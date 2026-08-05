package model

import "time"

// AppConfig 应用配置表（键值对）：唯一键 key
type AppConfig struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Key       string    `gorm:"size:128;not null;uniqueIndex" json:"key"`
	Value     string    `gorm:"type:text" json:"value"`
	UpdatedAt time.Time `json:"updated_at"`
}

// TableName 指定表名
func (AppConfig) TableName() string { return "app_configs" }
