package service

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"gorm.io/gorm"

	"myhub-server/internal/adapter"
	"myhub-server/internal/config"
	"myhub-server/internal/model"
	"myhub-server/internal/parser"
	"myhub-server/internal/repository"
)

// 文件管理相关业务错误
var (
	ErrCrossSourceDir = errors.New("跨源中转暂不支持目录")
	ErrInvalidName    = errors.New("非法文件名")
	ErrNotVideo       = errors.New("仅音视频文件支持缩略图")
	ErrNotImage       = errors.New("仅图片文件支持预览")
	ErrNotText        = errors.New("该文件不是纯文本或内容不可读")
)

// textPreviewMaxBytes 纯文本预览最大读取字节数（超出仅取头部并标记截断）。
const textPreviewMaxBytes = 2 << 20

// 媒体类型扩展名映射
var mediaTypeByExt = map[string]string{
	// 视频（直通格式见流媒体模块）
	".mp4": "video", ".webm": "video", ".m4v": "video", ".mkv": "video",
	".avi": "video", ".mov": "video", ".ts": "video", ".flv": "video",
	".wmv": "video", ".mpg": "video", ".mpeg": "video", ".rmvb": "video",
	// 音频
	".mp3": "audio", ".m4a": "audio", ".flac": "audio", ".wav": "audio",
	".ogg": "audio", ".aac": "audio", ".wma": "audio", ".opus": "audio",
	// 小说
	".txt": "novel", ".epub": "novel",
	// 漫画
	".cbz": "comic", ".cbr": "comic",
	// 图片
	".jpg": "image", ".jpeg": "image", ".png": "image", ".gif": "image",
	".webp": "image", ".bmp": "image", ".svg": "image",
	// 压缩包（可经漫画嗅探升级）
	".zip": "archive", ".rar": "archive", ".7z": "archive",
	".tar": "archive", ".gz": "archive",
}

// DetectMediaType 按扩展名识别媒体类型；目录返回 "dir"，未知返回 "other"
func DetectMediaType(name string, isDir bool) string {
	if isDir {
		return "dir"
	}
	ext := strings.ToLower(filepath.Ext(name))
	if t, ok := mediaTypeByExt[ext]; ok {
		return t
	}
	return "other"
}

// FileItem 文件列表项：元信息 + 媒体类型
type FileItem struct {
	adapter.FileInfo
	MediaType string `json:"media_type"`
}

// FileService 文件管理业务逻辑：编排适配器与回收站记录、跨源流式中转
type FileService struct {
	cfg          *config.Config
	sourceSvc    *SourceService
	trashRepo    *repository.TrashRepository
	progressRepo *repository.ProgressRepository

	// 缩略图 FFmpeg 抽帧并发控制（见 Thumbnail）
	thumbSem      chan struct{}
	thumbMu       sync.Mutex
	thumbInflight map[string]*thumbCall
}

// NewFileService 创建 FileService
func NewFileService(cfg *config.Config, sourceSvc *SourceService, trashRepo *repository.TrashRepository, progressRepo *repository.ProgressRepository) *FileService {
	return &FileService{
		cfg:           cfg,
		sourceSvc:     sourceSvc,
		trashRepo:     trashRepo,
		progressRepo:  progressRepo,
		thumbSem:      make(chan struct{}, thumbMaxConcurrent),
		thumbInflight: make(map[string]*thumbCall),
	}
}

// List 列目录，附带媒体类型识别
func (s *FileService) List(ctx context.Context, sourceID uint, p string) ([]FileItem, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	infos, err := a.List(ctx, p)
	if err != nil {
		return nil, err
	}
	items := make([]FileItem, 0, len(infos))
	for _, fi := range infos {
		items = append(items, FileItem{
			FileInfo:  fi,
			MediaType: DetectMediaType(fi.Name, fi.IsDir),
		})
	}
	return items, nil
}

// Info 查询单个文件信息（元信息 + 媒体类型）
func (s *FileService) Info(ctx context.Context, sourceID uint, p string) (*FileItem, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, err
	}
	return &FileItem{
		FileInfo:  *fi,
		MediaType: DetectMediaType(fi.Name, fi.IsDir),
	}, nil
}

// Mkdir 新建文件夹
func (s *FileService) Mkdir(ctx context.Context, sourceID uint, p string) error {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return err
	}
	return a.Mkdir(ctx, p)
}

