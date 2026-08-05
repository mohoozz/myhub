package repository

import (
	"gorm.io/gorm"

	"myhub-server/internal/model"
)

// FavoriteRepository 收藏数据访问
type FavoriteRepository struct {
	db *gorm.DB
}

// NewFavoriteRepository 创建 FavoriteRepository
func NewFavoriteRepository(db *gorm.DB) *FavoriteRepository {
	return &FavoriteRepository{db: db}
}

// List 收藏列表（按收藏时间降序，分页）
func (r *FavoriteRepository) List(offset, limit int) ([]model.Favorite, int64, error) {
	var total int64
	if err := r.db.Model(&model.Favorite{}).Count(&total).Error; err != nil {
		return nil, 0, err
	}
	var items []model.Favorite
	if err := r.db.Order("created_at DESC").Offset(offset).Limit(limit).Find(&items).Error; err != nil {
		return nil, 0, err
	}
	return items, total, nil
}

// GetByPath 按 (source_id, file_path) 查找收藏
func (r *FavoriteRepository) GetByPath(sourceID uint, filePath string) (*model.Favorite, error) {
	var fav model.Favorite
	if err := r.db.Where("source_id = ? AND file_path = ?", sourceID, filePath).First(&fav).Error; err != nil {
		return nil, err
	}
	return &fav, nil
}

// Exists 判断收藏是否已存在
func (r *FavoriteRepository) Exists(sourceID uint, filePath string) (bool, error) {
	var count int64
	if err := r.db.Model(&model.Favorite{}).Where("source_id = ? AND file_path = ?", sourceID, filePath).Count(&count).Error; err != nil {
		return false, err
	}
	return count > 0, nil
}

// Create 创建收藏
func (r *FavoriteRepository) Create(fav *model.Favorite) error {
	return r.db.Create(fav).Error
}

// Delete 按 (source_id, file_path) 删除收藏
func (r *FavoriteRepository) Delete(sourceID uint, filePath string) error {
	result := r.db.Where("source_id = ? AND file_path = ?", sourceID, filePath).Delete(&model.Favorite{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
