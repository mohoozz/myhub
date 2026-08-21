package model

import "time"

// Bookmark 浏览器书签：URL 唯一，重复添加幂等（更新标题/favicon 后返回既有记录）
type Bookmark struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Title     string    `gorm:"size:512;not null;default:''" json:"title"`
	URL       string    `gorm:"size:2048;not null;uniqueIndex:uk_bookmark_url" json:"url"`
	Favicon   string    `gorm:"size:16384;not null;default:''" json:"favicon"`
	CreatedAt time.Time `json:"created_at"`
}

// TableName 指定表名
func (Bookmark) TableName() string { return "browser_bookmarks" }

// BrowserHistory 浏览器访问历史。
// VisitedMs 为 visited_at 的毫秒时间戳冗余列，排序与游标分页基于它进行，
// 规避 SQLite 时间字符串比较的精度/时区陷阱。
type BrowserHistory struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Title     string    `gorm:"size:512;not null;default:''" json:"title"`
	URL       string    `gorm:"size:2048;not null;index:idx_history_url" json:"url"`
	Favicon   string    `gorm:"size:16384;not null;default:''" json:"favicon"`
	VisitedAt time.Time `gorm:"not null;index:idx_history_visited" json:"visited_at"`
	VisitedMs int64     `gorm:"not null;index:idx_history_visited_ms" json:"visited_ms"`
}

// TableName 指定表名
func (BrowserHistory) TableName() string { return "browser_history" }

// BrowserShortcut 起始页快捷入口：URL 唯一，按 sort_order 升序展示
type BrowserShortcut struct {
	ID        uint   `gorm:"primaryKey" json:"id"`
	Title     string `gorm:"size:512;not null" json:"title"`
	URL       string `gorm:"size:2048;not null;uniqueIndex:uk_shortcut_url" json:"url"`
	SortOrder int    `gorm:"not null;default:0" json:"sort_order"`
}

// TableName 指定表名
func (BrowserShortcut) TableName() string { return "browser_shortcuts" }
