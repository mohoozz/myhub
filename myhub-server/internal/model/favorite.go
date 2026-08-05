package model

import "time"

// Favorite 收藏表：唯一键 (source_id, file_path)
type Favorite struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	SourceID  uint      `gorm:"not null;uniqueIndex:uk_favorite_source_path" json:"source_id"`
	FilePath  string    `gorm:"size:1024;not null;uniqueIndex:uk_favorite_source_path" json:"file_path"`
	MediaType string    `gorm:"size:32;not null;default:'';index" json:"media_type"` // video/audio/novel/comic/image/dir 等
	Size      int64     `gorm:"not null;default:0" json:"size"`
	CreatedAt time.Time `json:"created_at"`
}

// TableName 指定表名
func (Favorite) TableName() string { return "favorites" }
