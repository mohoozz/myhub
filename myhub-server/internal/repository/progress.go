package repository

import (
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"myhub-server/internal/model"
)

// ProgressRepository 阅读进度数据访问
type ProgressRepository struct {
	db *gorm.DB
}

// NewProgressRepository 创建 ProgressRepository
func NewProgressRepository(db *gorm.DB) *ProgressRepository {
	return &ProgressRepository{db: db}
}

// List 全部进度（按更新时间降序）
func (r *ProgressRepository) List() ([]model.ReadingProgress, error) {
	var items []model.ReadingProgress
	if err := r.db.Order("updated_at DESC").Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// GetByPath 按 (source_id, file_path) 查找进度
func (r *ProgressRepository) GetByPath(sourceID uint, filePath string) (*model.ReadingProgress, error) {
	var p model.ReadingProgress
	if err := r.db.Where("source_id = ? AND file_path = ?", sourceID, filePath).First(&p).Error; err != nil {
		return nil, err
	}
	return &p, nil
}

// Upsert 按唯一键 (source_id, file_path) 插入或更新进度
func (r *ProgressRepository) Upsert(p *model.ReadingProgress) error {
	return r.db.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "source_id"}, {Name: "file_path"}},
		DoUpdates: clause.AssignmentColumns([]string{
			"media_type", "title", "cover", "progress_json", "percent", "finished", "updated_at",
		}),
	}).Create(p).Error
}

// MarkFinished 标记已读完
func (r *ProgressRepository) MarkFinished(sourceID uint, filePath string) error {
	result := r.db.Model(&model.ReadingProgress{}).
		Where("source_id = ? AND file_path = ?", sourceID, filePath).
		Updates(map[string]interface{}{"finished": true, "percent": 100})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
