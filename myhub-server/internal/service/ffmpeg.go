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
