package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/adapter"
	"myhub-server/internal/service"
)

// FileHandler 文件管理处理器
type FileHandler struct {
	fileSvc *service.FileService
}

// NewFileHandler 创建 FileHandler
func NewFileHandler(fileSvc *service.FileService) *FileHandler {
	return &FileHandler{fileSvc: fileSvc}
}

// mapFileError 文件管理错误映射；已写出响应时返回 true
func mapFileError(c *gin.Context, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, adapter.ErrNotExist):
		Fail(c, http.StatusNotFound, http.StatusNotFound, "路径不存在")
	case errors.Is(err, adapter.ErrForbidden):
		Fail(c, http.StatusForbidden, http.StatusForbidden, "路径越权")
	case errors.Is(err, adapter.ErrNotDirectory), errors.Is(err, adapter.ErrIsDirectory),
		errors.Is(err, service.ErrInvalidName), errors.Is(err, service.ErrCrossSourceDir),
		errors.Is(err, service.ErrNotVideo):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrNoFFmpeg):
		Fail(c, http.StatusNotImplemented, http.StatusNotImplemented, err.Error())
	case errors.Is(err, service.ErrSourceNotFound):
		Fail(c, http.StatusNotFound, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrInvalidSource), errors.Is(err, service.ErrSourceForbidden):
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
	default:
		_ = c.Error(err)
	}
	return true
}

// parseSourceID 解析 source 参数（query 或表单）
func parseSourceID(c *gin.Context, raw string) (uint, bool) {
	if raw != "" {
		if id, err := strconv.ParseUint(raw, 10, 64); err == nil && id > 0 {
			return uint(id), true
		}
	}
	Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少或无效的 source 参数")
	return 0, false
}

// List GET /api/files?source=&path=
func (h *FileHandler) List(c *gin.Context) {
	sourceID, ok := parseSourceID(c, c.Query("source"))
	if !ok {
		return
	}
	p := c.DefaultQuery("path", "/")
	items, err := h.fileSvc.List(c.Request.Context(), sourceID, p)
	if mapFileError(c, err) {
		return
	}
	Success(c, items)
}

// MkdirRequest 新建文件夹请求体
type MkdirRequest struct {
	Source uint   `json:"source" binding:"required"`
	Path   string `json:"path" binding:"required"`
}

// Mkdir POST /api/files/mkdir
func (h *FileHandler) Mkdir(c *gin.Context) {
	var req MkdirRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source 与 path 均为必填")
		return
	}
	if err := h.fileSvc.Mkdir(c.Request.Context(), req.Source, req.Path); mapFileError(c, err) {
		return
	}
	Success(c, nil)
}

// Upload POST /api/files/upload?source=&path=（multipart，字段名 files，支持多文件）
func (h *FileHandler) Upload(c *gin.Context) {
	sourceID, ok := parseSourceID(c, c.Query("source"))
	if !ok {
		return
	}
	dir := c.DefaultQuery("path", "/")

	form, err := c.MultipartForm()
	if err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "解析 multipart 表单失败")
		return
	}
	files := form.File["files"]
	if len(files) == 0 {
		// 兼容单文件字段名 file
		files = form.File["file"]
	}
	if len(files) == 0 {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "未找到上传文件（字段名 files）")
		return
	}

	uploaded := make([]string, 0, len(files))
	for _, fh := range files {
		f, err := fh.Open()
		if err != nil {
			Fail(c, http.StatusBadRequest, http.StatusBadRequest, "读取上传文件失败: "+fh.Filename)
			return
		}
		err = h.fileSvc.Upload(c.Request.Context(), sourceID, dir, fh.Filename, f, fh.Size)
		_ = f.Close()
		if mapFileError(c, err) {
			return
		}
		uploaded = append(uploaded, fh.Filename)
	}
	Success(c, gin.H{"uploaded": uploaded})
}

// RenameRequest 重命名请求体
type RenameRequest struct {
	Source  uint   `json:"source" binding:"required"`
	Path    string `json:"path" binding:"required"`
	NewName string `json:"new_name" binding:"required"`
}

// Rename POST /api/files/rename
func (h *FileHandler) Rename(c *gin.Context) {
	var req RenameRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source、path、new_name 均为必填")
		return
	}
	if err := h.fileSvc.Rename(c.Request.Context(), req.Source, req.Path, req.NewName); mapFileError(c, err) {
		return
	}
	Success(c, nil)
}

// TransferRequest 移动/复制请求体
type TransferRequest struct {
	Source       uint     `json:"source" binding:"required"`
	Paths        []string `json:"paths" binding:"required,min=1"`
	TargetSource uint     `json:"target_source"` // 缺省或与 source 相同为同源操作
	TargetPath   string   `json:"target_path" binding:"required"`
}

// Move POST /api/files/move
func (h *FileHandler) Move(c *gin.Context) {
	var req TransferRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source、paths、target_path 均为必填")
		return
	}
	target := req.TargetSource
	if target == 0 {
		target = req.Source
	}
	if err := h.fileSvc.Move(c.Request.Context(), req.Source, req.Paths, target, req.TargetPath); mapFileError(c, err) {
		return
	}
	Success(c, nil)
}

// Copy POST /api/files/copy
func (h *FileHandler) Copy(c *gin.Context) {
	var req TransferRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source、paths、target_path 均为必填")
		return
	}
	target := req.TargetSource
	if target == 0 {
		target = req.Source
	}
	if err := h.fileSvc.Copy(c.Request.Context(), req.Source, req.Paths, target, req.TargetPath); mapFileError(c, err) {
		return
	}
	Success(c, nil)
}

// DeleteRequest 删除请求体
type DeleteRequest struct {
	Source uint     `json:"source" binding:"required"`
	Paths  []string `json:"paths" binding:"required,min=1"`
}

// Delete DELETE /api/files（逻辑删除入回收站）
func (h *FileHandler) Delete(c *gin.Context) {
	var req DeleteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：source 与 paths 均为必填")
		return
	}
	if err := h.fileSvc.Delete(c.Request.Context(), req.Source, req.Paths); mapFileError(c, err) {
		return
	}
	Success(c, nil)
}

// Thumbnail GET /api/files/thumbnail?source=&path=（返回 JPEG 图片流）
func (h *FileHandler) Thumbnail(c *gin.Context) {
	sourceID, ok := parseSourceID(c, c.Query("source"))
	if !ok {
		return
	}
	p := c.Query("path")
	if p == "" {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "缺少 path 参数")
		return
	}
	thumbPath, err := h.fileSvc.Thumbnail(c.Request.Context(), sourceID, p)
	if mapFileError(c, err) {
		return
	}
	c.File(thumbPath)
}
