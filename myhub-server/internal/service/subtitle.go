package service

import (
	"bytes"
	"context"
	"io"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// SubtitleToVTT 将 srt/ass/ssa 字幕转换为 WebVTT；vtt 直接透传。
// 返回 VTT 内容。优先走 ffmpeg 转码；ffmpeg 不可用且为 srt 时退化为自行解析转换。
func (s *StreamService) SubtitleToVTT(ctx context.Context, sourceID uint, p string) ([]byte, error) {
	ext := strings.ToLower(filepath.Ext(p))
	switch ext {
	case ".srt", ".ass", ".ssa", ".vtt":
	default:
		return nil, ErrUnsupportedSubtitle
	}

	rc, err := s.Open(ctx, sourceID, p, 0, -1)
	if err != nil {
		return nil, err
	}
	defer rc.Close()

	if ext == ".vtt" {
		return readAllLimit(rc)
	}

	// 优先 ffmpeg：pipe 输入输出，本地/WebDAV 源均适用
	if ffmpeg, err := ffmpegBinary(); err == nil {
		cmd := exec.CommandContext(ctx, ffmpeg, "-i", "pipe:0", "-f", "webvtt", "-loglevel", "error", "pipe:1")
		cmd.Stdin = rc
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err == nil && out.Len() > 0 {
			return out.Bytes(), nil
		}
	}

	// ffmpeg 不可用/失败：srt 自行解析转换（ass/ssa 结构复杂，不做兜底）
	if ext != ".srt" {
		return nil, ErrNoFFmpeg
	}

	// rc 可能已被 ffmpeg 消费，重新打开
	rc2, err := s.Open(ctx, sourceID, p, 0, -1)
	if err != nil {
		return nil, err
	}
	defer rc2.Close()
	raw, err := readAllLimit(rc2)
	if err != nil {
		return nil, err
	}
	return srtToVTT(raw), nil
}

// readAllLimit 读取全部内容（上限 32MB，字幕文件足够）
func readAllLimit(r io.Reader) ([]byte, error) {
	var buf bytes.Buffer
	_, err := buf.ReadFrom(io.LimitReader(r, 32<<20))
	return buf.Bytes(), err
}

// srtTimestamp 匹配 srt 时间轴行：00:00:01,000 --> 00:00:04,000
var srtTimestamp = regexp.MustCompile(`(\d{2}:\d{2}:\d{2}),(\d{3})`)

// srtToVTT 简易 srt → webvtt 转换：时间戳逗号改小数点，加头部
func srtToVTT(raw []byte) []byte {
	text := strings.ReplaceAll(string(raw), "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	text = srtTimestamp.ReplaceAllString(text, "$1.$2")
	return []byte("WEBVTT\n\n" + strings.TrimPrefix(text, "\ufeff"))
}
