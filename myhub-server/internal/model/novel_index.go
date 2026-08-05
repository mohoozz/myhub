package model

import "time"

// NovelIndex TXT 小说章节索引缓存表：唯一键 (source_id, file_path)
// chapters_json 为章节数组：[{title, start, end}, ...]，start/end 为字节区间
type NovelIndex struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	SourceID     uint      `gorm:"not null;uniqueIndex:uk_novel_index_source_path" json:"source_id"`
	FilePath     string    `gorm:"size:1024;not null;uniqueIndex:uk_novel_index_source_path" json:"file_path"`
	Encoding     string    `gorm:"size:32;not null;default:'utf-8'" json:"encoding"` // utf-8/gbk/big5 等
	ChaptersJSON string    `gorm:"type:text" json:"chapters_json"`
	FileSize     int64     `gorm:"not null;default:0" json:"file_size"` // 用于判断文件是否变更需重建索引
	CreatedAt    time.Time `json:"-"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// TableName 指定表名
func (NovelIndex) TableName() string { return "novel_indexes" }
