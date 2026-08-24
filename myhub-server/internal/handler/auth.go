package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/service"
)

// AuthHandler 鉴权接口处理器
type AuthHandler struct {
	authSvc *service.AuthService
}

// NewAuthHandler 创建 AuthHandler
func NewAuthHandler(authSvc *service.AuthService) *AuthHandler {
	return &AuthHandler{authSvc: authSvc}
}

// LoginRequest 登录请求体
type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

// Login POST /api/auth/login
// 用户名密码验证（bcrypt），成功颁发 JWT（有效期取配置 jwt.expire_hours，默认 72h）
func (h *AuthHandler) Login(c *gin.Context) {
	var req LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：username 与 password 均为必填")
		return
	}

	token, err := h.authSvc.Login(req.Username, req.Password)
	if err != nil {
		if errors.Is(err, service.ErrInvalidCredentials) {
			Fail(c, http.StatusUnauthorized, http.StatusUnauthorized, err.Error())
			return
		}
		_ = c.Error(err)
		return
	}

	Success(c, gin.H{"token": token})
}

// ChangePasswordRequest 修改密码请求体
type ChangePasswordRequest struct {
	OldPassword string `json:"old_password" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=6"`
}

// ChangePassword PUT /api/auth/password（需 JWT）
// 需旧密码验证，通过后更新为新密码
func (h *AuthHandler) ChangePassword(c *gin.Context) {
	var req ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：old_password 必填，new_password 至少 6 位")
		return
	}

	err := h.authSvc.ChangePassword(GetUserID(c), req.OldPassword, req.NewPassword)
	if err != nil {
		if errors.Is(err, service.ErrWrongOldPassword) {
			Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
			return
		}
		_ = c.Error(err)
		return
	}

	Success(c, nil)
}

// Me GET /api/auth/me（需 JWT）：返回当前登录用户信息
func (h *AuthHandler) Me(c *gin.Context) {
	userID := GetUserID(c)
	resp := gin.H{
		"user_id":  userID,
		"username": GetUsername(c),
	}
	if v := h.authSvc.AvatarVersion(userID); v > 0 {
		resp["avatar_url"] = avatarURL(v)
	}
	Success(c, resp)
}

// 头像大小上限 5MB
const maxAvatarSize = 5 << 20

// UploadAvatar PUT /api/auth/avatar（需 JWT）
// multipart 字段 avatar，单文件，5MB 以内，jpg/jpeg/png/webp/gif。
// 成功返回 avatar_url（含 ?v= 版本号，客户端据此刷新缓存）。
func (h *AuthHandler) UploadAvatar(c *gin.Context) {
	file, err := c.FormFile("avatar")
	if err != nil {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "参数错误：缺少 avatar 文件")
		return
	}
	if file.Size <= 0 || file.Size > maxAvatarSize {
		Fail(c, http.StatusBadRequest, http.StatusBadRequest, "头像大小需在 5MB 以内")
		return
	}
	src, err := file.Open()
	if err != nil {
		_ = c.Error(err)
		return
	}
	defer src.Close()

	version, err := h.authSvc.SaveAvatar(GetUserID(c), file.Filename, src)
	if err != nil {
		if errors.Is(err, service.ErrInvalidAvatar) {
			Fail(c, http.StatusBadRequest, http.StatusBadRequest, err.Error())
			return
		}
		_ = c.Error(err)
		return
	}
	Success(c, gin.H{"avatar_url": avatarURL(version)})
}

// GetAvatar GET /api/auth/avatar（需 JWT）：返回当前用户头像图片
func (h *AuthHandler) GetAvatar(c *gin.Context) {
	p, err := h.authSvc.AvatarPath(GetUserID(c))
	if err != nil {
		Fail(c, http.StatusNotFound, http.StatusNotFound, "头像不存在")
		return
	}
	c.File(p)
}

// avatarURL 拼接带版本号的头像相对地址（防客户端缓存旧图）
func avatarURL(version int64) string {
	return "/api/auth/avatar?v=" + strconv.FormatInt(version, 10)
}