// Rename 重命名（同目录移动）
func (s *FileService) Rename(ctx context.Context, sourceID uint, p, newName string) error {
	if err := validateName(newName); err != nil {
		return err
	}
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return err
	}
	dst := path.Join(path.Dir("/"+strings.TrimPrefix(p, "/")), newName)
	if err := a.Move(ctx, p, dst); err != nil {
		return err
	}
	// 重命名后同步阅读进度路径（含子目录），避免"正在阅读"历史失效。
	s.updateProgressPath(ctx, sourceID, p, dst)
	return nil
}

// updateProgressPath 文件路径变更（移动/重命名）后，同步更新阅读进度记录路径。
// 失败仅记日志，不阻断文件操作本身。
func (s *FileService) updateProgressPath(_ context.Context, sourceID uint, oldPath, newPath string) {
	if _, err := s.progressRepo.UpdatePathPrefix(sourceID, oldPath, newPath); err != nil {
		log.Printf("同步阅读进度路径失败 source=%d old=%s new=%s: %v", sourceID, oldPath, newPath, err)
	}
}

// Upload 流式上传文件到指定目录
func (s *FileService) Upload(ctx context.Context, sourceID uint, dir, name string, r io.Reader, size int64) error {
	if err := validateName(name); err != nil {
		return err
	}
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return err
	}
	return a.WriteStream(ctx, path.Join(dir, name), r, size)
}

// Move 移动：同源走适配器 Move；跨源走流式中转（不落临时文件），成功后源文件入回收站
func (s *FileService) Move(ctx context.Context, sourceID uint, paths []string, targetSourceID uint, targetDir string) error {
	if sourceID == targetSourceID {
		a, _, err := s.sourceSvc.GetAdapter(sourceID)
		if err != nil {
			return err
		}
		for _, p := range paths {
			dst := path.Join(targetDir, path.Base(p))
			if err := a.Move(ctx, p, dst); err != nil {
				return err
			}
			// 移动后同步阅读进度路径（含子目录），避免"正在阅读"历史失效。
			s.updateProgressPath(ctx, sourceID, p, dst)
		}
		return nil
	}

	// 跨源：流式中转 + 源入回收站
	if err := s.relay(ctx, sourceID, paths, targetSourceID, targetDir); err != nil {
		return err
	}
	return s.Delete(ctx, sourceID, paths)
}

// Copy 复制：同源走适配器 Copy；跨源走流式中转
func (s *FileService) Copy(ctx context.Context, sourceID uint, paths []string, targetSourceID uint, targetDir string) error {
	if sourceID == targetSourceID {
		a, _, err := s.sourceSvc.GetAdapter(sourceID)
		if err != nil {
			return err
		}
		for _, p := range paths {
			dst := path.Join(targetDir, path.Base(p))
			if err := a.Copy(ctx, p, dst); err != nil {
				return err
			}
		}
		return nil
	}
	return s.relay(ctx, sourceID, paths, targetSourceID, targetDir)
}

// relay 跨源流式中转：ReadStream(源) → WriteStream(目标)，不落地临时文件
func (s *FileService) relay(ctx context.Context, sourceID uint, paths []string, targetSourceID uint, targetDir string) error {
	src, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return err
	}
	dst, _, err := s.sourceSvc.GetAdapter(targetSourceID)
	if err != nil {
		return err
	}

	for _, p := range paths {
		fi, err := src.Stat(ctx, p)
		if err != nil {
			return err
		}
		if fi.IsDir {
			return ErrCrossSourceDir
		}

		rc, err := src.ReadStream(ctx, p, 0, -1)
		if err != nil {
			return err
		}
		err = dst.WriteStream(ctx, path.Join(targetDir, path.Base(p)), rc, fi.Size)
		_ = rc.Close()
		if err != nil {
			return fmt.Errorf("跨源中转 %s 失败: %w", p, err)
		}
	}
	return nil
}

// Delete 删除入回收站：适配器逻辑删除 + trash_items 落库
func (s *FileService) Delete(ctx context.Context, sourceID uint, paths []string) error {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return err
	}
	for _, p := range paths {
		fi, err := a.Stat(ctx, p)
		if err != nil {
			return err
		}
		trashPath, err := a.Delete(ctx, p)
		if err != nil {
			return err
		}
		item := &model.TrashItem{
			SourceID:     sourceID,
			OriginalPath: p,
			TrashPath:    trashPath,
			Size:         fi.Size,
			DeletedAt:    time.Now(),
		}
		if err := s.trashRepo.Create(item); err != nil {
			return fmt.Errorf("回收站记录失败: %w", err)
		}
		// 删除文件/目录后联动清理阅读进度（含子目录），
		// 避免"正在阅读"仍展示已删除文件；无记录时忽略，失败不阻断文件删除。
		if err := s.progressRepo.Delete(sourceID, p); err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			log.Printf("删除阅读进度记录失败 source=%d path=%s: %v", sourceID, p, err)
		}
	}
	return nil
}

