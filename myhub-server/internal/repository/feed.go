package repository

import (
	"time"

	"gorm.io/gorm"

	"myhub-server/internal/model"
)

// FeedRepository 动态模块数据访问：已读游标、稍后观看、items 本地缓存。
type FeedRepository struct {
	db *gorm.DB
}

// NewFeedRepository 创建 FeedRepository
func NewFeedRepository(db *gorm.DB) *FeedRepository {
	return &FeedRepository{db: db}
}

// ---------- 动态条目（本地缓存 myhub-feed 同步结果） ----------

// UpsertItem 按 (platform, content_id) 幂等写入动态条目，冲突时跳过。
// 返回 true 表示新插入（此前不存在）。
func (r *FeedRepository) UpsertItem(item *model.FeedItem) (bool, error) {
	var count int64
	err := r.db.Model(&model.FeedItem{}).
		Where("platform = ? AND content_id = ?", item.Platform, item.ContentID).
		Count(&count).Error
	if err != nil {
		return false, err
	}
	if count > 0 {
		return false, nil
	}
	if err := r.db.Create(item).Error; err != nil {
		return false, err
	}
	return true, nil
}

// MaxSourceID 返回本地已缓存的 myhub-feed 源库最大条目 id（作为增量同步游标）。
// myhub-feed 的 /api/items 以 since_id 增量返回，本地记录其源库自增 id 最大值。
func (r *FeedRepository) MaxSourceID() (uint, error) {
	var maxID uint
	if err := r.db.Model(&model.FeedItem{}).Select("COALESCE(MAX(source_id), 0)").Scan(&maxID).Error; err != nil {
		return 0, err
	}
	return maxID, nil
}

// ListItems 按发布时间降序 + id 降序分页（游标为 beforeID）。
func (r *FeedRepository) ListItems(beforeID uint, limit int) ([]model.FeedItem, error) {
	var items []model.FeedItem
	q := r.db.Order("published_at DESC").Order("id DESC").Limit(limit)
	if beforeID > 0 {
		q = q.Where("id < ?", beforeID)
	}
	if err := q.Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// GetItem 按 id 取单条动态。
func (r *FeedRepository) GetItem(id uint) (*model.FeedItem, error) {
	var item model.FeedItem
	if err := r.db.First(&item, id).Error; err != nil {
		return nil, err
	}
	return &item, nil
}

// GetItemByKey 按 (platform, content_id) 取单条动态。
func (r *FeedRepository) GetItemByKey(platform, contentID string) (*model.FeedItem, error) {
	var item model.FeedItem
	if err := r.db.Where("platform = ? AND content_id = ?", platform, contentID).
		First(&item).Error; err != nil {
		return nil, err
	}
	return &item, nil
}

// ---------- 已读游标 ----------

// GetCursor 获取已读游标（单行），不存在返回零值。
func (r *FeedRepository) GetCursor() (*model.FeedCursor, error) {
	var c model.FeedCursor
	if err := r.db.First(&c).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return &model.FeedCursor{}, nil
		}
		return nil, err
	}
	return &c, nil
}

// SaveCursor 保存已读游标（upsert 单行）。
func (r *FeedRepository) SaveCursor(feedItemID uint, readAt time.Time) error {
	c, err := r.GetCursor()
	if err != nil {
		return err
	}
	c.FeedItemID = feedItemID
	c.ReadAt = readAt
	return r.db.Save(c).Error
}

// ---------- 稍后观看 ----------

// ListWatchLater 稍后观看列表（按加入时间降序），关联动态条目详情。
func (r *FeedRepository) ListWatchLater(limit int) ([]model.WatchLater, error) {
	var list []model.WatchLater
	if err := r.db.Order("id DESC").Limit(limit).Find(&list).Error; err != nil {
		return nil, err
	}
	return list, nil
}

// ExistsWatchLater 判断是否已在稍后观看。
func (r *FeedRepository) ExistsWatchLater(platform, contentID string) (bool, error) {
	var count int64
	if err := r.db.Model(&model.WatchLater{}).
		Where("platform = ? AND content_id = ?", platform, contentID).
		Count(&count).Error; err != nil {
		return false, err
	}
	return count > 0, nil
}

// AddWatchLater 加入稍后观看。
func (r *FeedRepository) AddWatchLater(platform, contentID string) (*model.WatchLater, error) {
	w := &model.WatchLater{Platform: platform, ContentID: contentID}
	if err := r.db.Create(w).Error; err != nil {
		return nil, err
	}
	return w, nil
}

// RemoveWatchLater 移出稍后观看；不存在返回 gorm.ErrRecordNotFound。
func (r *FeedRepository) RemoveWatchLater(platform, contentID string) error {
	res := r.db.Where("platform = ? AND content_id = ?", platform, contentID).
		Delete(&model.WatchLater{})
	if res.Error != nil {
		return res.Error
	}
	if res.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
