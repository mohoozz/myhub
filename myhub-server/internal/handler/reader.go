package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/parser"
	"myhub-server/internal/service"
)

// ReaderHandler 小说/EPUB 阅读处理器
type ReaderHandler struct {
	readerSvc *service.ReaderService
}

// NewReaderHandler 创建 ReaderHandler
func NewReaderHandler(readerSvc *service.ReaderService) *ReaderHandler {
	return &ReaderHandler{readerSvc: readerSvc}
}

// mapReaderError 阅读器错误映射；已写出响应时返回 true
func mapReaderError(c *gin.Context, err error) bool {
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
	case errors.Is(err, service.ErrChapterOutOfRange):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, adapter.ErrIsDirectory):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "不能读取目录")
	case errors.Is(err, parser.ErrNotEPUB):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "不是有效的 EPUB 文件")
	case errors.Is(err, parser.ErrItemNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, "EPUB 条目不存在")
	default:
		_ = c.Error(err)
	}
	return true
}

// parseSourcePath 解析 source 与 path 查询参数
func parseSourcePath(c *gin.Context) (uint, string, bool) {
	sourceID, ok := parseSourceID(c, c.Query("source"))
	if !ok {
		return 0, "", false
	}
	p := c.Query("path")
	if p == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 path 参数")
		return 0, "", false
	}
	return sourceID, p, true
}

// NovelChapters GET /api/reader/novel/chapters?source=&path=
func (h *ReaderHandler) NovelChapters(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	result, err := h.readerSvc.GetNovelChapters(c.Request.Context(), sourceID, p)
	if mapReaderError(c, err) {
		return
	}
	Success(c, result)
}

// NovelContent GET /api/reader/novel/content?source=&path=&chapter=N
func (h *ReaderHandler) NovelContent(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	chapter, err := strconv.Atoi(c.DefaultQuery("chapter", "0"))
	if err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "无效的 chapter 参数")
		return
	}
	result, err := h.readerSvc.GetNovelContent(c.Request.Context(), sourceID, p, chapter)
	if mapReaderError(c, err) {
		return
	}
	Success(c, result)
}

// EpubMeta GET /api/reader/epub/meta?source=&path=
func (h *ReaderHandler) EpubMeta(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	result, err := h.readerSvc.GetEpubMeta(c.Request.Context(), sourceID, p)
	if mapReaderError(c, err) {
		return
	}
	Success(c, result)
}

// EpubChapter GET /api/reader/epub/chapter?source=&path=&id=
func (h *ReaderHandler) EpubChapter(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	id := c.Query("id")
	if id == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 id 参数")
		return
	}
	data, err := h.readerSvc.GetEpubChapter(c.Request.Context(), sourceID, p, id)
	if mapReaderError(c, err) {
		return
	}
	c.Data(http.StatusOK, "text/html; charset=utf-8", data)
}

// EpubResource GET /api/reader/epub/resource?source=&path=&id=
func (h *ReaderHandler) EpubResource(c *gin.Context) {
	sourceID, p, ok := parseSourcePath(c)
	if !ok {
		return
	}
	id := c.Query("id")
	if id == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 id 参数")
		return
	}
	data, mediaType, err := h.readerSvc.GetEpubResource(c.Request.Context(), sourceID, p, id)
	if mapReaderError(c, err) {
		return
	}
	c.Data(http.StatusOK, mediaType, data)
}
