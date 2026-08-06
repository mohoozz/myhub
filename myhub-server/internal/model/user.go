package model

import "time"

// User 用户表
type User struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	Username     string    `gorm:"size:64;uniqueIndex;not null" json:"username"`
	PasswordHash string    `gorm:"size:128;not null" json:"-"`
	Avatar       string    `gorm:"size:256" json:"avatar"` // 头像文件名（相对 avatars 目录），空表示未设置
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"-"`
}

// TableName 指定表名
func (User) TableName() string { return "users" }
