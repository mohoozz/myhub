package handler

import (
	"errors"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/parser"
	"myhub-server/internal/service"
)

// ComicHandler 漫画阅读处理器
type ComicHandler struct {
	comicSvc *service.ComicService
}

// NewComicHandler 创建 ComicHandler
func NewComicHandler(comicSvc *service.ComicService) *ComicHandler {
	return &ComicHandler{comicSvc: comicSvc}
}

// mapComicError 漫画错误映射；已写出响应时返回 true
func mapComicError(c *gin.Context, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, adapter.ErrNotExist):
		Fail(c, http.StatusNotFound, http.StatusNotFound, "文件不存在")
	case errors.Is(err, adapter.ErrForbidden), errors.Is(err, service.ErrSourceForbidden):
		Fail(c, http.StatusForbidden, http.StatusForbidden, "路径越权")
	case errors.Is(err, service.ErrSourceNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrInvalidSource):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, adapter.ErrIsDirectory):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "不能读取目录")
	case errors.Is(err, parser.ErrNotArchive), errors.Is(err, parser.ErrNotEPUB):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "不是支持的压缩包/EPUB 格式")
	case errors.Is(err, parser.ErrEntryNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, "压缩包内条目不存在")
	case errors.Is(err, service.ErrNotComic):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrPageOutOfRange):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	default:
		_ = c.Error(err)
	}
	return true
}

// imageContentType 按扩展名返回图片 Content-Type
func imageContentType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".bmp":
		return "image/bmp"
	case ".avif":
		return "image/avif"
	}
	return "application/octet-stream"
}

// Detect GET /api/reader/comic/detect?source=&path=
func (h *ComicHandler) Detect(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	result, err := h.comicSvc.Detect(c.Request.Context(), sourceID, p)
	if mapComicError(c, err) {
		return
	}
	Success(c, result)
}

// OverrideRequest 手动覆盖请求体
type OverrideRequest struct {
	Source  uint   `json:"source" binding:"required"`
	Path    string `json:"path" binding:"required"`
	IsComic bool   `json:"is_comic"`
}

// Override POST /api/reader/comic/override
func (h *ComicHandler) Override(c *gin.Context) {
	var req OverrideRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source 与 path 均为必填")
		return
	}
	if err := h.comicSvc.SetOverride(req.Source, req.Path, req.IsComic); mapComicError(c, err) {
		return
	}
	Success(c, nil)
}

// Pages GET /api/reader/comic/pages?source=&path=
func (h *ComicHandler) Pages(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	pages, err := h.comicSvc.Pages(c.Request.Context(), sourceID, p)
	if mapComicError(c, err) {
		return
	}
	Success(c, gin.H{"pages": pages, "total": len(pages)})
}

// Page GET /api/reader/comic/page?source=&path=&n=N
func (h *ComicHandler) Page(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	n, err := strconv.Atoi(c.DefaultQuery("n", "0"))
	if err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "无效的页码")
		return
	}
	data, name, err := h.comicSvc.Page(c.Request.Context(), sourceID, p, n)
	if mapComicError(c, err) {
		return
	}
	c.Data(http.StatusOK, imageContentType(name), data)
}

// ArchiveTree GET /api/reader/archive/tree?source=&path=
func (h *ComicHandler) ArchiveTree(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	entries, err := h.comicSvc.ArchiveTree(c.Request.Context(), sourceID, p)
	if mapComicError(c, err) {
		return
	}
	Success(c, gin.H{"entries": entries, "total": len(entries)})
}

// ArchiveFile GET /api/reader/archive/file?source=&path=&entry=
func (h *ComicHandler) ArchiveFile(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	entry := c.Query("entry")
	if entry == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 entry 参数")
		return
	}
	data, name, err := h.comicSvc.ArchiveFile(c.Request.Context(), sourceID, p, entry)
	if mapComicError(c, err) {
		return
	}
	c.Data(http.StatusOK, service.StreamContentType(name), data)
}
