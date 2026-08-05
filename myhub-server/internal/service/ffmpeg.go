package service

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

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
		fullURL := strings.TrimSuffix(cfg.URL, "/") + path.Join("/", source.MountPoint, p)
		auth := base64.StdEncoding.EncodeToString([]byte(cfg.Username + ":" + cfg.Password))
		return []string{"-headers", fmt.Sprintf("Authorization: Basic %s\r\n", auth), "-i", fullURL}, nil

	default:
		return nil, fmt.Errorf("类型 %q 暂不支持 ffmpeg 输入", source.Type)
	}
}
