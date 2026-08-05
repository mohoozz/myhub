package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/service"
)

// TrashHandler 回收站处理器
type TrashHandler struct {
	trashSvc *service.TrashService
}

// NewTrashHandler 创建 TrashHandler
func NewTrashHandler(trashSvc *service.TrashService) *TrashHandler {
	return &TrashHandler{trashSvc: trashSvc}
}

// mapTrashError 回收站错误映射；已写出响应时返回 true
func mapTrashError(c *gin.Context, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, service.ErrTrashItemNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrSourceNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, adapter.ErrNotExist):
		Fail(c, http.StatusNotFound, http.StatusNotFound, "回收站文件不存在")
	case errors.Is(err, adapter.ErrForbidden), errors.Is(err, service.ErrSourceForbidden):
		Fail(c, http.StatusForbidden, http.StatusForbidden, "路径越权")
	case errors.Is(err, adapter.ErrTargetExists):
		Fail(c, http.StatusConflict, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrInvalidSource):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	default:
		_ = c.Error(err)
	}
	return true
}

// parseOptionalSourceID 解析可选的 source 查询参数（缺省返回 0 = 不过滤）
func parseOptionalSourceID(c *gin.Context) (uint, bool) {
	raw := c.Query("source")
	if raw == "" {
		return 0, true
	}
	id, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "无效的 source 参数")
		return 0, false
	}
	return uint(id), true
}

// List GET /api/trash?source=
func (h *TrashHandler) List(c *gin.Context) {
	sourceID, ok := parseOptionalSourceID(c)
	if !ok {
		return
	}
	items, err := h.trashSvc.List(sourceID)
	if mapTrashError(c, err) {
		return
	}
	Success(c, items)
}

// RestoreRequest 还原请求体
type RestoreRequest struct {
	ID uint `json:"id" binding:"required"`
}

// Restore POST /api/trash/restore
func (h *TrashHandler) Restore(c *gin.Context) {
	var req RestoreRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：id 必填")
		return
	}
	if err := h.trashSvc.Restore(c.Request.Context(), req.ID); mapTrashError(c, err) {
		return
	}
	Success(c, nil)
}

// Delete DELETE /api/trash/:id（彻底删除单个文件）
func (h *TrashHandler) Delete(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}
	if err := h.trashSvc.Purge(c.Request.Context(), id); mapTrashError(c, err) {
		return
	}
	Success(c, nil)
}

// Clear DELETE /api/trash?source=（清空回收站）
func (h *TrashHandler) Clear(c *gin.Context) {
	sourceID, ok := parseOptionalSourceID(c)
	if !ok {
		return
	}
	if err := h.trashSvc.Clear(c.Request.Context(), sourceID); mapTrashError(c, err) {
		return
	}
	Success(c, nil)
}
