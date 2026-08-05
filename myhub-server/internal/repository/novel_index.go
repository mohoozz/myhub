package repository

import (
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"myhub-server/internal/model"
)

// NovelIndexRepository 小说章节索引缓存数据访问
type NovelIndexRepository struct {
	db *gorm.DB
}

// NewNovelIndexRepository 创建 NovelIndexRepository
func NewNovelIndexRepository(db *gorm.DB) *NovelIndexRepository {
	return &NovelIndexRepository{db: db}
}

// GetByPath 按 (source_id, file_path) 查找索引
func (r *NovelIndexRepository) GetByPath(sourceID uint, filePath string) (*model.NovelIndex, error) {
	var idx model.NovelIndex
	if err := r.db.Where("source_id = ? AND file_path = ?", sourceID, filePath).First(&idx).Error; err != nil {
		return nil, err
	}
	return &idx, nil
}

// Upsert 按唯一键 (source_id, file_path) 插入或更新索引
func (r *NovelIndexRepository) Upsert(idx *model.NovelIndex) error {
	return r.db.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "source_id"}, {Name: "file_path"}},
		DoUpdates: clause.AssignmentColumns([]string{"encoding", "chapters_json", "file_size", "updated_at"}),
	}).Create(idx).Error
}

// DeleteByPath 删除索引（文件变更时失效）
func (r *NovelIndexRepository) DeleteByPath(sourceID uint, filePath string) error {
	return r.db.Where("source_id = ? AND file_path = ?", sourceID, filePath).Delete(&model.NovelIndex{}).Error
}
