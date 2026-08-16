package service

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"myhub-server/internal/model"
)

// HLS 参数
const (
	hlsSegmentTime   = 6                // 分片时长（秒）
	hlsIdleTimeout   = 5 * time.Minute  // 空闲回收时间
	hlsRecyclePeriod = 30 * time.Second // 回收检查周期
	hlsWaitPlaylist  = 15 * time.Second // 等待播放列表产出超时
	hlsWaitSegment   = 30 * time.Second // 等待分片产出超时
)

// HLSSession HLS 转码会话：一个 (sourceID, path) 对应一个 ffmpeg 进程
type HLSSession struct {
	ID       string // base64url("sourceID|path")
	Dir      string // 输出目录（含 playlist.m3u8 与 segment/ 子目录）
	SourceID uint
	Path     string

	mu         sync.Mutex
	cmd        *exec.Cmd
	exited     bool
	encodeMode bool // false=优先 -c copy 仅转封装；失败后 true 降码重编码
	lastAccess atomic.Int64
}

// Touch 更新最近访问时间（供 handler 层调用）
func (s *HLSSession) Touch() {
	s.lastAccess.Store(time.Now().Unix())
}

// PlaylistPath 返回播放列表文件路径
func (s *HLSSession) PlaylistPath() string {
	return filepath.Join(s.Dir, "playlist.m3u8")
}

// touch 更新最近访问时间
func (s *HLSSession) touch() {
	s.lastAccess.Store(time.Now().Unix())
}

// idle 返回空闲时长
func (s *HLSSession) idle() time.Duration {
	return time.Since(time.Unix(s.lastAccess.Load(), 0))
}

// kill 终止 ffmpeg 进程
func (s *HLSSession) kill() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil && s.cmd.Process != nil && !s.exited {
		_ = s.cmd.Process.Kill()
	}
}

// HLSSessionID 计算会话 ID（自描述，可逆解码出 sourceID 与 path）
func HLSSessionID(sourceID uint, p string) string {
	raw := fmt.Sprintf("%d|%s", sourceID, p)
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

// ParseHLSSessionID 解码会话 ID
func ParseHLSSessionID(id string) (uint, string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(id)
	if err != nil {
		return 0, "", ErrInvalidHLSSession
	}
	parts := strings.SplitN(string(raw), "|", 2)
	if len(parts) != 2 {
		return 0, "", ErrInvalidHLSSession
	}
	sourceID, err := strconv.ParseUint(parts[0], 10, 64)
	if err != nil || sourceID == 0 {
		return 0, "", ErrInvalidHLSSession
	}
	return uint(sourceID), parts[1], nil
}

// EnsureHLSSession 获取或启动 HLS 转码会话（同视频共享会话）
func (s *StreamService) EnsureHLSSession(ctx context.Context, sourceID uint, p string) (*HLSSession, error) {
	id := HLSSessionID(sourceID, p)

	s.mu.Lock()
	if sess, ok := s.sessions[id]; ok {
		sess.touch()
		s.mu.Unlock()
		return sess, nil
	}

	source, err := s.sourceSvc.GetByID(sourceID)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}

	sess := &HLSSession{
		ID:       id,
		Dir:      filepath.Join(s.cfg.Data.HLSDir, id),
		SourceID: sourceID,
		Path:     p,
	}
	sess.touch()
	if err := s.startFFmpeg(ctx, sess, source); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	s.sessions[id] = sess
	s.mu.Unlock()
	return sess, nil
}

