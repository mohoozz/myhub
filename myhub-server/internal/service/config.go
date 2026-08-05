package service

import (
	"errors"
	"strings"

	"myhub-server/internal/repository"
)

// ErrInternalConfigKey 内部保留键不允许经配置接口读写
var ErrInternalConfigKey = errors.New("该配置键为内部保留，不允许修改")

// internalConfigPrefixes 内部保留键前缀（如漫画覆盖标记），不出现在配置接口
var internalConfigPrefixes = []string{"comic_override:"}

// ConfigService 系统配置业务逻辑
type ConfigService struct {
	configRepo *repository.ConfigRepository
}

// NewConfigService 创建 ConfigService
func NewConfigService(configRepo *repository.ConfigRepository) *ConfigService {
	return &ConfigService{configRepo: configRepo}
}

// isInternalKey 判断是否为内部保留键
func isInternalKey(key string) bool {
	for _, p := range internalConfigPrefixes {
		if strings.HasPrefix(key, p) {
			return true
		}
	}
	return false
}

// All 返回全部用户配置（过滤内部保留键），map 形式
func (s *ConfigService) All() (map[string]string, error) {
	items, err := s.configRepo.All()
	if err != nil {
		return nil, err
	}
	result := make(map[string]string, len(items))
	for _, item := range items {
		if isInternalKey(item.Key) {
			continue
		}
		result[item.Key] = item.Value
	}
	return result, nil
}

// BatchUpdate 批量更新配置（键或值为空跳过；内部键报错）
func (s *ConfigService) BatchUpdate(kv map[string]string) error {
	for k, v := range kv {
		if k == "" {
			continue
		}
		if isInternalKey(k) {
			return ErrInternalConfigKey
		}
		if err := s.configRepo.Set(k, v); err != nil {
			return err
		}
	}
	return nil
}
