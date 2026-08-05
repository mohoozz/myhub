package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"gorm.io/gorm"

	"myhub-server/internal/adapter"
	"myhub-server/internal/config"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 路径源相关业务错误
var (
	ErrSourceNotFound  = errors.New("路径源不存在")
	ErrInvalidSource   = errors.New("路径源参数无效")
	ErrSourceForbidden = errors.New("挂载点不在白名单内")
)

// SourceService 路径源业务逻辑
type SourceService struct {
	cfg        *config.Config
	sourceRepo *repository.SourceRepository
}

// NewSourceService 创建 SourceService
func NewSourceService(cfg *config.Config, sourceRepo *repository.SourceRepository) *SourceService {
	return &SourceService{cfg: cfg, sourceRepo: sourceRepo}
}

// List 返回全部路径源
func (s *SourceService) List() ([]model.Source, error) {
	return s.sourceRepo.List()
}

// GetByID 按 ID 获取路径源
func (s *SourceService) GetByID(id uint) (*model.Source, error) {
	source, err := s.sourceRepo.GetByID(id)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrSourceNotFound
		}
		return nil, err
	}
	return source, nil
}

// validate 校验路径源字段，并通过适配器工厂做实例化预检（白名单/配置合法性）
func (s *SourceService) validate(source *model.Source) error {
	if strings.TrimSpace(source.Name) == "" {
		return fmt.Errorf("%w：名称不能为空", ErrInvalidSource)
	}

	switch source.Type {
	case model.SourceTypeLocal:
		if strings.TrimSpace(source.MountPoint) == "" {
			return fmt.Errorf("%w：本地路径源必须指定挂载点", ErrInvalidSource)
		}
	case model.SourceTypeWebDAV:
		var cfg adapter.WebDavConfig
		if err := json.Unmarshal([]byte(source.ConfigJSON), &cfg); err != nil {
			return fmt.Errorf("%w：WebDAV 配置 JSON 解析失败", ErrInvalidSource)
		}
		if strings.TrimSpace(cfg.URL) == "" {
			return fmt.Errorf("%w：WebDAV 配置缺少 url", ErrInvalidSource)
		}
	case model.SourceTypeOpenList:
		return fmt.Errorf("%w：OpenList 类型二期才支持", ErrInvalidSource)
	default:
		return fmt.Errorf("%w：未知类型 %q", ErrInvalidSource, source.Type)
	}

	// 实例化预检：local 校验白名单，webdav 校验配置格式
	if _, err := s.newAdapter(source); err != nil {
		if errors.Is(err, adapter.ErrForbidden) {
			return ErrSourceForbidden
		}
		return err
	}
	return nil
}

// newAdapter 根据路径源创建适配器实例
func (s *SourceService) newAdapter(source *model.Source) (adapter.IStorageAdapter, error) {
	return adapter.New(source, s.cfg.Storage.AllowedRoots)
}

// Create 创建路径源
func (s *SourceService) Create(source *model.Source) error {
	if err := s.validate(source); err != nil {
		return err
	}
	return s.sourceRepo.Create(source)
}

// Update 更新路径源（全量字段由调用方组装）
func (s *SourceService) Update(source *model.Source) error {
	if _, err := s.GetByID(source.ID); err != nil {
		return err
	}
	if err := s.validate(source); err != nil {
		return err
	}
	return s.sourceRepo.Update(source)
}

// Delete 删除路径源
func (s *SourceService) Delete(id uint) error {
	if _, err := s.GetByID(id); err != nil {
		return err
	}
	return s.sourceRepo.Delete(id)
}

// Test 连接测试：实例化适配器并调用 Test 验证挂载点可用
func (s *SourceService) Test(ctx context.Context, id uint) error {
	source, err := s.GetByID(id)
	if err != nil {
		return err
	}
	a, err := s.newAdapter(source)
	if err != nil {
		if errors.Is(err, adapter.ErrForbidden) {
			return ErrSourceForbidden
		}
		return err
	}
	return a.Test(ctx)
}

// GetAdapter 获取指定路径源的适配器实例（供文件管理等模块使用）
func (s *SourceService) GetAdapter(sourceID uint) (adapter.IStorageAdapter, *model.Source, error) {
	source, err := s.GetByID(sourceID)
	if err != nil {
		return nil, nil, err
	}
	if !source.Enabled {
		return nil, nil, fmt.Errorf("%w：路径源已停用", ErrInvalidSource)
	}
	a, err := s.newAdapter(source)
	if err != nil {
		return nil, nil, err
	}
	return a, source, nil
}
