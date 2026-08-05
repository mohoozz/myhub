// myhub 命令行工具：用户管理等运维操作。
// 用法：
//
//	go run cmd/cli/main.go create-user -username admin -password 123456
//	go run cmd/cli/main.go reset-password -username admin -password newpass
package main

import (
	"flag"
	"fmt"
	"log"
	"os"

	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"myhub-server/internal/config"
	"myhub-server/internal/database"
	"myhub-server/internal/model"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	cfg, err := config.Load("")
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}
	db, err := database.Init(cfg.Database.Path)
	if err != nil {
		log.Fatalf("初始化数据库失败: %v", err)
	}
	if err := database.Migrate(db, &model.User{}); err != nil {
		log.Fatalf("数据库迁移失败: %v", err)
	}

	switch os.Args[1] {
	case "create-user":
		fs := flag.NewFlagSet("create-user", flag.ExitOnError)
		username := fs.String("username", "", "用户名（必填）")
		password := fs.String("password", "", "密码（必填）")
		_ = fs.Parse(os.Args[2:])
		if *username == "" || *password == "" {
			fmt.Fprintln(os.Stderr, "错误: -username 与 -password 均为必填")
			fs.Usage()
			os.Exit(1)
		}
		createUser(db, *username, *password)
	case "reset-password":
		fs := flag.NewFlagSet("reset-password", flag.ExitOnError)
		username := fs.String("username", "", "用户名（必填）")
		password := fs.String("password", "", "新密码（必填）")
		_ = fs.Parse(os.Args[2:])
		if *username == "" || *password == "" {
			fmt.Fprintln(os.Stderr, "错误: -username 与 -password 均为必填")
			fs.Usage()
			os.Exit(1)
		}
		resetPassword(db, *username, *password)
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Println(`myhub 命令行工具

用法:
  go run cmd/cli/main.go <command> [flags]

命令:
  create-user     创建用户    -username <用户名> -password <密码>
  reset-password  重置密码    -username <用户名> -password <新密码>`)
}

func hashPassword(password string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", fmt.Errorf("密码加密失败: %w", err)
	}
	return string(hash), nil
}

func createUser(db *gorm.DB, username, password string) {
	var count int64
	if err := db.Model(&model.User{}).Where("username = ?", username).Count(&count).Error; err != nil {
		log.Fatalf("查询用户失败: %v", err)
	}
	if count > 0 {
		log.Fatalf("创建用户失败: 用户名 %q 已存在", username)
	}

	hash, err := hashPassword(password)
	if err != nil {
		log.Fatal(err)
	}

	user := &model.User{Username: username, PasswordHash: hash}
	if err := db.Create(user).Error; err != nil {
		log.Fatalf("创建用户失败: %v", err)
	}
	fmt.Printf("用户 %q 创建成功（id=%d）\n", username, user.ID)
}

func resetPassword(db *gorm.DB, username, password string) {
	var user model.User
	if err := db.Where("username = ?", username).First(&user).Error; err != nil {
		log.Fatalf("用户 %q 不存在: %v", username, err)
	}

	hash, err := hashPassword(password)
	if err != nil {
		log.Fatal(err)
	}
	if err := db.Model(&user).Update("password_hash", hash).Error; err != nil {
		log.Fatalf("重置密码失败: %v", err)
	}
	fmt.Printf("用户 %q 密码已重置\n", username)
}
