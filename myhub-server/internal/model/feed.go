package model

import "time"

// FeedSubscription 动态订阅源表（二期 M5）
type FeedSubscription struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	Platform     string    `gorm:"size:32;not null;index" json:"platform"` // bilibili/youtube/douyin
	Name         string    `gorm:"size:128;not null" json:"name"`          // 订阅源显示名（如 UP 主名）
	Target       string    `gorm:"size:512;not null" json:"target"`        // 抓取目标（UP主ID/频道ID/主页URL）
	CronExpr     string    `gorm:"size:64;not null;default:'0 */6 * * *'" json:"cron_expr"` // 抓取频率
	Enabled      bool      `gorm:"not null;default:true" json:"enabled"`
	LastFetchedAt *time.Time `json:"last_fetched_at"` // 上次抓取时间，用于增量抓取
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"-"`
}

// TableName 指定表名
func (FeedSubscription) TableName() string { return "feed_subscriptions" }

// FeedItem 动态条目表：唯一键 (platform, content_id)
type FeedItem struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	Platform    string    `gorm:"size:32;not null;uniqueIndex:uk_feed_platform_content;index" json:"platform"`
	ContentID   string    `gorm:"size:128;not null;uniqueIndex:uk_feed_platform_content" json:"content_id"` // 平台内唯一 ID（BV号/视频ID）
	MediaType   string    `gorm:"size:32;not null;default:'video';index" json:"media_type"`                 // video/audio/article
	Author      string    `gorm:"size:128" json:"author"`
	Title       string    `gorm:"size:512;not null" json:"title"`
	Cover       string    `gorm:"size:1024" json:"cover"`
	URL         string    `gorm:"size:1024" json:"url"` // 原站链接
	Description string    `gorm:"type:text" json:"description"`
	PublishedAt time.Time `gorm:"not null;index" json:"published_at"` // 平台发布时间
	CreatedAt   time.Time `json:"created_at"`
	// SourceID 记录 myhub-feed 源库的条目自增 id，用于增量同步（since_id）游标。
	// 不参与业务序列化，也不作为本地主键（本地 ID 独立自增，供前端游标分页）。
	SourceID uint `gorm:"index" json:"-"`
}

// TableName 指定表名
func (FeedItem) TableName() string { return "feed_items" }

// FeedCursor 已读游标表（单行，记录"已看到此处"锚点）
type FeedCursor struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	FeedItemID uint     `gorm:"not null;default:0" json:"feed_item_id"` // 已读到的最新条目
	ReadAt    time.Time `json:"read_at"`                                // 游标对应条目的发布时间
	UpdatedAt time.Time `json:"updated_at"`
}

// TableName 指定表名
func (FeedCursor) TableName() string { return "feed_cursors" }

// WatchLater 稍后观看表：唯一键 (platform, content_id)
type WatchLater struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Platform  string    `gorm:"size:32;not null;uniqueIndex:uk_watch_later_platform_content" json:"platform"`
	ContentID string    `gorm:"size:128;not null;uniqueIndex:uk_watch_later_platform_content" json:"content_id"`
	CreatedAt time.Time `json:"created_at"`
}

// TableName 指定表名
func (WatchLater) TableName() string { return "watch_later" }

// FeedFetchLog 抓取任务日志表
type FeedFetchLog struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	SubscriptionID uint      `gorm:"not null;index" json:"subscription_id"`
	Status         string    `gorm:"size:16;not null" json:"status"` // success/failed/running
	NewItems       int       `gorm:"not null;default:0" json:"new_items"` // 本次新增条数
	Message        string    `gorm:"type:text" json:"message"`            // 错误或附加信息
	StartedAt      time.Time `gorm:"not null" json:"started_at"`
	FinishedAt     *time.Time `json:"finished_at"`
}

// TableName 指定表名
func (FeedFetchLog) TableName() string { return "feed_fetch_logs" }
