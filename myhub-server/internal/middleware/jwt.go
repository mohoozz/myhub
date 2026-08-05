package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/handler"
	"myhub-server/internal/service"
)

// JWTAuth JWT 鉴权中间件。
// 解析 Authorization: Bearer <token>，校验通过后将用户 ID/用户名注入 Context；
// 缺失或非法 Token 一律返回 401 并中断请求。
func JWTAuth(authSvc *service.AuthService) gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" {
			handler.Fail(c, http.StatusUnauthorized, http.StatusUnauthorized, "缺少 Authorization 请求头")
			c.Abort()
			return
		}

		// 兼容大小写与多余空格的 "Bearer " 前缀
		parts := strings.SplitN(authHeader, " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || strings.TrimSpace(parts[1]) == "" {
			handler.Fail(c, http.StatusUnauthorized, http.StatusUnauthorized, "Authorization 格式错误，应为 Bearer <token>")
			c.Abort()
			return
		}

		claims, err := authSvc.ParseToken(strings.TrimSpace(parts[1]))
		if err != nil {
			handler.Fail(c, http.StatusUnauthorized, http.StatusUnauthorized, "Token 无效或已过期")
			c.Abort()
			return
		}

		c.Set(handler.CtxUserID, claims.UserID)
		c.Set(handler.CtxUsername, claims.Username)
		c.Next()
	}
}
