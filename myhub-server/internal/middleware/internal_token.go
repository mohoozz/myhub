package middleware

import (
	"crypto/subtle"
	"net/http"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/config"
	"myhub-server/internal/handler"
)

// InternalTokenHeader 内部接口令牌请求头
const InternalTokenHeader = "X-Internal-Token"

// InternalToken 内部接口 Token 校验中间件（供 OpenClaw 等内部服务回传）。
// 校验 X-Internal-Token 请求头与配置 internal.token 是否一致（常量时间比较防时序攻击）。
func InternalToken(cfg *config.Config) gin.HandlerFunc {
	expected := []byte(cfg.Internal.Token)
	return func(c *gin.Context) {
		token := c.GetHeader(InternalTokenHeader)
		if token == "" || subtle.ConstantTimeCompare([]byte(token), expected) != 1 {
			handler.Fail(c, http.StatusUnauthorized, http.StatusUnauthorized, "内部接口令牌无效")
			c.Abort()
			return
		}
		c.Next()
	}
}
