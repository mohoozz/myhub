package service

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"

	"myhub-server/internal/config"
	"myhub-server/internal/repository"
)

// 鉴权相关业务错误
var (
	ErrInvalidCredentials = errors.New("用户名或密码错误")
	ErrWrongOldPassword   = errors.New("原密码错误")
	ErrInvalidAvatar      = errors.New("仅支持 jpg/jpeg/png/webp/gif 图片")
	ErrAvatarNotFound     = errors.New("头像不存在")
)

// Claims JWT 自定义声明
type Claims struct {
	UserID   uint   `json:"user_id"`
	Username string `json:"username"`
	jwt.RegisteredClaims
}

// AuthService 鉴权业务逻辑
type AuthService struct {
	cfg      *config.Config
	userRepo *repository.UserRepository
}

// NewAuthService 创建 AuthService
func NewAuthService(cfg *config.Config, userRepo *repository.UserRepository) *AuthService {
	return &AuthService{cfg: cfg, userRepo: userRepo}
}

// Login 校验用户名密码，成功返回 JWT 字符串
func (s *AuthService) Login(username, password string) (string, error) {
	user, err := s.userRepo.FindByUsername(username)
	if err != nil {
		// 不区分用户不存在与密码错误，防止用户名枚举
		return "", ErrInvalidCredentials
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		return "", ErrInvalidCredentials
	}
	return s.GenerateToken(user.ID, user.Username)
}

// ChangePassword 修改密码：先验证旧密码，再更新
func (s *AuthService) ChangePassword(userID uint, oldPassword, newPassword string) error {
	user, err := s.userRepo.FindByID(userID)
	if err != nil {
		return fmt.Errorf("用户不存在: %w", err)
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(oldPassword)); err != nil {
		return ErrWrongOldPassword
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("密码加密失败: %w", err)
	}
	return s.userRepo.UpdatePassword(userID, string(hash))
}

// SaveAvatar 保存用户头像：扩展名白名单校验后写入 avatars 目录
//（文件名 <userID><ext>，旧扩展名文件一并清理），并更新用户记录。
// 返回头像版本号（UpdatedAt 秒级时间戳），供客户端拼接 ?v= 防缓存。
func (s *AuthService) SaveAvatar(userID uint, filename string, src io.Reader) (int64, error) {
	ext := strings.ToLower(filepath.Ext(filename))
	switch ext {
	case ".jpg", ".jpeg", ".png", ".webp", ".gif":
	default:
		return 0, ErrInvalidAvatar
	}

	dir := s.cfg.Data.AvatarsDir
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, fmt.Errorf("创建头像目录失败: %w", err)
	}
	name := fmt.Sprintf("%d%s", userID, ext)
	dst := filepath.Join(dir, name)
	f, err := os.Create(dst)
	if err != nil {
		return 0, fmt.Errorf("写入头像失败: %w", err)
	}
	defer f.Close()
	if _, err := io.Copy(f, src); err != nil {
		return 0, fmt.Errorf("写入头像失败: %w", err)
	}

	// 清理同用户旧扩展名文件（如 1.png → 1.jpg）
	for _, old := range []string{".jpg", ".jpeg", ".png", ".webp", ".gif"} {
		if old != ext {
			_ = os.Remove(filepath.Join(dir, fmt.Sprintf("%d%s", userID, old)))
		}
	}

	if err := s.userRepo.UpdateAvatar(userID, name); err != nil {
		return 0, fmt.Errorf("更新头像记录失败: %w", err)
	}
	user, err := s.userRepo.FindByID(userID)
	if err != nil {
		return 0, fmt.Errorf("用户不存在: %w", err)
	}
	return user.UpdatedAt.Unix(), nil
}

// AvatarPath 返回用户头像文件的磁盘路径；未设置或文件缺失返回 ErrAvatarNotFound。
func (s *AuthService) AvatarPath(userID uint) (string, error) {
	user, err := s.userRepo.FindByID(userID)
	if err != nil {
		return "", ErrAvatarNotFound
	}
	if user.Avatar == "" {
		return "", ErrAvatarNotFound
	}
	p := filepath.Join(s.cfg.Data.AvatarsDir, user.Avatar)
	if fi, err := os.Stat(p); err != nil || fi.IsDir() {
		return "", ErrAvatarNotFound
	}
	return p, nil
}

// AvatarVersion 返回头像版本号（UpdatedAt 秒级时间戳）；未设置返回 0。
func (s *AuthService) AvatarVersion(userID uint) int64 {
	user, err := s.userRepo.FindByID(userID)
	if err != nil || user.Avatar == "" {
		return 0
	}
	return user.UpdatedAt.Unix()
}

// GenerateToken 为用户颁发 JWT（有效期取配置 jwt.expire_hours）
func (s *AuthService) GenerateToken(userID uint, username string) (string, error) {
	expireHours := s.cfg.JWT.ExpireHours
	if expireHours <= 0 {
		expireHours = 24
	}
	now := time.Now()
	claims := Claims{
		UserID:   userID,
		Username: username,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "myhub-server",
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Duration(expireHours) * time.Hour)),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(s.cfg.JWT.Secret))
}

// ParseToken 解析并校验 JWT，成功返回 Claims
func (s *AuthService) ParseToken(tokenString string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("非预期的签名算法: %v", t.Header["alg"])
		}
		return []byte(s.cfg.JWT.Secret), nil
	})
	if err != nil {
		return nil, err
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, errors.New("无效的 Token")
	}
	return claims, nil
}
