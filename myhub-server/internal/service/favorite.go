package service

import (
	"context"
	"errors"

	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 收藏相关业务错误
var (
	ErrFavoriteExists   = errors.New("已收藏过该文件")
	ErrFavoriteNotFound = errors.New("收藏不存在")
)

// FavoriteService 收藏业务逻辑
type FavoriteService struct {
	sourceSvc *SourceService
	favRepo   *repository.FavoriteRepository
}

// NewFavoriteService 创建 FavoriteService
func NewFavoriteService(sourceSvc *SourceService, favRepo *repository.FavoriteRepository) *FavoriteService {
	return &FavoriteService{sourceSvc: sourceSvc, favRepo: favRepo}
}

// List 收藏列表（分页，按收藏时间降序）
func (s *FavoriteService) List(page, pageSize int) ([]model.Favorite, int64, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 200 {
		pageSize = 50
	}
	return s.favRepo.List((page-1)*pageSize, pageSize)
}

// Add 添加收藏：先 Stat 验证文件存在并取元信息，再查重入库
func (s *FavoriteService) Add(ctx context.Context, sourceID uint, filePath string) (*model.Favorite, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	fi, err := a.Stat(ctx, filePath)
	if err != nil {
		return nil, err
	}

	exists, err := s.favRepo.Exists(sourceID, filePath)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, ErrFavoriteExists
	}

	fav := &model.Favorite{
		SourceID:  sourceID,
		FilePath:  filePath,
		MediaType: DetectMediaType(fi.Name, fi.IsDir),
		Size:      fi.Size,
	}
	if err := s.favRepo.Create(fav); err != nil {
		return nil, err
	}
	return fav, nil
}

// Remove 取消收藏
func (s *FavoriteService) Remove(sourceID uint, filePath string) error {
	if err := s.favRepo.Delete(sourceID, filePath); err != nil {
		return ErrFavoriteNotFound
	}
	return nil
}
