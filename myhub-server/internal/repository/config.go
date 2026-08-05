package repository

import (
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"myhub-server/internal/model"
)

// ConfigRepository 应用配置（键值对）数据访问
type ConfigRepository struct {
	db *gorm.DB
}

// NewConfigRepository 创建 ConfigRepository
func NewConfigRepository(db *gorm.DB) *ConfigRepository {
	return &ConfigRepository{db: db}
}

// Get 按键取值，不存在返回空字符串 + nil 错误
func (r *ConfigRepository) Get(key string) (string, error) {
	var cfg model.AppConfig
	err := r.db.Where("key = ?", key).First(&cfg).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return "", nil
		}
		return "", err
	}
	return cfg.Value, nil
}

// Set 设置键值（存在则更新）
func (r *ConfigRepository) Set(key, value string) error {
	return r.db.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "key"}},
		DoUpdates: clause.AssignmentColumns([]string{"value", "updated_at"}),
	}).Create(&model.AppConfig{Key: key, Value: value}).Error
}

// Delete 删除键
func (r *ConfigRepository) Delete(key string) error {
	return r.db.Where("key = ?", key).Delete(&model.AppConfig{}).Error
}

// All 返回全部配置
func (r *ConfigRepository) All() ([]model.AppConfig, error) {
	var cfgs []model.AppConfig
	if err := r.db.Find(&cfgs).Error; err != nil {
		return nil, err
	}
	return cfgs, nil
}
