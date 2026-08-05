// Package handler 提供统一的 HTTP 响应格式与各类请求处理器。
package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// Response 统一响应结构：{ "code": 0, "data": ..., "message": "" }
// code 为 0 表示成功，非 0 为业务错误码。
type Response struct {
	Code    int         `json:"code"`
	Data    interface{} `json:"data"`
	Message string      `json:"message"`
}

// Success 返回成功响应，HTTP 状态码固定 200，业务码 0。
func Success(c *gin.Context, data interface{}) {
	c.JSON(http.StatusOK, Response{
		Code:    0,
		Data:    data,
		Message: "",
	})
}

// Fail 返回失败响应，httpStatus 为 HTTP 状态码，code 为业务错误码。
func Fail(c *gin.Context, httpStatus int, code int, message string) {
	c.JSON(httpStatus, Response{
		Code:    code,
		Data:    nil,
		Message: message,
	})
}
