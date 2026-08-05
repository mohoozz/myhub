package model

import "time"

// SourceType 路径源类型
type SourceType string

const (
	SourceTypeLocal   SourceType = "local"   // 本地磁盘
	SourceTypeWebDAV  SourceType = "webdav"  // WebDAV
	SourceTypeOpenList SourceType = "openlist" // OpenList（二期）
)

// Source 路径源表：一个路径源对应一个存储适配器实例
type Source struct {
	ID         uint       `gorm:"primaryKey" json:"id"`
	Name       string     `gorm:"size:128;not null" json:"name"`
	Type       SourceType `gorm:"size:32;not null;index" json:"type"`
	ConfigJSON string     `gorm:"type:text" json:"config_json"` // 适配器配置（JSON），如 WebDAV 地址/账号
	MountPoint string     `gorm:"size:512" json:"mount_point"`  // 挂载点/根路径
	Enabled    bool       `gorm:"not null;default:true" json:"enabled"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"-"`
}

// TableName 指定表名
func (Source) TableName() string { return "sources" }
