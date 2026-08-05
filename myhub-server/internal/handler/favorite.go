package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/service"
)

// FavoriteHandler 收藏处理器
type FavoriteHandler struct {
	favSvc *service.FavoriteService
}

// NewFavoriteHandler 创建 FavoriteHandler
func NewFavoriteHandler(favSvc *service.FavoriteService) *FavoriteHandler {
	return &FavoriteHandler{favSvc: favSvc}
}

// mapFavoriteError 收藏错误映射；已写出响应时返回 true
func mapFavoriteError(c *gin.Context, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, service.ErrFavoriteExists):
		Fail(c, http.StatusConflict, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrFavoriteNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, adapter.ErrNotExist):
		Fail(c, http.StatusNotFound, http.StatusNotFound, "文件不存在")
	case errors.Is(err, adapter.ErrForbidden), errors.Is(err, service.ErrSourceForbidden):
		Fail(c, http.StatusForbidden, http.StatusForbidden, "路径越权")
	case errors.Is(err, service.ErrSourceNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrInvalidSource):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	default:
		_ = c.Error(err)
	}
	return true
}

// FavoriteRequest 添加/取消收藏请求体
type FavoriteRequest struct {
	SourceID uint   `json:"source_id" binding:"required"`
	FilePath string `json:"file_path" binding:"required"`
}

// List GET /api/favorites?page=&page_size=
func (h *FavoriteHandler) List(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "50"))

	items, total, err := h.favSvc.List(page, pageSize)
	if mapFavoriteError(c, err) {
		return
	}
	Success(c, gin.H{
		"list":      items,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// Add POST /api/favorites
func (h *FavoriteHandler) Add(c *gin.Context) {
	var req FavoriteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source_id 与 file_path 均为必填")
		return
	}
	fav, err := h.favSvc.Add(c.Request.Context(), req.SourceID, req.FilePath)
	if mapFavoriteError(c, err) {
		return
	}
	Success(c, fav)
}

// Remove DELETE /api/favorites
func (h *FavoriteHandler) Remove(c *gin.Context) {
	var req FavoriteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source_id 与 file_path 均为必填")
		return
	}
	if err := h.favSvc.Remove(req.SourceID, req.FilePath); mapFavoriteError(c, err) {
		return
	}
	Success(c, nil)
}
