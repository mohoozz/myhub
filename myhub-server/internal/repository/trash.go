package repository

import (
	"time"

	"gorm.io/gorm"

	"myhub-server/internal/model"
)

// TrashRepository 回收站数据访问
type TrashRepository struct {
	db *gorm.DB
}

// NewTrashRepository 创建 TrashRepository
func NewTrashRepository(db *gorm.DB) *TrashRepository {
	return &TrashRepository{db: db}
}

// List 回收站列表，sourceID 为 0 时不过滤；按删除时间降序
func (r *TrashRepository) List(sourceID uint) ([]model.TrashItem, error) {
	var items []model.TrashItem
	q := r.db.Order("deleted_at DESC")
	if sourceID > 0 {
		q = q.Where("source_id = ?", sourceID)
	}
	if err := q.Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// GetByID 按 ID 查找回收站条目
func (r *TrashRepository) GetByID(id uint) (*model.TrashItem, error) {
	var item model.TrashItem
	if err := r.db.First(&item, id).Error; err != nil {
		return nil, err
	}
	return &item, nil
}

// Create 创建回收站条目
func (r *TrashRepository) Create(item *model.TrashItem) error {
	return r.db.Create(item).Error
}

// Delete 按 ID 删除条目
func (r *TrashRepository) Delete(id uint) error {
	result := r.db.Delete(&model.TrashItem{}, id)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

// DeleteAll 清空回收站，返回被删除的条目（调用方需先查出来删物理文件）
func (r *TrashRepository) DeleteAll(sourceID uint) error {
	q := r.db.Where("1 = 1")
	if sourceID > 0 {
		q = q.Where("source_id = ?", sourceID)
	}
	return q.Delete(&model.TrashItem{}).Error
}

// DeleteExpired 删除 deleted_at 早于 cutoff 的条目，返回条目列表（供物理删除）
func (r *TrashRepository) ListExpired(cutoff time.Time) ([]model.TrashItem, error) {
	var items []model.TrashItem
	if err := r.db.Where("deleted_at < ?", cutoff).Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}