// Image 读取图片文件原始字节（按扩展名校验，仅支持图片类型）。
// 返回 (bytes, 文件名)；WebDAV 源流式读取整文件。
func (s *FileService) Image(ctx context.Context, sourceID uint, p string) ([]byte, string, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, "", err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, "", err
	}
	if fi.IsDir {
		return nil, "", ErrNotImage
	}
	if DetectMediaType(fi.Name, false) != "image" {
		return nil, "", ErrNotImage
	}
	rc, err := a.ReadStream(ctx, p, 0, -1)
	if err != nil {
		return nil, "", err
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, "", err
	}
	return data, fi.Name, nil
}

// TextPreviewResult 纯文本预览响应
type TextPreviewResult struct {
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	Content   string `json:"content"`
	Truncated bool   `json:"truncated"` // 文件超出预览上限，仅返回头部内容
}

// TextPreview 读取任意文件的纯文本预览：采样检测编码（UTF-8/GBK/Big5），
// 解码为 UTF-8；超出 [textPreviewMaxBytes] 仅取头部并标记 truncated；
// 明显为二进制文件（NUL/控制字符占比过高）时报 ErrNotText。
func (s *FileService) TextPreview(ctx context.Context, sourceID uint, p string) (*TextPreviewResult, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, err
	}
	if fi.IsDir {
		return nil, adapter.ErrIsDirectory
	}
	// 空文件：直接返回空内容，避免对空文件发起 Range 读取
	if fi.Size == 0 {
		return &TextPreviewResult{Name: fi.Name, Size: 0, Content: ""}, nil
	}

	// 采样检测编码
	sampleRC, err := a.ReadStream(ctx, p, 0, encodingSampleSize)
	if err != nil {
		return nil, err
	}
	sample, _ := io.ReadAll(sampleRC)
	_ = sampleRC.Close()
	encName := parser.DetectEncoding(sample)
	// UTF-16 文本天然含大量 NUL 字节（码元高/低位），须跳过二进制判定；
	// 其余编码保持原判断，避免把二进制文件当文本解码
	if !parser.IsUTF16(encName) && isBinarySample(sample) {
		return nil, ErrNotText
	}

	// 超出上限仅读取头部
	length := fi.Size
	truncated := false
	if length > textPreviewMaxBytes {
		length = textPreviewMaxBytes
		truncated = true
	}
	rc, err := a.ReadStream(ctx, p, 0, length)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	raw, err := io.ReadAll(rc)
	if err != nil {
		return nil, err
	}
	content := parser.DecodeString(encName, raw)
	// 解码后乱码（U+FFFD）占比过高视为非文本
	if garbageRatio(content) > 0.1 {
		return nil, ErrNotText
	}
	return &TextPreviewResult{
		Name:      fi.Name,
		Size:      fi.Size,
		Content:   content,
		Truncated: truncated,
	}, nil
}

// isBinarySample 粗略判断字节采样是否为二进制：NUL 占比 >1%
// 或不可打印控制字符（排除 \t\n\r\f）占比 >5% 视为二进制。
func isBinarySample(sample []byte) bool {
	if len(sample) == 0 {
		return false
	}
	var nul, ctrl int
	for _, b := range sample {
		switch {
		case b == 0:
			nul++
		case b < 0x09 || (b > 0x0D && b < 0x20):
			ctrl++
		}
	}
	if float64(nul)/float64(len(sample)) > 0.01 {
		return true
	}
	return float64(ctrl)/float64(len(sample)) > 0.05
}

// garbageRatio 计算解码文本中替换符（U+FFFD）占比。
func garbageRatio(s string) float64 {
	if s == "" {
		return 0
	}
	runes := utf8.RuneCountInString(s)
	if runes == 0 {
		return 0
	}
	return float64(bytes.Count([]byte(s), []byte("\uFFFD"))) / float64(runes)
}

// thumbMaxConcurrent 缩略图 FFmpeg 抽帧的最大并发数。
//
// 目录内大量视频封面未缓存时，前端会并发请求几十个缩略图；若不限流，
// 后端会同时启动几十个 FFmpeg 进程，抢满 CPU/磁盘 I/O（WebDAV 源还抢
// 网络带宽），拖慢视频流（直链 Range / HLS 转码）导致播放启动卡顿。
const thumbMaxConcurrent = 2

// thumbCall 同一缩略图键（sourceID+path）的共享生成任务（singleflight）。
type thumbCall struct {
	done chan struct{}
	path string
	err  error
}

