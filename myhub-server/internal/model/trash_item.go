package model

import "time"

// TrashItem 回收站条目：记录被逻辑删除的文件的原始位置与回收站位置
type TrashItem struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	SourceID     uint      `gorm:"not null;index" json:"source_id"`
	OriginalPath string    `gorm:"size:1024;not null" json:"original_path"` // 删除前路径
	TrashPath    string    `gorm:"size:1024;not null" json:"trash_path"`    // .trash/ 内路径
	Size         int64     `gorm:"not null;default:0" json:"size"`
	DeletedAt    time.Time `gorm:"not null;index" json:"deleted_at"`
}

// TableName 指定表名
func (TrashItem) TableName() string { return "trash_items" }
