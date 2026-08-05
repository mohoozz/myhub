package repository

import (
	"gorm.io/gorm"

	"myhub-server/internal/model"
)

// SourceRepository 路径源数据访问
type SourceRepository struct {
	db *gorm.DB
}

// NewSourceRepository 创建 SourceRepository
func NewSourceRepository(db *gorm.DB) *SourceRepository {
	return &SourceRepository{db: db}
}

// List 返回全部路径源（按创建时间升序）
func (r *SourceRepository) List() ([]model.Source, error) {
	var sources []model.Source
	if err := r.db.Order("created_at ASC").Find(&sources).Error; err != nil {
		return nil, err
	}
	return sources, nil
}

// GetByID 按 ID 查找路径源，未找到返回 gorm.ErrRecordNotFound
func (r *SourceRepository) GetByID(id uint) (*model.Source, error) {
	var source model.Source
	if err := r.db.First(&source, id).Error; err != nil {
		return nil, err
	}
	return &source, nil
}

// Create 创建路径源
func (r *SourceRepository) Create(source *model.Source) error {
	return r.db.Create(source).Error
}

// Update 按 ID 更新路径源（仅更新非零字段由调用方控制）
func (r *SourceRepository) Update(source *model.Source) error {
	return r.db.Save(source).Error
}

// Delete 按 ID 删除路径源
func (r *SourceRepository) Delete(id uint) error {
	result := r.db.Delete(&model.Source{}, id)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
