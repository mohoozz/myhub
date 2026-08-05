package service

import (
	"context"
	"errors"
	"log"
	"time"

	"gorm.io/gorm"

	"myhub-server/internal/adapter"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 回收站相关业务错误
var ErrTrashItemNotFound = errors.New("回收站条目不存在")

// TrashService 回收站业务逻辑
type TrashService struct {
	sourceSvc *SourceService
	trashRepo *repository.TrashRepository
}

// NewTrashService 创建 TrashService
func NewTrashService(sourceSvc *SourceService, trashRepo *repository.TrashRepository) *TrashService {
	return &TrashService{sourceSvc: sourceSvc, trashRepo: trashRepo}
}

// List 回收站列表，sourceID 为 0 时返回全部
func (s *TrashService) List(sourceID uint) ([]model.TrashItem, error) {
	return s.trashRepo.List(sourceID)
}

// getItem 按 ID 获取条目
func (s *TrashService) getItem(id uint) (*model.TrashItem, error) {
	item, err := s.trashRepo.GetByID(id)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrTrashItemNotFound
		}
		return nil, err
	}
	return item, nil
}

// Restore 还原：从 .trash/ 移回原路径，成功后删除记录
func (s *TrashService) Restore(ctx context.Context, id uint) error {
	item, err := s.getItem(id)
	if err != nil {
		return err
	}
	a, _, err := s.sourceSvc.GetAdapter(item.SourceID)
	if err != nil {
		return err
	}
	if err := a.Restore(ctx, item.TrashPath, item.OriginalPath); err != nil {
		return err
	}
	return s.trashRepo.Delete(id)
}

// Purge 彻底删除单个条目（物理删除 + 删除记录）
func (s *TrashService) Purge(ctx context.Context, id uint) error {
	item, err := s.getItem(id)
	if err != nil {
		return err
	}
	if err := s.purgeItem(ctx, item); err != nil {
		return err
	}
	return s.trashRepo.Delete(id)
}

// Clear 清空回收站（可按 sourceID 过滤）：先物理删除，后清记录
func (s *TrashService) Clear(ctx context.Context, sourceID uint) error {
	items, err := s.trashRepo.List(sourceID)
	if err != nil {
		return err
	}
	for _, item := range items {
		if err := s.purgeItem(ctx, &item); err != nil {
			return err
		}
	}
	return s.trashRepo.DeleteAll(sourceID)
}

// purgeItem 物理删除回收站文件；文件已不存在时视为成功（记录由调用方清理）
func (s *TrashService) purgeItem(ctx context.Context, item *model.TrashItem) error {
	a, _, err := s.sourceSvc.GetAdapter(item.SourceID)
	if err != nil {
		return err
	}
	if err := a.Purge(ctx, item.TrashPath); err != nil && !errors.Is(err, adapter.ErrNotExist) {
		return err
	}
	return nil
}

// CleanupExpired 定时清理：彻底删除超过 retentionDays 天的条目。
// 单个条目失败仅记录日志，不中断整体清理；失败的记录保留待下次重试。
func (s *TrashService) CleanupExpired(ctx context.Context, retentionDays int) {
	if retentionDays <= 0 {
		retentionDays = 30
	}
	cutoff := time.Now().Add(-time.Duration(retentionDays) * 24 * time.Hour)
	items, err := s.trashRepo.ListExpired(cutoff)
	if err != nil {
		log.Printf("回收站定时清理：查询过期条目失败: %v", err)
		return
	}
	if len(items) == 0 {
		return
	}

	cleaned := 0
	for _, item := range items {
		if err := s.purgeItem(ctx, &item); err != nil {
			log.Printf("回收站定时清理：物理删除失败 id=%d path=%s: %v", item.ID, item.TrashPath, err)
			continue
		}
		if err := s.trashRepo.Delete(item.ID); err != nil {
			log.Printf("回收站定时清理：删除记录失败 id=%d: %v", item.ID, err)
			continue
		}
		cleaned++
	}
	log.Printf("回收站定时清理完成：共 %d 条过期，清理 %d 条", len(items), cleaned)
}
