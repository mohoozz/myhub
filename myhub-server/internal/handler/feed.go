package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/service"
)

// FeedHandler 动态模块处理器
type FeedHandler struct {
	feedSvc *service.FeedService
}

// NewFeedHandler 创建 FeedHandler
func NewFeedHandler(feedSvc *service.FeedService) *FeedHandler {
	return &FeedHandler{feedSvc: feedSvc}
}

// mapFeedError 动态模块错误映射；已写出响应时返回 true。
func mapFeedError(c *gin.Context, err error) bool {
	if err == nil {
		return false
	}
	switch {
	case errors.Is(err, service.ErrFeedUnavailable):
		Fail(c, http.StatusBadGateway, http.StatusBadGateway, err.Error())
	case errors.Is(err, service.ErrFeedItemNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrWatchLaterNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrWatchLaterExists):
		Fail(c, http.StatusConflict, http.StatusConflict, err.Error())
	default:
		Fail(c, http.StatusBadGateway, http.StatusBadGateway, err.Error())
	}
	return true
}

// List GET /api/feed?before=&limit=
// before 为上一页最早条目的本地 id（游标），首页不传。
func (h *FeedHandler) List(c *gin.Context) {
	beforeID, _ := strconv.Atoi(c.DefaultQuery("before", "0"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))

	items, err := h.feedSvc.List(c.Request.Context(), uint(beforeID), limit)
	if mapFeedError(c, err) {
		return
	}

	cursor, _ := h.feedSvc.GetCursor(c.Request.Context())
	Success(c, gin.H{
		"items":      items,
		"cursor_id":  cursor.FeedItemID,
		"has_more":   len(items) == limit,
	})
}

// MarkRead POST /api/feed/read
func (h *FeedHandler) MarkRead(c *gin.Context) {
	var req struct {
		FeedItemID uint `json:"feed_item_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：feed_item_id 为必填")
		return
	}
	if err := h.feedSvc.MarkRead(c.Request.Context(), req.FeedItemID); mapFeedError(c, err) {
		return
	}
	Success(c, nil)
}

// ReadAll POST /api/feed/read-all
func (h *FeedHandler) ReadAll(c *gin.Context) {
	if err := h.feedSvc.ReadAll(c.Request.Context()); mapFeedError(c, err) {
		return
	}
	Success(c, nil)
}

// Cursor GET /api/feed/cursor
func (h *FeedHandler) Cursor(c *gin.Context) {
	cursor, err := h.feedSvc.GetCursor(c.Request.Context())
	if mapFeedError(c, err) {
		return
	}
	Success(c, cursor)
}

// ---------- 订阅源 ----------

// ListSubscriptions GET /api/feed/subscriptions
func (h *FeedHandler) ListSubscriptions(c *gin.Context) {
	data, err := h.feedSvc.ListSubscriptions(c.Request.Context())
	if mapFeedError(c, err) {
		return
	}
	Success(c, data)
}

// AddSubscription POST /api/feed/subscriptions
func (h *FeedHandler) AddSubscription(c *gin.Context) {
	var req struct {
		Platform string `json:"platform" binding:"required"`
		Target   string `json:"target" binding:"required"`
		Name     string `json:"name"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：platform 与 target 为必填")
		return
	}
	data, err := h.feedSvc.AddSubscription(c.Request.Context(), req.Platform, req.Target, req.Name)
	if mapFeedError(c, err) {
		return
	}
	Success(c, data)
}

// DeleteSubscription DELETE /api/feed/subscriptions/:id?purge=
func (h *FeedHandler) DeleteSubscription(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：id 非法")
		return
	}
	purge := c.DefaultQuery("purge", "false") == "true"
	data, err := h.feedSvc.DeleteSubscription(c.Request.Context(), id, purge)
	if mapFeedError(c, err) {
		return
	}
	Success(c, data)
}

// ---------- 抓取 ----------

// Fetch POST /api/feed/fetch
func (h *FeedHandler) Fetch(c *gin.Context) {
	platform := c.DefaultQuery("platform", "")
	subscriptionID, _ := strconv.Atoi(c.DefaultQuery("subscription_id", "0"))
	data, err := h.feedSvc.Fetch(c.Request.Context(), platform, subscriptionID)
	if mapFeedError(c, err) {
		return
	}
	Success(c, data)
}

// ListLogs GET /api/feed/logs
func (h *FeedHandler) ListLogs(c *gin.Context) {
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	data, err := h.feedSvc.ListLogs(c.Request.Context(), limit)
	if mapFeedError(c, err) {
		return
	}
	Success(c, data)
}

// ---------- 稍后观看 ----------

// ListWatchLater GET /api/feed/watch-later
func (h *FeedHandler) ListWatchLater(c *gin.Context) {
	list, err := h.feedSvc.ListWatchLater(c.Request.Context())
	if mapFeedError(c, err) {
		return
	}
	Success(c, list)
}

// AddWatchLater POST /api/feed/watch-later
func (h *FeedHandler) AddWatchLater(c *gin.Context) {
	var req struct {
		Platform  string `json:"platform" binding:"required"`
		ContentID string `json:"content_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：platform 与 content_id 为必填")
		return
	}
	w, err := h.feedSvc.AddWatchLater(c.Request.Context(), req.Platform, req.ContentID)
	if mapFeedError(c, err) {
		return
	}
	Success(c, w)
}

// RemoveWatchLater DELETE /api/feed/watch-later
func (h *FeedHandler) RemoveWatchLater(c *gin.Context) {
	var req struct {
		Platform  string `json:"platform" binding:"required"`
		ContentID string `json:"content_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：platform 与 content_id 为必填")
		return
	}
	if err := h.feedSvc.RemoveWatchLater(c.Request.Context(), req.Platform, req.ContentID); mapFeedError(c, err) {
		return
	}
	Success(c, nil)
}
