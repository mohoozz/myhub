// myhub-server 服务入口：加载配置 → 初始化数据库 → 注册路由 → 启动服务（含优雅关闭）。
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/robfig/cron/v3"

	"myhub-server/internal/config"
	"myhub-server/internal/database"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
	"myhub-server/internal/router"
	"myhub-server/internal/service"
)

func main() {
	// 1. 加载配置（config.yaml + 环境变量覆盖）
	cfg, err := config.Load("")
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}

	// 2. 初始化数据库（自动创建 data 目录、配置连接池）
	db, err := database.Init(cfg.Database.Path)
	if err != nil {
		log.Fatalf("初始化数据库失败: %v", err)
	}

	// 自动迁移：启动时自动建表/更新表结构
	if err := database.Migrate(db, model.All()...); err != nil {
		log.Fatalf("数据库迁移失败: %v", err)
	}

	// 首次启动预置默认快捷入口（仅表为空时执行，F-602）
	if err := service.NewBrowserService(
		repository.NewBrowserRepository(db),
	).SeedDefaultShortcuts(); err != nil {
		log.Fatalf("预置默认快捷入口失败: %v", err)
	}

	// 3. 注册路由
	r, cleanup := router.Setup(cfg, db)

	// 3.1 定时任务：每天 03:00 清理过期回收站条目
	// 保留天数优先读 AppConfig（设置页可改），缺省回退配置文件
	sourceSvc := service.NewSourceService(cfg, repository.NewSourceRepository(db))
	trashSvc := service.NewTrashService(sourceSvc, repository.NewTrashRepository(db))
	configRepo := repository.NewConfigRepository(db)
	cronRunner := cron.New()
	if _, err := cronRunner.AddFunc("0 3 * * *", func() {
		days := cfg.Trash.RetentionDays
		if v, err := configRepo.Get("trash.retention_days"); err == nil {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				days = n
			}
		}
		trashSvc.CleanupExpired(context.Background(), days)
	}); err != nil {
		log.Fatalf("注册回收站清理任务失败: %v", err)
	}
	cronRunner.Start()
	log.Printf("定时任务已启动：回收站清理（每天 03:00，保留 %d 天）", cfg.Trash.RetentionDays)

	// 4. 启动服务（含优雅关闭）
	addr := fmt.Sprintf(":%d", cfg.Server.Port)
	srv := &http.Server{
		Addr:    addr,
		Handler: r,
	}

	// 异步启动，避免阻塞信号监听
	go func() {
		log.Printf("myhub-server 启动，监听 %s（模式: %s）", addr, cfg.Server.Mode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("服务启动失败: %v", err)
		}
	}()

	// 监听中断信号，优雅关闭
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("收到退出信号，正在优雅关闭...")

	// 停止定时任务与流媒体会话
	cronRunner.Stop()
	cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("服务关闭异常: %v", err)
	}

	// 关闭数据库连接
	if sqlDB, err := db.DB(); err == nil {
		_ = sqlDB.Close()
	}

	log.Println("服务已退出")
}
