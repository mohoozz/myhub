package repository

import (
	"strings"

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

// UpdatePathPrefix 把路径前缀（含子路径）从 oldPrefix 改写为 newPrefix。
// 用于文件/目录移动或重命名后同步阅读进度的路径，避免"正在阅读"历史失效。
// 返回受影响的记录数；oldPrefix == newPrefix 或前缀为空时直接返回 0。
func (r *ProgressRepository) UpdatePathPrefix(sourceID uint, oldPrefix, newPrefix string) (int64, error) {
	oldPrefix = strings.TrimSuffix(oldPrefix, "/")
	newPrefix = strings.TrimSuffix(newPrefix, "/")
	if oldPrefix == "" || newPrefix == "" || oldPrefix == newPrefix {
		return 0, nil
	}
	var rows []model.ReadingProgress
	if err := r.db.
		Where("source_id = ? AND (file_path = ? OR file_path LIKE ?)",
			sourceID, oldPrefix, oldPrefix+"/%").
		Find(&rows).Error; err != nil {
		return 0, err
	}
	for _, row := range rows {
		newPath := newPrefix + strings.TrimPrefix(row.FilePath, oldPrefix)
		// 目标位置若已有进度（如同名覆盖），先移除旧记录，以移动后的文件进度为准。
		if err := r.db.
			Where("source_id = ? AND file_path = ?", sourceID, newPath).
			Delete(&model.ReadingProgress{}).Error; err != nil {
			return 0, err
		}
		if err := r.db.Model(&model.ReadingProgress{}).
			Where("source_id = ? AND file_path = ?", sourceID, row.FilePath).
			Update("file_path", newPath).Error; err != nil {
			return 0, err
		}
	}
	return int64(len(rows)), nil
}

// Delete 删除进度记录：按路径前缀删除（含目录下所有子文件的进度）。
// 传入目录路径时同时清理其全部子项，传入文件路径时仅删除该文件记录。
func (r *ProgressRepository) Delete(sourceID uint, filePath string) error {
	prefix := strings.TrimSuffix(filePath, "/")
	if prefix == "" {
		return nil
	}
	result := r.db.
		Where("source_id = ? AND (file_path = ? OR file_path LIKE ?)",
			sourceID, prefix, prefix+"/%").
		Delete(&model.ReadingProgress{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
