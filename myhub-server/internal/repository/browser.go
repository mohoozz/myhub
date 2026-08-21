package repository

import (
	"gorm.io/gorm"

	"myhub-server/internal/model"
)

// BrowserRepository 浏览器书签/历史/快捷入口数据访问
type BrowserRepository struct {
	db *gorm.DB
}

// NewBrowserRepository 创建 BrowserRepository
func NewBrowserRepository(db *gorm.DB) *BrowserRepository {
	return &BrowserRepository{db: db}
}

// ---------- 书签 ----------

// ListBookmarks 书签列表（按创建时间降序）
func (r *BrowserRepository) ListBookmarks() ([]model.Bookmark, error) {
	var items []model.Bookmark
	if err := r.db.Order("created_at DESC, id DESC").Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// GetBookmarkByURL 按 URL 查找书签
func (r *BrowserRepository) GetBookmarkByURL(url string) (*model.Bookmark, error) {
	var b model.Bookmark
	if err := r.db.Where("url = ?", url).First(&b).Error; err != nil {
		return nil, err
	}
	return &b, nil
}

// GetBookmarkByID 按 ID 查找书签
func (r *BrowserRepository) GetBookmarkByID(id uint) (*model.Bookmark, error) {
	var b model.Bookmark
	if err := r.db.First(&b, id).Error; err != nil {
		return nil, err
	}
	return &b, nil
}

// SaveBookmark 创建或保存书签（有主键更新，无主键插入）
func (r *BrowserRepository) SaveBookmark(b *model.Bookmark) error {
	return r.db.Save(b).Error
}

// DeleteBookmarkByID 按 ID 删除书签，未命中返回 gorm.ErrRecordNotFound
func (r *BrowserRepository) DeleteBookmarkByID(id uint) error {
	result := r.db.Delete(&model.Bookmark{}, id)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

// DeleteBookmarkByURL 按 URL 删除书签，未命中返回 gorm.ErrRecordNotFound
func (r *BrowserRepository) DeleteBookmarkByURL(url string) error {
	result := r.db.Where("url = ?", url).Delete(&model.Bookmark{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

// ---------- 历史 ----------

// ListHistory 历史游标分页：按 (visited_ms, id) 降序。
// hasCursor 为 true 时仅取游标之前的记录（不含游标记录本身）。
func (r *BrowserRepository) ListHistory(beforeMs int64, beforeID uint, hasCursor bool, limit int) ([]model.BrowserHistory, error) {
	q := r.db.Model(&model.BrowserHistory{}).Order("visited_ms DESC, id DESC").Limit(limit)
	if hasCursor {
		q = q.Where("visited_ms < ? OR (visited_ms = ? AND id < ?)", beforeMs, beforeMs, beforeID)
	}
	var items []model.BrowserHistory
	if err := q.Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// CreateHistoryItems 批量写入访问历史
func (r *BrowserRepository) CreateHistoryItems(items []model.BrowserHistory) error {
	if len(items) == 0 {
		return nil
	}
	return r.db.Create(&items).Error
}

// DeleteHistoryByID 按 ID 删除单条历史，未命中返回 gorm.ErrRecordNotFound
func (r *BrowserRepository) DeleteHistoryByID(id uint) error {
	result := r.db.Delete(&model.BrowserHistory{}, id)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

// ClearHistory 清空全部历史
func (r *BrowserRepository) ClearHistory() error {
	return r.db.Where("1 = 1").Delete(&model.BrowserHistory{}).Error
}

// ---------- 快捷入口 ----------

// ListShortcuts 快捷入口列表（按 sort_order 升序、id 升序）
func (r *BrowserRepository) ListShortcuts() ([]model.BrowserShortcut, error) {
	var items []model.BrowserShortcut
	if err := r.db.Order("sort_order ASC, id ASC").Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// GetShortcutByID 按 ID 查找快捷入口
func (r *BrowserRepository) GetShortcutByID(id uint) (*model.BrowserShortcut, error) {
	var s model.BrowserShortcut
	if err := r.db.First(&s, id).Error; err != nil {
		return nil, err
	}
	return &s, nil
}

// GetShortcutByURL 按 URL 查找快捷入口
func (r *BrowserRepository) GetShortcutByURL(url string) (*model.BrowserShortcut, error) {
	var s model.BrowserShortcut
	if err := r.db.Where("url = ?", url).First(&s).Error; err != nil {
		return nil, err
	}
	return &s, nil
}

// MaxShortcutOrder 当前最大 sort_order（空表返回 0）
func (r *BrowserRepository) MaxShortcutOrder() (int, error) {
	var max int
	if err := r.db.Model(&model.BrowserShortcut{}).
		Select("COALESCE(MAX(sort_order), 0)").Scan(&max).Error; err != nil {
		return 0, err
	}
	return max, nil
}

// SaveShortcut 创建或保存快捷入口（有主键更新，无主键插入）
func (r *BrowserRepository) SaveShortcut(s *model.BrowserShortcut) error {
	return r.db.Save(s).Error
}

// UpdateShortcutOrders 按 ids 顺序批量重排（sort_order = 数组下标）
func (r *BrowserRepository) UpdateShortcutOrders(ids []uint) error {
	if len(ids) == 0 {
		return nil
	}
	return r.db.Transaction(func(tx *gorm.DB) error {
		for i, id := range ids {
			if err := tx.Model(&model.BrowserShortcut{}).
				Where("id = ?", id).Update("sort_order", i).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

// DeleteShortcutByID 按 ID 删除快捷入口，未命中返回 gorm.ErrRecordNotFound
func (r *BrowserRepository) DeleteShortcutByID(id uint) error {
	result := r.db.Delete(&model.BrowserShortcut{}, id)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
