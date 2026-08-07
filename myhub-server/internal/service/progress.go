package service

import (
	"errors"

	"gorm.io/gorm"

	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 进度相关业务错误
var (
	ErrProgressNotFound = errors.New("进度记录不存在")
	ErrInvalidProgress  = errors.New("进度参数无效")
)

// ProgressService 阅读进度业务逻辑
type ProgressService struct {
	progressRepo *repository.ProgressRepository
}

// NewProgressService 创建 ProgressService
func NewProgressService(progressRepo *repository.ProgressRepository) *ProgressService {
	return &ProgressService{progressRepo: progressRepo}
}

// List 全部进度（按更新时间降序）
func (s *ProgressService) List() ([]model.ReadingProgress, error) {
	return s.progressRepo.List()
}

// Save 保存/更新进度（upsert）
func (s *ProgressService) Save(p *model.ReadingProgress) error {
	if p.SourceID == 0 || p.FilePath == "" {
		return ErrInvalidProgress
	}
	switch p.MediaType {
	case "novel", "comic", "video", "audio":
	default:
		return ErrInvalidProgress
	}
	if p.Percent < 0 || p.Percent > 100 {
		return ErrInvalidProgress
	}
	if p.Percent >= 100 {
		p.Finished = true
	}
	return s.progressRepo.Upsert(p)
}

// Delete 删除阅读记录
func (s *ProgressService) Delete(sourceID uint, filePath string) error {
	if err := s.progressRepo.Delete(sourceID, filePath); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrProgressNotFound
		}
		return err
	}
	return nil
}
