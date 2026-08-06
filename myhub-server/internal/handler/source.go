package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/model"
	"myhub-server/internal/service"
)

// SourceHandler 路径源管理处理器
type SourceHandler struct {
	sourceSvc *service.SourceService
}

// NewSourceHandler 创建 SourceHandler
func NewSourceHandler(sourceSvc *service.SourceService) *SourceHandler {
	return &SourceHandler{sourceSvc: sourceSvc}
}

// parseID 解析路径参数 :id
func parseID(c *gin.Context) (uint, bool) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "无效的 ID")
		return 0, false
	}
	return uint(id), true
}

// mapSourceError 将 Service 层错误映射为 HTTP 响应；已写出响应时返回 true
func mapSourceError(c *gin.Context, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, service.ErrSourceNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrInvalidSource), errors.Is(err, service.ErrSourceForbidden):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, adapter.ErrNotExist):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "挂载点不存在")
	case errors.Is(err, adapter.ErrNotDirectory):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "挂载点不是目录")
	case errors.Is(err, adapter.ErrForbidden):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "挂载点越权：不在允许范围内")
	default:
		_ = c.Error(err)
	}
	return true
}

// SourceRequest 创建/更新路径源请求体
type SourceRequest struct {
	Name       string          `json:"name" binding:"required"`
	Type       model.SourceType `json:"type" binding:"required"`
	ConfigJSON string          `json:"config_json"`
	MountPoint string          `json:"mount_point"`
	Enabled    *bool           `json:"enabled"` // 指针区分"未传"与"传 false"
}

// List GET /api/sources
func (h *SourceHandler) List(c *gin.Context) {
	sources, err := h.sourceSvc.List()
	if err != nil {
		_ = c.Error(err)
		return
	}
	Success(c, sources)
}

// Get GET /api/sources/:id
func (h *SourceHandler) Get(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}
	source, err := h.sourceSvc.GetByID(id)
	if mapSourceError(c, err) {
		return
	}
	Success(c, source)
}

// Create POST /api/sources
func (h *SourceHandler) Create(c *gin.Context) {
	var req SourceRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：name 与 type 均为必填")
		return
	}

	source := &model.Source{
		Name:       req.Name,
		Type:       req.Type,
		ConfigJSON: req.ConfigJSON,
		MountPoint: req.MountPoint,
		Enabled:    true, // 默认启用
	}
	if req.Enabled != nil {
		source.Enabled = *req.Enabled
	}

	if err := h.sourceSvc.Create(source); mapSourceError(c, err) {
		return
	}
	Success(c, source)
}

// Update PUT /api/sources/:id
func (h *SourceHandler) Update(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}

	source, err := h.sourceSvc.GetByID(id)
	if mapSourceError(c, err) {
		return
	}

	var req SourceRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：name 与 type 均为必填")
		return
	}

	source.Name = req.Name
	source.Type = req.Type
	source.ConfigJSON = req.ConfigJSON
	source.MountPoint = req.MountPoint
	if req.Enabled != nil {
		source.Enabled = *req.Enabled
	}

	if err := h.sourceSvc.Update(source); mapSourceError(c, err) {
		return
	}
	Success(c, source)
}

// Delete DELETE /api/sources/:id
func (h *SourceHandler) Delete(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}
	if err := h.sourceSvc.Delete(id); mapSourceError(c, err) {
		return
	}
	Success(c, nil)
}

// Test POST /api/sources/:id/test 连接测试
func (h *SourceHandler) Test(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}
	network, err := h.sourceSvc.Test(c.Request.Context(), id)
	if mapSourceError(c, err) {
		return
	}
	Success(c, gin.H{"message": "连接正常", "network": network})
}
