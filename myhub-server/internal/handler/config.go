package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/service"
)

// ConfigHandler 系统配置处理器
type ConfigHandler struct {
	configSvc *service.ConfigService
}

// NewConfigHandler 创建 ConfigHandler
func NewConfigHandler(configSvc *service.ConfigService) *ConfigHandler {
	return &ConfigHandler{configSvc: configSvc}
}

// GetAll GET /api/config
func (h *ConfigHandler) GetAll(c *gin.Context) {
	configs, err := h.configSvc.All()
	if err != nil {
		_ = c.Error(err)
		return
	}
	Success(c, configs)
}

// BatchUpdate PUT /api/config（请求体为键值对 map）
func (h *ConfigHandler) BatchUpdate(c *gin.Context) {
	var kv map[string]string
	if err := c.ShouldBindJSON(&kv); err != nil || len(kv) == 0 {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：请求体应为非空键值对 JSON")
		return
	}
	if err := h.configSvc.BatchUpdate(kv); err != nil {
		if errors.Is(err, service.ErrInternalConfigKey) {
			Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
			return
		}
		_ = c.Error(err)
		return
	}
	Success(c, nil)
}
