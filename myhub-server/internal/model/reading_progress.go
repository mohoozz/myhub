package model

import "time"

// ReadingProgress 阅读/播放进度表：唯一键 (source_id, file_path)
// progress_json 存放各类型专属进度数据（章节号、播放秒数、漫画页码等）
type ReadingProgress struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	SourceID     uint      `gorm:"not null;uniqueIndex:uk_progress_source_path" json:"source_id"`
	FilePath     string    `gorm:"size:1024;not null;uniqueIndex:uk_progress_source_path" json:"file_path"`
	MediaType    string    `gorm:"size:32;not null;index" json:"media_type"` // novel/comic/video/audio
	Title        string    `gorm:"size:512" json:"title"`
	Cover        string    `gorm:"size:1024" json:"cover"` // 封面 URL 或缩略图路径
	ProgressJSON string    `gorm:"type:text" json:"progress_json"`
	Percent      float64   `gorm:"not null;default:0" json:"percent"` // 0~100
	Finished     bool      `gorm:"not null;default:false" json:"finished"`
	UpdatedAt    time.Time `gorm:"index" json:"updated_at"`
	CreatedAt    time.Time `json:"-"`
}

// TableName 指定表名
func (ReadingProgress) TableName() string { return "reading_progress" }
