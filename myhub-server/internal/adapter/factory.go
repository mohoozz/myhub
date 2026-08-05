package adapter

import (
	"encoding/json"
	"fmt"

	"myhub-server/internal/model"
)

// New 适配器工厂：根据 Source.Type 创建对应适配器实例。
// allowedRoots 为本地路径源白名单（仅对 local 类型生效）。
func New(source *model.Source, allowedRoots []string) (IStorageAdapter, error) {
	switch source.Type {
	case model.SourceTypeLocal:
		return NewLocalAdapter(source.MountPoint, allowedRoots)

	case model.SourceTypeWebDAV:
		var cfg WebDavConfig
		if err := json.Unmarshal([]byte(source.ConfigJSON), &cfg); err != nil {
			return nil, fmt.Errorf("解析 WebDAV 配置失败: %w", err)
		}
		return NewWebDavAdapter(&cfg, source.MountPoint)

	case model.SourceTypeOpenList:
		// TODO(二期)：对接 OpenList REST API
		return nil, fmt.Errorf("OpenList 适配器尚未实现（二期）")

	default:
		return nil, fmt.Errorf("未知的路径源类型: %q", source.Type)
	}
}
