package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	"myhub-server/internal/adapter"
	"myhub-server/internal/model"
)

// ErrNoFFmpeg 未安装 ffmpeg
var ErrNoFFmpeg = fmt.Errorf("未找到 ffmpeg")

// ffmpegBinary 查找 ffmpeg 可执行文件
func ffmpegBinary() (string, error) {
	p, err := exec.LookPath("ffmpeg")
	if err != nil {
		return "", ErrNoFFmpeg
	}
	return p, nil
}

// probeVideoCodec 用 ffprobe 探测主视频流编码名（如 "hevc"、"h264"）。
// 探测失败返回空字符串（调用方按"未知"处理，走保守路径）。
func probeVideoCodec(ctx context.Context, source *model.Source, p string) string {
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		return ""
	}
	inputArgs, err := ffmpegInputArgs(source, p)
	if err != nil {
		return ""
	}
	// 探测选项必须在 -i 之前（-analyzeduration/-probesize 是输入侧选项）。
	// moov atom 在文件末尾的 MP4（压制组常见）默认探测窗口不足，ffprobe
	// 读不到 moov 就探测不到视频流，返回空。这里给 3s / 10MB 足够覆盖
	// 末尾 moov（约 9.9MB）。
	probeOpts := []string{
		"-analyzeduration", "3000000",
		"-probesize", "10485760",
	}
	args := make([]string, 0, len(inputArgs)+len(probeOpts)+8)
	// 在 -i 之前插入探测选项
	for _, a := range inputArgs {
		if a == "-i" {
			args = append(args, probeOpts...)
		}
		args = append(args, a)
	}
	args = append(args,
		"-v", "error",
		"-select_streams", "v:0",
		"-show_entries", "stream=codec_name",
		"-of", "csv=p=0",
	)
	cmdCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cmdCtx, ffprobe, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// probeAudioCodec 用 ffprobe 探测主音频流编码名（如 "aac"、"ac3"、"eac3"）。
// 返回 codec_name|codec_tag_string 两个值（空格分隔，csv 一行两列）。
// 探测失败返回空字符串（调用方按"未知"处理）。
func probeAudioCodec(ctx context.Context, source *model.Source, p string) string {
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		return ""
	}
	inputArgs, err := ffmpegInputArgs(source, p)
	if err != nil {
		return ""
	}
	probeOpts := []string{
		"-analyzeduration", "3000000",
		"-probesize", "10485760",
	}
	args := make([]string, 0, len(inputArgs)+len(probeOpts)+8)
	for _, a := range inputArgs {
		if a == "-i" {
			args = append(args, probeOpts...)
		}
		args = append(args, a)
	}
	args = append(args,
		"-v", "error",
		"-select_streams", "a:0",
		"-show_entries", "stream=codec_name,codec_tag_string",
		"-of", "csv=p=0",
	)
	cmdCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cmdCtx, ffprobe, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ffmpegInputArgs 构造 ffmpeg 输入参数（含 -i）。
// 本地源直接用文件绝对路径；WebDAV 源用 URL + Basic 认证头。
func ffmpegInputArgs(source *model.Source, p string) ([]string, error) {
	switch source.Type {
	case model.SourceTypeLocal:
		abs := filepath.Join(source.MountPoint, filepath.FromSlash(strings.TrimPrefix(p, "/")))
		return []string{"-i", abs}, nil

	case model.SourceTypeWebDAV:
		var cfg adapter.WebDavConfig
		if err := json.Unmarshal([]byte(source.ConfigJSON), &cfg); err != nil {
			return nil, err
		}
		base := strings.TrimSuffix(cfg.URL, "/")
		// 内网地址可达时优先使用（与适配器链路选择一致）
		if lan := strings.TrimSuffix(strings.TrimSpace(cfg.LanURL), "/"); lan != "" && probeHTTP(lan, 3*time.Second) {
			base = lan
		}
		// 逐段百分号编码：文件名中的 #、空格、CJK 等字符不做转义会破坏 URL
		fullURL := base + escapeURLPath(path.Join("/", source.MountPoint, p))
		auth := base64.StdEncoding.EncodeToString([]byte(cfg.Username + ":" + cfg.Password))
		return []string{"-headers", fmt.Sprintf("Authorization: Basic %s\r\n", auth), "-i", fullURL}, nil

	default:
		return nil, fmt.Errorf("类型 %q 暂不支持 ffmpeg 输入", source.Type)
	}
}

// escapeURLPath 逐段编码 URL 路径，保留 "/" 分隔符
func escapeURLPath(p string) string {
	segs := strings.Split(p, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
}

// probeHTTP 短超时探测地址可达性，收到任意 HTTP 响应（含 401/404）即视为可达
func probeHTTP(rawURL string, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return false
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return true
}
