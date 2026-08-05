//go:build tools

// Package tools 固定尚未被代码直接引用的核心依赖，防止 go mod tidy 将其移除。
// 这些依赖在 M1 里程碑会被正式使用：
//   - golang-jwt/jwt/v5：登录鉴权签发/校验 Token（TODO 1.2）
//   - robfig/cron/v3：回收站定时清理、动态抓取调度（TODO 1.6 / 1.12）
//   - golang.org/x/crypto：bcrypt 密码哈希（TODO 1.2）
package tools

import (
	_ "github.com/golang-jwt/jwt/v5"
	_ "github.com/robfig/cron/v3"
	_ "golang.org/x/crypto/bcrypt"
)
