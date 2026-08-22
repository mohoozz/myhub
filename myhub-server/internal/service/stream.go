package service

import (
	"context"
	"errors"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"myhub-server/internal/adapter"
	"myhub-server/internal/config"
)

// 流媒体相关业务错误
var (
	ErrInvalidRange        = errors.New("无效的 Range 请求头")
	ErrUnsupportedSubtitle = errors.New("不支持的字幕格式（仅 srt/ass/ssa/vtt）")
	ErrHLSFailed           = errors.New("HLS 转码失败")
	ErrInvalidHLSSession   = errors.New("无效的 HLS 会话 ID")
)

// 直通格式：浏览器可直接解码播放
var directStreamExts = map[string]string{
	// 视频
	".mp4": "video/mp4", ".webm": "video/webm", ".m4v": "video/mp4",
	".mkv": "video/x-matroska", ".avi": "video/x-msvideo", ".mov": "video/quicktime",
	// 音频
	".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".flac": "audio/flac",
	".wav": "audio/wav", ".ogg": "audio/ogg",
	// 字幕
	".vtt": "text/vtt",
}

// StreamContentType 按扩展名返回 Content-Type，未知返回 application/octet-stream
func StreamContentType(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if ct, ok := directStreamExts[ext]; ok {
		return ct
	}
	return "application/octet-stream"
}

// IsPassthrough 判断是否为直通格式（视频/音频）
func IsPassthrough(name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	ct, ok := directStreamExts[ext]
	return ok && (strings.HasPrefix(ct, "video/") || strings.HasPrefix(ct, "audio/"))
}

// ParseRange 解析 HTTP Range 头（仅支持单区间），返回闭区间 [start, end]。
// header 为空时返回整个文件区间。非法区间返回 ErrInvalidRange。
func ParseRange(header string, size int64) (int64, int64, error) {
	if header == "" {
		return 0, size - 1, nil
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, ErrInvalidRange
	}
	spec := strings.TrimPrefix(header, "bytes=")
	if strings.Contains(spec, ",") {
		return 0, 0, ErrInvalidRange // 不支持多区间
	}
	parts := strings.SplitN(spec, "-", 2)
	if len(parts) != 2 {
		return 0, 0, ErrInvalidRange
	}

	var start, end int64
	if parts[0] == "" {
		// 后缀区间：bytes=-N 表示最后 N 字节
		n, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, ErrInvalidRange
		}
		if n > size {
			n = size
		}
		start = size - n
		end = size - 1
	} else {
		var err error
		start, err = strconv.ParseInt(parts[0], 10, 64)
		if err != nil || start < 0 {
			return 0, 0, ErrInvalidRange
		}
		if parts[1] == "" {
			end = size - 1
		} else {
			end, err = strconv.ParseInt(parts[1], 10, 64)
			if err != nil {
				return 0, 0, ErrInvalidRange
			}
		}
	}
	if start >= size || end < start {
		return 0, 0, ErrInvalidRange
	}
	if end >= size {
		end = size - 1
	}
	return start, end, nil
}

// StreamService 流媒体业务逻辑：Range 流式响应、HLS 会话池、字幕转换
type StreamService struct {
	cfg       *config.Config
	sourceSvc *SourceService

	mu       sync.Mutex
	sessions map[string]*HLSSession
	stopCh   chan struct{}
}

// NewStreamService 创建 StreamService 并启动会话回收协程
func NewStreamService(cfg *config.Config, sourceSvc *SourceService) *StreamService {
	s := &StreamService{
		cfg:       cfg,
		sourceSvc: sourceSvc,
		sessions:  make(map[string]*HLSSession),
		stopCh:    make(chan struct{}),
	}
	go s.recycleLoop()
	return s
}

// Stat 获取文件元信息
func (s *StreamService) Stat(ctx context.Context, sourceID uint, p string) (*adapter.FileInfo, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	return a.Stat(ctx, p)
}

// ProbeCodec 探测视频与音频主流的编码名（如 "hevc"/"h264"、"aac"/"ac3"），
// 以及音频的 codec_tag（如 "mp4a"），供客户端识别畸形封装（如 mp4a tag 装 MP3）。
// 客户端据此在播放前决定直连硬解还是转码/软解，避免"黑屏有声"或"有声无图"再兜底。
// 探测失败返回空字符串（客户端按"未知"处理，走既有兜底路径）。
func (s *StreamService) ProbeCodec(ctx context.Context, sourceID uint, p string) (videoCodec, audioCodec, audioTag string) {
	_, source, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return "", "", ""
	}
	video := probeVideoCodec(ctx, source, p)
	audio := probeAudioCodec(ctx, source, p)
	// audio 形如 "mp3,mp4a"（codec_name,codec_tag_string），无音频轨时为空
	audioCodec, audioTag = "", ""
	if audio != "" {
		if parts := strings.SplitN(audio, ",", 2); len(parts) == 2 {
			audioCodec = strings.TrimSpace(parts[0])
			audioTag = strings.TrimSpace(parts[1])
		} else {
			audioCodec = strings.TrimSpace(audio)
		}
	}
	return video, audioCodec, audioTag
}

// Open 打开文件流（支持 Range）
func (s *StreamService) Open(ctx context.Context, sourceID uint, p string, offset, length int64) (io.ReadCloser, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	return a.ReadStream(ctx, p, offset, length)
}

// Stop 停止会话回收协程并终止全部转码会话
func (s *StreamService) Stop() {
	close(s.stopCh)
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sess := range s.sessions {
		sess.kill()
	}
	s.sessions = make(map[string]*HLSSession)
}