// Thumbnail 生成/获取音视频缩略图（FFmpeg，按 sourceID+path 缓存）
// 视频抽帧；音频提取内嵌专辑封面（attached pic 以视频流形式存在）。
// 返回缓存的 JPEG 文件路径
//
// 并发控制：
// * 缓存命中直接返回，不占用抽帧并发额度；
// * 同一文件的并发请求共享同一次抽帧（singleflight），等待方复用结果；
// * 全局信号量把同时运行的 FFmpeg 抽帧进程限制在 thumbMaxConcurrent 内。
func (s *FileService) Thumbnail(ctx context.Context, sourceID uint, p string) (string, error) {
	// 缓存命中直接返回
	sum := sha1.Sum([]byte(fmt.Sprintf("%d:%s", sourceID, p)))
	outPath := filepath.Join(s.cfg.Data.ThumbsDir, hex.EncodeToString(sum[:])+".jpg")
	if _, err := os.Stat(outPath); err == nil {
		return outPath, nil
	}

	// singleflight：同一视频的并发请求只跑一次 FFmpeg
	s.thumbMu.Lock()
	if call, ok := s.thumbInflight[outPath]; ok {
		s.thumbMu.Unlock()
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-call.done:
			return call.path, call.err
		}
	}
	call := &thumbCall{done: make(chan struct{})}
	s.thumbInflight[outPath] = call
	s.thumbMu.Unlock()

	call.path, call.err = s.generateThumbnail(ctx, sourceID, p, outPath)

	s.thumbMu.Lock()
	delete(s.thumbInflight, outPath)
	s.thumbMu.Unlock()
	close(call.done)
	return call.path, call.err
}

// generateThumbnail 实际执行 FFmpeg 抽帧（受全局并发限额约束）。
func (s *FileService) generateThumbnail(ctx context.Context, sourceID uint, p, outPath string) (string, error) {
	a, source, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return "", err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return "", err
	}
	mediaType := DetectMediaType(fi.Name, fi.IsDir)
	if mediaType != "video" && mediaType != "audio" {
		return "", ErrNotVideo
	}

	// 并发限额：拿到许可才开始抽帧；排队等待期间响应请求取消
	select {
	case s.thumbSem <- struct{}{}:
		defer func() { <-s.thumbSem }()
	case <-ctx.Done():
		return "", ctx.Err()
	}

	ffmpeg, err := ffmpegBinary()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(s.cfg.Data.ThumbsDir, 0o755); err != nil {
		return "", err
	}

	// 构造 ffmpeg 输入：本地源直接用文件路径，WebDAV 源用 URL + Basic 认证头
	inputArgs, err := ffmpegInputArgs(source, p)
	if err != nil {
		return "", err
	}

	// 候选命令：前一个失败（或无产物）时依次回退
	var argSets [][]string
	if mediaType == "audio" {
		// -an 丢弃音频流，取封面图帧并等比缩放到宽 320
		argSets = [][]string{
			append(append([]string{}, inputArgs...), "-an", "-vframes", "1", "-vf", "scale=320:-2", "-y", outPath),
		}
	} else {
		// -ss 10 置于 -i 前（输入seek，快）；短于 10 秒的视频无帧产出时回退抽首帧
		argSets = [][]string{
			append(append([]string{"-ss", "10"}, inputArgs...), "-vframes", "1", "-s", "320x180", "-y", outPath),
			append(append([]string{}, inputArgs...), "-vframes", "1", "-s", "320x180", "-y", outPath),
		}
	}

	var lastErr error
	for _, args := range argSets {
		cmdCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
		cmd := exec.CommandContext(cmdCtx, ffmpeg, args...)
		output, runErr := cmd.CombinedOutput()
		cancel()
		if runErr != nil {
			lastErr = fmt.Errorf("ffmpeg 执行失败: %w, 输出: %s", runErr, tailOutput(output, 800))
			continue
		}
		if st, statErr := os.Stat(outPath); statErr == nil && st.Size() > 0 {
			return outPath, nil
		}
		lastErr = errors.New("ffmpeg 未产出有效缩略图")
	}
	return "", lastErr
}

// tailOutput 截取命令输出的末尾部分（ffmpeg 的错误信息在尾部，头部是版本 banner）
func tailOutput(b []byte, n int) string {
	s := strings.TrimSpace(string(b))
	if len(s) > n {
		s = "..." + s[len(s)-n:]
	}
	return s
}

// validateName 校验文件名合法（非空、无路径分隔符、非 . / ..）
func validateName(name string) error {
	if name == "" || name == "." || name == ".." ||
		strings.ContainsAny(name, `/\`) {
		return ErrInvalidName
	}
	return nil
}
