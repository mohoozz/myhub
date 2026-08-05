package handler

import (
	"github.com/gin-gonic/gin"
)

// 服务元信息，用于健康检查返回
const (
	ServiceName = "myhub-server"
	Version     = "0.1.0"
)

// Health 健康检查处理器
// GET /api/health
func Health(c *gin.Context) {
	Success(c, gin.H{
		"service": ServiceName,
		"version": Version,
		"status":  "ok",
	})
}
