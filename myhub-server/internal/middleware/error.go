package middleware

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"myhub-server/internal/handler"
)

// AppError 业务错误，handler 中通过 c.Error(err) 上报，
// 由 ErrorHandler 中间件统一转换为错误响应。
type AppError struct {
	HTTPStatus int    // HTTP 状态码
	Code       int    // 业务错误码
	Message    string // 错误信息
}

// Error 实现 error 接口
func (e *AppError) Error() string {
	return e.Message
}

// NewAppError 创建业务错误
func NewAppError(httpStatus, code int, message string) *AppError {
	return &AppError{HTTPStatus: httpStatus, Code: code, Message: message}
}

// ErrorHandler 全局错误处理中间件。
// 捕获 handler 通过 c.Error() 上报的错误，统一返回错误响应；
// 未匹配到 AppError 时按 500 内部错误处理。
func ErrorHandler() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()

		// 响应已写出或无错误时不处理
		if len(c.Errors) == 0 || c.Writer.Written() {
			return
		}

		err := c.Errors.Last().Err

		var appErr *AppError
		if errors.As(err, &appErr) {
			handler.Fail(c, appErr.HTTPStatus, appErr.Code, appErr.Message)
			return
		}

		handler.Fail(c, http.StatusInternalServerError, http.StatusInternalServerError, err.Error())
	}
}
