package handler

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/service"
)

// StreamHandler 流媒体处理器。
// 由于 /api/stream/:sourceId/*path 与 /api/stream/hls/... 在 gin 中路由冲突，
// 统一使用 /api/stream/*rest 单通配路由，在此手动分发：
//
//	/api/stream/{sourceId}/{path...}            原始流（Range）
//	/api/stream/hls/{id}/playlist.m3u8          HLS 播放列表
//	/api/stream/hls/{id}/segment/{name}.ts      HLS 分片
//	/api/stream/subtitle?source=&path=          字幕转换（srt/ass → vtt）
type StreamHandler struct {
	streamSvc *service.StreamService
}

// NewStreamHandler 创建 StreamHandler
func NewStreamHandler(streamSvc *service.StreamService) *StreamHandler {
	return &StreamHandler{streamSvc: streamSvc}
}

// mapStreamError 流媒体错误映射；已写出响应时返回 true
func mapStreamError(c *gin.Context, err error) bool {
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
	case errors.Is(err, service.ErrUnsupportedSubtitle):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrHLSFailed):
		Fail(c, http.StatusInternalServerError, http.StatusInternalServerError, err.Error())
	case errors.Is(err, service.ErrInvalidHLSSession):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrNoFFmpeg):
		Fail(c, http.StatusNotImplemented, http.StatusNotImplemented, err.Error())
	default:
		_ = c.Error(err)
	}
	return true
}

// Dispatch GET /api/stream/*rest 统一入口
func (h *StreamHandler) Dispatch(c *gin.Context) {
	rest := strings.TrimPrefix(c.Param("rest"), "/")
	if rest == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少路径")
		return
	}

	seg, remainder, _ := strings.Cut(rest, "/")
	switch seg {
	case "hls":
		h.handleHLS(c, remainder)
	case "subtitle":
		h.handleSubtitle(c)
	case "probe":
		h.handleProbe(c)
	default:
		sourceID, err := strconv.ParseUint(seg, 10, 64)
		if err != nil || sourceID == 0 {
			Fail(c, http.StatusBadRequest, http.StatusBadRequest, "无效的 sourceId")
			return
		}
		h.handleRaw(c, uint(sourceID), "/"+remainder)
	}
}

// handleProbe GET /api/stream/probe?source=&path=（探测视频编码）
// 返回 {"codec": "hevc"}，供客户端在播放前决定硬解/软解，避免黑屏兜底。
func (h *StreamHandler) handleProbe(c *gin.Context) {
	sourceID, ok := parseSourceID(c, c.Query("source"))
	if !ok {
		return
	}
	p := c.Query("path")
	if p == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 path 参数")
		return
	}
	codec := h.streamSvc.ProbeCodec(c.Request.Context(), sourceID, p)
	log.Printf("[probe] sourceID=%d path=%s codec=%q", sourceID, p, codec)
	Success(c, gin.H{"codec": codec})
}

// handleRaw 原始流：解析 Range 头，返回 200 全量或 206 部分内容
func (h *StreamHandler) handleRaw(c *gin.Context, sourceID uint, p string) {
	ctx := c.Request.Context()

	fi, err := h.streamSvc.Stat(ctx, sourceID, p)
	if mapStreamError(c, err) {
		log.Printf("[stream] Stat failed sourceID=%d path=%s err=%v", sourceID, p, err)
		return
	}
	if fi.IsDir {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "不能流式传输目录")
		return
	}

	start, end, err := service.ParseRange(c.GetHeader("Range"), fi.Size)
	if err != nil {
		log.Printf("[stream] invalid Range sourceID=%d path=%s range=%q size=%d err=%v", sourceID, p, c.GetHeader("Range"), fi.Size, err)
		c.Header("Content-Range", fmt.Sprintf("bytes */%d", fi.Size))
		Fail(c, http.StatusRequestedRangeNotSatisfiable, http.StatusRequestedRangeNotSatisfiable, "无效的 Range")
		return
	}
	length := end - start + 1
	status := http.StatusOK
	if c.GetHeader("Range") != "" {
		status = http.StatusPartialContent
	}
	log.Printf("[stream] raw sourceID=%d path=%s size=%d range=%q start=%d end=%d length=%d contentType=%s status=%d", sourceID, p, fi.Size, c.GetHeader("Range"), start, end, length, service.StreamContentType(fi.Name), status)

	rc, err := h.streamSvc.Open(ctx, sourceID, p, start, length)
	if mapStreamError(c, err) {
		log.Printf("[stream] Open failed sourceID=%d path=%s err=%v", sourceID, p, err)
		return
	}
	defer rc.Close()

	c.Header("Content-Type", service.StreamContentType(fi.Name))
	c.Header("Accept-Ranges", "bytes")
	c.Header("Content-Length", strconv.FormatInt(length, 10))
	if c.GetHeader("Range") != "" {
		c.Header("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, fi.Size))
		c.Status(http.StatusPartialContent)
	} else {
		c.Status(http.StatusOK)
	}
	n, copyErr := io.CopyN(c.Writer, rc, length)
	log.Printf("[stream] raw sent sourceID=%d path=%s bytes=%d err=%v", sourceID, p, n, copyErr)
}

// handleHLS 分发 HLS 播放列表与分片请求
func (h *StreamHandler) handleHLS(c *gin.Context, remainder string) {
	id, file, _ := strings.Cut(remainder, "/")
	sourceID, p, err := service.ParseHLSSessionID(id)
	if mapStreamError(c, err) {
		return
	}
	log.Printf("[HLS] 请求 sourceID=%d path=%s resource=%q", sourceID, p, file)

	sess, err := h.streamSvc.EnsureHLSSession(c.Request.Context(), sourceID, p)
	if mapStreamError(c, err) {
		return
	}
	sess.Touch()

	switch {
	case file == "playlist.m3u8":
		if err := h.streamSvc.WaitPlaylist(c.Request.Context(), sess); mapStreamError(c, err) {
			log.Printf("[HLS] 等待播放列表失败 sourceID=%d err=%v", sourceID, err)
			return
		}
		log.Printf("[HLS] 返回播放列表 sourceID=%d path=%s", sourceID, p)
		c.Header("Content-Type", "application/vnd.apple.mpegurl")
		c.File(sess.PlaylistPath())

	case strings.HasPrefix(file, "segment/"):
		name := strings.TrimPrefix(file, "segment/")
		segPath, err := h.streamSvc.WaitSegment(c.Request.Context(), sess, name)
		if err != nil {
			log.Printf("[HLS] 分片不存在 sourceID=%d seg=%s err=%v", sourceID, name, err)
			Fail(c, http.StatusNotFound, http.StatusNotFound, "分片不存在")
			return
		}
		c.Header("Content-Type", "video/mp2t")
		c.File(segPath)

	default:
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "无效的 HLS 资源")
	}
}

// handleSubtitle 字幕转换：srt/ass/ssa → vtt
func (h *StreamHandler) handleSubtitle(c *gin.Context) {
	sourceID, ok := parseSourceID(c, c.Query("source"))
	if !ok {
		return
	}
	p := c.Query("path")
	if p == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 path 参数")
		return
	}
	data, err := h.streamSvc.SubtitleToVTT(c.Request.Context(), sourceID, p)
	if mapStreamError(c, err) {
		return
	}
	c.Data(http.StatusOK, "text/vtt; charset=utf-8", data)
}
