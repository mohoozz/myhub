package handler

import (
	"errors"
	"net/http"

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
// 用户名密码验证（bcrypt），成功颁发 JWT（有效期取配置 jwt.expire_hours，默认 24h）
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
	Success(c, gin.H{
		"user_id":  GetUserID(c),
		"username": GetUsername(c),
	})
}
