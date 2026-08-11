// Package router 负责 HTTP 路由注册。
package router

import (
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"myhub-server/internal/config"
	"myhub-server/internal/handler"
	"myhub-server/internal/middleware"
	"myhub-server/internal/repository"
	"myhub-server/internal/service"
)

// Setup 构建 Gin 引擎并注册全部路由。
// 返回的 cleanup 用于服务关闭时释放资源（如 HLS 转码进程）。
func Setup(cfg *config.Config, db *gorm.DB) (*gin.Engine, func()) {
	gin.SetMode(cfg.Server.Mode)

	r := gin.New()

	// 全局中间件：日志、异常恢复、CORS、统一错误处理
	r.Use(gin.Logger())
	r.Use(gin.Recovery())
	r.Use(middleware.CORS())
	r.Use(middleware.ErrorHandler())

	// 组装依赖：Repository → Service → Handler
	userRepo := repository.NewUserRepository(db)
	authSvc := service.NewAuthService(cfg, userRepo)
	authHandler := handler.NewAuthHandler(authSvc)

	sourceRepo := repository.NewSourceRepository(db)
	sourceSvc := service.NewSourceService(cfg, sourceRepo)
	sourceHandler := handler.NewSourceHandler(sourceSvc)

	trashRepo := repository.NewTrashRepository(db)
	progressRepo := repository.NewProgressRepository(db)
	fileSvc := service.NewFileService(cfg, sourceSvc, trashRepo, progressRepo)
	fileHandler := handler.NewFileHandler(fileSvc)

	trashSvc := service.NewTrashService(sourceSvc, trashRepo)
	trashHandler := handler.NewTrashHandler(trashSvc)

	favRepo := repository.NewFavoriteRepository(db)
	favSvc := service.NewFavoriteService(sourceSvc, favRepo)
	favHandler := handler.NewFavoriteHandler(favSvc)

	streamSvc := service.NewStreamService(cfg, sourceSvc)
	streamHandler := handler.NewStreamHandler(streamSvc)

	novelRepo := repository.NewNovelIndexRepository(db)
	readerSvc := service.NewReaderService(sourceSvc, novelRepo)
	readerHandler := handler.NewReaderHandler(readerSvc)

	configRepo := repository.NewConfigRepository(db)
	comicSvc := service.NewComicService(sourceSvc, configRepo, cfg.Data.ComicCacheDir, cfg.Data.ComicCacheMaxMB)
	comicHandler := handler.NewComicHandler(comicSvc)

	progressSvc := service.NewProgressService(progressRepo)
	progressHandler := handler.NewProgressHandler(progressSvc)

	configSvc := service.NewConfigService(configRepo)
	configHandler := handler.NewConfigHandler(configSvc)

	// 健康检查
	r.GET("/api/health", handler.Health)

	// 公开路由组：登录无需 JWT
	auth := r.Group("/api/auth")
	{
		auth.POST("/login", authHandler.Login)
	}

	// 需鉴权路由组：挂 JWT 中间件
	api := r.Group("/api", middleware.JWTAuth(authSvc))
	{
		api.PUT("/auth/password", authHandler.ChangePassword)
		api.GET("/auth/me", authHandler.Me)
		api.PUT("/auth/avatar", authHandler.UploadAvatar)
		api.GET("/auth/avatar", authHandler.GetAvatar)

		// 路径源管理
		sources := api.Group("/sources")
		{
			sources.GET("", sourceHandler.List)
			sources.GET("/:id", sourceHandler.Get)
			sources.POST("", sourceHandler.Create)
			sources.PUT("/:id", sourceHandler.Update)
			sources.DELETE("/:id", sourceHandler.Delete)
			sources.POST("/:id/test", sourceHandler.Test)
		}

		// 文件管理
		files := api.Group("/files")
		{
			files.GET("", fileHandler.List)
			files.GET("/info", fileHandler.Info)
			files.POST("/mkdir", fileHandler.Mkdir)
			files.POST("/upload", fileHandler.Upload)
			files.POST("/rename", fileHandler.Rename)
			files.POST("/move", fileHandler.Move)
			files.POST("/copy", fileHandler.Copy)
			files.DELETE("", fileHandler.Delete)
			files.GET("/thumbnail", fileHandler.Thumbnail)
			files.GET("/image", fileHandler.Image)
			files.GET("/text", fileHandler.TextPreview)
		}

		// 回收站
		trash := api.Group("/trash")
		{
			trash.GET("", trashHandler.List)
			trash.POST("/restore", trashHandler.Restore)
			trash.DELETE("/:id", trashHandler.Delete)
			trash.DELETE("", trashHandler.Clear)
		}

		// 收藏
		favorites := api.Group("/favorites")
		{
			favorites.GET("", favHandler.List)
			favorites.POST("", favHandler.Add)
			favorites.DELETE("", favHandler.Remove)
		}

		// 流媒体（单通配路由，handler 内分发原始流/HLS/字幕）
		api.GET("/stream/*rest", streamHandler.Dispatch)

		// 小说/EPUB 阅读器
		reader := api.Group("/reader")
		{
			reader.GET("/novel/chapters", readerHandler.NovelChapters)
			reader.GET("/novel/content", readerHandler.NovelContent)
			reader.GET("/epub/meta", readerHandler.EpubMeta)
			reader.GET("/epub/chapter", readerHandler.EpubChapter)
			reader.GET("/epub/resource", readerHandler.EpubResource)

			// 漫画阅读
			reader.GET("/comic/detect", comicHandler.Detect)
			reader.POST("/comic/override", comicHandler.Override)
			reader.GET("/comic/pages", comicHandler.Pages)
			reader.GET("/comic/page", comicHandler.Page)

			// 普通压缩包
			reader.GET("/archive/tree", comicHandler.ArchiveTree)
			reader.GET("/archive/file", comicHandler.ArchiveFile)
		}

		// 阅读进度
		api.GET("/progress", progressHandler.List)
		api.PUT("/progress", progressHandler.Save)
		api.DELETE("/progress", progressHandler.Delete)

		// 系统配置
		api.GET("/config", configHandler.GetAll)
		api.PUT("/config", configHandler.BatchUpdate)
	}

	// 内部路由组：供 OpenClaw 等内部服务回传，Token 校验中间件
	internal := r.Group("/api/internal", middleware.InternalToken(cfg))
	{
		// 占位端点：验证内部令牌中间件可用，后续由 1.12 动态模块替换为真实业务
		internal.GET("/ping", func(c *gin.Context) {
			handler.Success(c, gin.H{"status": "ok"})
		})
		// TODO(1.12 动态模块)：internal.POST("/feed/ingest", ...)
	}

	// 未匹配路由：/api 统一 JSON 404；配置了 web.dir 时托管 Flutter Web 产物（SPA 回退 index.html）
	webDir := resolveWebDir(cfg.Web.Dir)
	r.NoRoute(func(c *gin.Context) {
		if strings.HasPrefix(c.Request.URL.Path, "/api/") {
			handler.Fail(c, http.StatusNotFound, http.StatusNotFound, "接口不存在")
			return
		}
		if webDir == "" {
			handler.Fail(c, http.StatusNotFound, http.StatusNotFound, "接口不存在")
			return
		}
		serveSPA(c, webDir)
	})

	return r, streamSvc.Stop
}

// resolveWebDir 校验并返回可用的静态托管目录；未配置或目录无效返回空
func resolveWebDir(dir string) string {
	if dir == "" {
		return ""
	}
	fi, err := os.Stat(dir)
	if err != nil || !fi.IsDir() {
		return ""
	}
	// 无 index.html 视为无效目录
	if _, err := os.Stat(filepath.Join(dir, "index.html")); err != nil {
		return ""
	}
	return dir
}

// serveSPA 托管单页应用：静态文件优先，未命中回退 index.html（前端路由）
func serveSPA(c *gin.Context, webDir string) {
	// 清洗路径，防目录穿越
	cleaned := path.Clean("/" + c.Request.URL.Path)
	full := filepath.Join(webDir, filepath.FromSlash(cleaned))
	if !strings.HasPrefix(full, filepath.Clean(webDir)+string(os.PathSeparator)) && full != filepath.Clean(webDir) {
		handler.Fail(c, http.StatusForbidden, http.StatusForbidden, "路径越权")
		return
	}
	if fi, err := os.Stat(full); err == nil && !fi.IsDir() {
		c.File(full)
		return
	}
	// SPA 回退
	c.Header("Cache-Control", "no-cache")
	c.File(filepath.Join(webDir, "index.html"))
}
