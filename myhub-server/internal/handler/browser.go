package handler

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/service"
)

// BrowserHandler 浏览器书签/历史/快捷入口处理器
type BrowserHandler struct {
	svc *service.BrowserService
}

// NewBrowserHandler 创建 BrowserHandler
func NewBrowserHandler(svc *service.BrowserService) *BrowserHandler {
	return &BrowserHandler{svc: svc}
}

// mapBrowserError 浏览器模块错误映射；已写出响应时返回 true
func mapBrowserError(c *gin.Context, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, service.ErrInvalidURL), errors.Is(err, service.ErrInvalidCursor):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrBookmarkNotFound),
		errors.Is(err, service.ErrHistoryNotFound),
		errors.Is(err, service.ErrShortcutNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrShortcutExists):
		Fail(c, http.StatusConflict, http.StatusConflict, err.Error())
	default:
		_ = c.Error(err)
	}
	return true
}

// ---------- 书签 ----------

// BookmarkRequest 添加书签请求体
type BookmarkRequest struct {
	Title   string `json:"title"`
	URL     string `json:"url" binding:"required"`
	Favicon string `json:"favicon"`
}

// ListBookmarks GET /api/browser/bookmarks
func (h *BrowserHandler) ListBookmarks(c *gin.Context) {
	items, err := h.svc.ListBookmarks()
	if mapBrowserError(c, err) {
		return
	}
	Success(c, gin.H{"list": items, "total": len(items)})
}

// AddBookmark POST /api/browser/bookmarks（URL 唯一，重复添加幂等）
func (h *BrowserHandler) AddBookmark(c *gin.Context) {
	var req BookmarkRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：url 为必填")
		return
	}
	b, created, err := h.svc.AddBookmark(req.Title, req.URL, req.Favicon)
	if mapBrowserError(c, err) {
		return
	}
	Success(c, gin.H{"bookmark": b, "created": created})
}

// RemoveBookmark DELETE /api/browser/bookmarks?id= 或 ?url=
func (h *BrowserHandler) RemoveBookmark(c *gin.Context) {
	id, _ := strconv.ParseUint(c.Query("id"), 10, 64)
	rawURL := c.Query("url")
	if id == 0 && rawURL == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：id 或 url 至少提供一个")
		return
	}
	if err := h.svc.RemoveBookmark(uint(id), rawURL); mapBrowserError(c, err) {
		return
	}
	Success(c, nil)
}

// ---------- 历史 ----------

// HistoryReportItem 单条历史上报
type HistoryReportItem struct {
	Title     string     `json:"title"`
	URL       string     `json:"url"`
	Favicon   string     `json:"favicon"`
	VisitedAt *time.Time `json:"visited_at"`
}

// HistoryReportRequest 历史批量上报请求体（前端节流后批量提交）
type HistoryReportRequest struct {
	Items []HistoryReportItem `json:"items" binding:"required,min=1,max=200"`
}

// ListHistory GET /api/browser/history?cursor=&limit=（visited_at 降序游标分页，按日分组由前端处理）
func (h *BrowserHandler) ListHistory(c *gin.Context) {
	cursor := c.Query("cursor")
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	items, nextCursor, err := h.svc.ListHistory(cursor, limit)
	if mapBrowserError(c, err) {
		return
	}
	Success(c, gin.H{"list": items, "next_cursor": nextCursor})
}

// ReportHistory POST /api/browser/history
func (h *BrowserHandler) ReportHistory(c *gin.Context) {
	var req HistoryReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：items 为必填（1~200 条）")
		return
	}
	inputs := make([]service.HistoryItemInput, 0, len(req.Items))
	for _, it := range req.Items {
		in := service.HistoryItemInput{
			Title:   it.Title,
			URL:     it.URL,
			Favicon: it.Favicon,
		}
		if it.VisitedAt != nil {
			in.VisitedAt = *it.VisitedAt
		}
		inputs = append(inputs, in)
	}
	inserted, err := h.svc.ReportHistory(inputs)
	if mapBrowserError(c, err) {
		return
	}
	Success(c, gin.H{"inserted": inserted})
}

// DeleteHistory DELETE /api/browser/history（?id= 单条删除，无参数清空全部）
func (h *BrowserHandler) DeleteHistory(c *gin.Context) {
	idStr := c.Query("id")
	if idStr == "" {
		if err := h.svc.ClearHistory(); mapBrowserError(c, err) {
			return
		}
		Success(c, gin.H{"cleared": true})
		return
	}
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil || id == 0 {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：id 必须为正整数")
		return
	}
	if err := h.svc.DeleteHistory(uint(id)); mapBrowserError(c, err) {
		return
	}
	Success(c, nil)
}

// ---------- 快捷入口 ----------

// ShortcutAddRequest 添加快捷入口请求体
type ShortcutAddRequest struct {
	Title string `json:"title"`
	URL   string `json:"url" binding:"required"`
}

// ShortcutUpdateRequest 更新快捷入口请求体（指针字段区分"未提供"）
type ShortcutUpdateRequest struct {
	ID        uint    `json:"id" binding:"required"`
	Title     *string `json:"title"`
	URL       *string `json:"url"`
	SortOrder *int    `json:"sort_order"`
}

// ShortcutReorderRequest 批量重排请求体
type ShortcutReorderRequest struct {
	IDs []uint `json:"ids" binding:"required,min=1"`
}

// ListShortcuts GET /api/browser/shortcuts（按 sort_order 升序）
func (h *BrowserHandler) ListShortcuts(c *gin.Context) {
	items, err := h.svc.ListShortcuts()
	if mapBrowserError(c, err) {
		return
	}
	Success(c, gin.H{"list": items, "total": len(items)})
}

// AddShortcut POST /api/browser/shortcuts
func (h *BrowserHandler) AddShortcut(c *gin.Context) {
	var req ShortcutAddRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：url 为必填")
		return
	}
	sc, err := h.svc.AddShortcut(req.Title, req.URL)
	if mapBrowserError(c, err) {
		return
	}
	Success(c, sc)
}

// UpdateShortcut PUT /api/browser/shortcuts
func (h *BrowserHandler) UpdateShortcut(c *gin.Context) {
	var req ShortcutUpdateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：id 为必填")
		return
	}
	sc, err := h.svc.UpdateShortcut(service.ShortcutUpdate{
		ID:        req.ID,
		Title:     req.Title,
		URL:       req.URL,
		SortOrder: req.SortOrder,
	})
	if mapBrowserError(c, err) {
		return
	}
	Success(c, sc)
}

// ReorderShortcuts PUT /api/browser/shortcuts/order
func (h *BrowserHandler) ReorderShortcuts(c *gin.Context) {
	var req ShortcutReorderRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：ids 为必填")
		return
	}
	if err := h.svc.ReorderShortcuts(req.IDs); mapBrowserError(c, err) {
		return
	}
	Success(c, nil)
}

// RemoveShortcut DELETE /api/browser/shortcuts?id=
func (h *BrowserHandler) RemoveShortcut(c *gin.Context) {
	id, err := strconv.ParseUint(c.Query("id"), 10, 64)
	if err != nil || id == 0 {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：id 必须为正整数")
		return
	}
	if err := h.svc.RemoveShortcut(uint(id)); mapBrowserError(c, err) {
		return
	}
	Success(c, nil)
}
