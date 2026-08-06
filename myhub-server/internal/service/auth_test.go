package service

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"myhub-server/internal/config"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// newAvatarTestSvc 构建内存库 + 临时头像目录的 AuthService，并预置一个用户。
func newAvatarTestSvc(t *testing.T) (*AuthService, uint, string) {
	t.Helper()
	dir := t.TempDir()

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&model.User{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}

	repo := repository.NewUserRepository(db)
	hash, _ := bcrypt.GenerateFromPassword([]byte("pass"), bcrypt.DefaultCost)
	user := &model.User{Username: "admin", PasswordHash: string(hash)}
	if err := repo.Create(user); err != nil {
		t.Fatalf("创建用户失败: %v", err)
	}

	cfg := &config.Config{}
	cfg.Data.AvatarsDir = filepath.Join(dir, "avatars")
	return NewAuthService(cfg, repo), user.ID, cfg.Data.AvatarsDir
}

func TestSaveAvatarAndPath(t *testing.T) {
	svc, uid, dir := newAvatarTestSvc(t)

	version, err := svc.SaveAvatar(uid, "photo.PNG", bytes.NewReader([]byte("fake-png")))
	if err != nil {
		t.Fatalf("SaveAvatar 失败: %v", err)
	}
	if version <= 0 {
		t.Fatalf("版本号应大于 0, 得到 %d", version)
	}

	p, err := svc.AvatarPath(uid)
	if err != nil {
		t.Fatalf("AvatarPath 失败: %v", err)
	}
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("读取头像文件失败: %v", err)
	}
	if string(data) != "fake-png" {
		t.Fatalf("头像内容不符: %q", data)
	}
	if filepath.Base(p) != "1.png" {
		t.Fatalf("文件名应为 1.png（扩展名小写）, 得到 %s", filepath.Base(p))
	}

	// 换扩展名重新上传：旧文件应被清理
	if _, err := svc.SaveAvatar(uid, "new.jpg", bytes.NewReader([]byte("fake-jpg"))); err != nil {
		t.Fatalf("重复 SaveAvatar 失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "1.png")); !os.IsNotExist(err) {
		t.Fatalf("旧扩展名文件应被清理")
	}
	if _, err := svc.AvatarPath(uid); err != nil {
		t.Fatalf("AvatarPath 重新读取失败: %v", err)
	}
}

func TestSaveAvatarInvalidExt(t *testing.T) {
	svc, uid, _ := newAvatarTestSvc(t)
	if _, err := svc.SaveAvatar(uid, "a.txt", bytes.NewReader([]byte("x"))); !errors.Is(err, ErrInvalidAvatar) {
		t.Fatalf("应返回 ErrInvalidAvatar, 得到 %v", err)
	}
}

func TestAvatarNotFound(t *testing.T) {
	svc, uid, _ := newAvatarTestSvc(t)
	if _, err := svc.AvatarPath(uid); !errors.Is(err, ErrAvatarNotFound) {
		t.Fatalf("未设置头像应返回 ErrAvatarNotFound, 得到 %v", err)
	}
	if v := svc.AvatarVersion(uid); v != 0 {
		t.Fatalf("未设置头像版本应为 0, 得到 %d", v)
	}
}
