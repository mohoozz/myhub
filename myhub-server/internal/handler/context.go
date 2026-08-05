package handler

import "github.com/gin-gonic/gin"

// Context 键：JWT 中间件注入的用户信息
const (
	CtxUserID   = "userID"
	CtxUsername = "username"
)

// GetUserID 从 Context 获取当前用户 ID（须在 JWT 中间件之后调用）
func GetUserID(c *gin.Context) uint {
	if v, ok := c.Get(CtxUserID); ok {
		if id, ok := v.(uint); ok {
			return id
		}
	}
	return 0
}

// GetUsername 从 Context 获取当前用户名（须在 JWT 中间件之后调用）
func GetUsername(c *gin.Context) string {
	if v, ok := c.Get(CtxUsername); ok {
		if name, ok := v.(string); ok {
			return name
		}
	}
	return ""
}
