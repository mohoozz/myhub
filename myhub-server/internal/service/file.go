package service

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	"myhub-server/internal/adapter"
	"myhub-server/internal/config"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 文件管理相关业务错误
var (
	ErrCrossSourceDir = errors.New("跨源中转暂不支持目录")
	ErrInvalidName    = errors.New("非法文件名")
	ErrNotVideo       = errors.New("仅音视频文件支持缩略图")
)

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
	cfg       *config.Config
	sourceSvc *SourceService
	trashRepo *repository.TrashRepository
}

// NewFileService 创建 FileService
func NewFileService(cfg *config.Config, sourceSvc *SourceService, trashRepo *repository.TrashRepository) *FileService {
	return &FileService{cfg: cfg, sourceSvc: sourceSvc, trashRepo: trashRepo}
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
	return a.Move(ctx, p, dst)
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
	}
	return nil
}

// Thumbnail 生成/获取音视频缩略图（FFmpeg，按 sourceID+path 缓存）
// 视频抽帧；音频提取内嵌专辑封面（attached pic 以视频流形式存在）。
// 返回缓存的 JPEG 文件路径
func (s *FileService) Thumbnail(ctx context.Context, sourceID uint, p string) (string, error) {
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

	// 缓存命中直接返回
	sum := sha1.Sum([]byte(fmt.Sprintf("%d:%s", sourceID, p)))
	outPath := filepath.Join(s.cfg.Data.ThumbsDir, hex.EncodeToString(sum[:])+".jpg")
	if _, err := os.Stat(outPath); err == nil {
		return outPath, nil
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