// startFFmpeg 启动转码进程：优先 -c copy 仅转封装
func (s *StreamService) startFFmpeg(ctx context.Context, sess *HLSSession, source *model.Source) error {
	ffmpeg, err := ffmpegBinary()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(sess.Dir, "segment"), 0o755); err != nil {
		return err
	}

	args, err := ffmpegInputArgs(source, sess.Path)
	if err != nil {
		return err
	}
	// 判断是否需要重编码：
	//  1. encodeMode 已置位（前次 -c copy 失败）→ 重编码兜底；
	//  2. 主视频流为 HEVC/H.265 → 设备（尤其 iOS AVPlayer）可能无法硬解，
	//     -c copy 转封装后仍是 HEVC，照样黑屏有声；必须强制重编码为 H.264。
	// 重编码优先保持视频编码转换，音频尽量复制以降低开销。
	needEncode := sess.encodeMode
	if !needEncode {
		codec := probeVideoCodec(ctx, source, sess.Path)
		codec = strings.ToLower(codec)
		log.Printf("[HLS] 探测编码 sourceID=%d path=%s codec=%q", sess.SourceID, sess.Path, codec)
		if codec == "hevc" || codec == "h265" || codec == "x265" {
			needEncode = true
			sess.encodeMode = true // 避免后续再次探测
		}
	}
	if needEncode {
		// 降码重编码：视频强制 H.264，音频尝试复制（HEVC 常见配 AAC，可直接复制）
		log.Printf("[HLS] 转码策略=重编码(libx264) sourceID=%d path=%s", sess.SourceID, sess.Path)
		args = append(args, "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
			"-c:a", "aac", "-b:a", "128k")
	} else {
		log.Printf("[HLS] 转码策略=转封装(-c copy) sourceID=%d path=%s", sess.SourceID, sess.Path)
		args = append(args, "-c", "copy")
	}
	// 分片写入 segment/ 子目录，播放列表内引用 "segment/xxx.ts"，
	// 与路由 /api/stream/hls/:id/segment/:n.ts 的相对解析一致。
	// -hls_base_url 让 m3u8 里的分片引用带上 "segment/" 前缀，
	// 否则 ffmpeg 默认只写文件名（seg_00000.ts），AVPlayer 按相对路径
	// 解析成 /api/stream/hls/:id/seg_00000.ts（缺 segment/），路由不匹配返回 400。
	args = append(args,
		"-hls_time", fmt.Sprintf("%d", hlsSegmentTime),
		"-hls_list_size", "0",
		"-hls_segment_filename", filepath.Join(sess.Dir, "segment", "seg_%05d.ts"),
		"-hls_base_url", "segment/",
		"-loglevel", "error", "-y",
		filepath.Join(sess.Dir, "playlist.m3u8"),
	)

	cmd := exec.Command(ffmpeg, args...)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动 ffmpeg 失败: %w", err)
	}

	sess.mu.Lock()
	sess.cmd = cmd
	sess.exited = false
	sess.mu.Unlock()

	go func() {
		err := cmd.Wait()
		sess.mu.Lock()
		sess.exited = true
		sess.mu.Unlock()
		if err != nil {
			log.Printf("[HLS] ffmpeg 退出异常 sourceID=%d path=%s err=%v", sess.SourceID, sess.Path, err)
		} else {
			log.Printf("[HLS] ffmpeg 正常结束 sourceID=%d path=%s", sess.SourceID, sess.Path)
		}
	}()
	return nil
}

// WaitPlaylist 等待播放列表产出；转封装失败时自动降级重编码重试一次
func (s *StreamService) WaitPlaylist(ctx context.Context, sess *HLSSession) error {
	deadline := time.Now().Add(hlsWaitPlaylist)
	playlist := filepath.Join(sess.Dir, "playlist.m3u8")

	for {
		if fi, err := os.Stat(playlist); err == nil && fi.Size() > 0 {
			return nil
		}

		sess.mu.Lock()
		exited := sess.exited
		encodeMode := sess.encodeMode
		sess.mu.Unlock()

		if exited {
			if !encodeMode {
				// 转封装失败（编码不兼容），降级重编码重试
				source, err := s.sourceSvc.GetByID(sess.SourceID)
				if err != nil {
					return err
				}
				sess.mu.Lock()
				sess.encodeMode = true
				sess.mu.Unlock()
				if err := s.startFFmpeg(ctx, sess, source); err != nil {
					return err
				}
				deadline = time.Now().Add(hlsWaitPlaylist)
				continue
			}
			return ErrHLSFailed
		}

		if time.Now().After(deadline) {
			return ErrHLSFailed
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// WaitSegment 等待分片产出，返回分片文件路径
func (s *StreamService) WaitSegment(ctx context.Context, sess *HLSSession, name string) (string, error) {
	// 防目录穿越：分片名仅允许 seg_00001.ts 形式
	if strings.ContainsAny(name, `/\`) || strings.Contains(name, "..") || !strings.HasSuffix(name, ".ts") {
		return "", ErrInvalidHLSSession
	}
	segPath := filepath.Join(sess.Dir, "segment", name)
	deadline := time.Now().Add(hlsWaitSegment)

	for {
		if fi, err := os.Stat(segPath); err == nil && fi.Size() > 0 {
			return segPath, nil
		}
		sess.mu.Lock()
		exited := sess.exited
		sess.mu.Unlock()
		// 进程已退出且分片不存在 → 确实没有该分片
		if exited {
			if _, err := os.Stat(segPath); err != nil {
				return "", os.ErrNotExist
			}
		}
		if time.Now().After(deadline) {
			return "", os.ErrNotExist
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// recycleLoop 定期回收空闲超过 5 分钟的转码会话
func (s *StreamService) recycleLoop() {
	ticker := time.NewTicker(hlsRecyclePeriod)
	defer ticker.Stop()
	for {
		select {
		case <-s.stopCh:
			return
		case <-ticker.C:
			s.mu.Lock()
			for id, sess := range s.sessions {
				if sess.idle() > hlsIdleTimeout {
					sess.kill()
					_ = os.RemoveAll(sess.Dir)
					delete(s.sessions, id)
				}
			}
			s.mu.Unlock()
		}
	}
}
