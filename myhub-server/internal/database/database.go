// Package database 负责 GORM + SQLite 数据库的初始化与迁移。
// 使用纯 Go 的 glebarez/sqlite 驱动，无需 CGO，方便 Windows 与交叉编译。
package database

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Init 打开 SQLite 数据库并配置连接池。
// 会自动创建数据库文件所在的父目录（如 data/）。
func Init(dbPath string) (*gorm.DB, error) {
	// 自动创建数据目录
	dir := filepath.Dir(dbPath)
	if dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("创建数据库目录失败: %w", err)
		}
	}

	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	})
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}

	// 连接池配置：SQLite 单写者，限制为 1 个连接最稳定
	sqlDB, err := db.DB()
	if err != nil {
		return nil, fmt.Errorf("获取底层连接失败: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)

	return db, nil
}

// Migrate 自动迁移入口，后续新增模型时在调用处追加即可，例如：
//
//	database.Migrate(db, &model.User{}, &model.Source{})
func Migrate(db *gorm.DB, models ...interface{}) error {
	if len(models) == 0 {
		return nil
	}
	return db.AutoMigrate(models...)
}
