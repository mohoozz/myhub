package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/model"
	"myhub-server/internal/service"
)

// ProgressHandler 阅读进度处理器
type ProgressHandler struct {
	progressSvc *service.ProgressService
}

// NewProgressHandler 创建 ProgressHandler
func NewProgressHandler(progressSvc *service.ProgressService) *ProgressHandler {
	return &ProgressHandler{progressSvc: progressSvc}
}

// List GET /api/progress
func (h *ProgressHandler) List(c *gin.Context) {
	items, err := h.progressSvc.List()
	if err != nil {
		_ = c.Error(err)
		return
	}
	Success(c, items)
}

// SaveRequest 保存进度请求体
type SaveRequest struct {
	SourceID     uint    `json:"source_id" binding:"required"`
	FilePath     string  `json:"file_path" binding:"required"`
	MediaType    string  `json:"media_type" binding:"required"`
	Title        string  `json:"title"`
	Cover        string  `json:"cover"`
	ProgressJSON string  `json:"progress_json"`
	Percent      float64 `json:"percent"`
	Finished     bool    `json:"finished"`
}

// Save PUT /api/progress（upsert）
func (h *ProgressHandler) Save(c *gin.Context) {
	var req SaveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source_id、file_path、media_type 均为必填")
		return
	}
	p := &model.ReadingProgress{
		SourceID:     req.SourceID,
		FilePath:     req.FilePath,
		MediaType:    req.MediaType,
		Title:        req.Title,
		Cover:        req.Cover,
		ProgressJSON: req.ProgressJSON,
		Percent:      req.Percent,
		Finished:     req.Finished,
	}
	if err := h.progressSvc.Save(p); err != nil {
		if errors.Is(err, service.ErrInvalidProgress) {
			Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：media_type 须为 novel/comic/video/audio，percent 须在 0~100")
			return
		}
		_ = c.Error(err)
		return
	}
	Success(c, nil)
}

// FinishRequest 标记已读完请求体
type FinishRequest struct {
	SourceID uint   `json:"source_id" binding:"required"`
	FilePath string `json:"file_path" binding:"required"`
}

// Finish DELETE /api/progress（标记已读完）
func (h *ProgressHandler) Finish(c *gin.Context) {
	var req FinishRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source_id 与 file_path 均为必填")
		return
	}
	if err := h.progressSvc.MarkFinished(req.SourceID, req.FilePath); err != nil {
		if errors.Is(err, service.ErrProgressNotFound) {
			Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
			return
		}
		_ = c.Error(err)
		return
	}
	Success(c, nil)
}
