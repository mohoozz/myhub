package repository

import (
	"errors"

	"gorm.io/gorm"

	"myhub-server/internal/model"
)

// UserRepository 用户数据访问
type UserRepository struct {
	db *gorm.DB
}

// NewUserRepository 创建 UserRepository
func NewUserRepository(db *gorm.DB) *UserRepository {
	return &UserRepository{db: db}
}

// FindByUsername 按用户名查找用户，未找到返回 gorm.ErrRecordNotFound
func (r *UserRepository) FindByUsername(username string) (*model.User, error) {
	var user model.User
	if err := r.db.Where("username = ?", username).First(&user).Error; err != nil {
		return nil, err
	}
	return &user, nil
}

// FindByID 按 ID 查找用户
func (r *UserRepository) FindByID(id uint) (*model.User, error) {
	var user model.User
	if err := r.db.First(&user, id).Error; err != nil {
		return nil, err
	}
	return &user, nil
}

// Create 创建用户，用户名重复时返回 ErrUserExists
var ErrUserExists = errors.New("用户名已存在")

func (r *UserRepository) Create(user *model.User) error {
	var count int64
	if err := r.db.Model(&model.User{}).Where("username = ?", user.Username).Count(&count).Error; err != nil {
		return err
	}
	if count > 0 {
		return ErrUserExists
	}
	return r.db.Create(user).Error
}

// UpdatePassword 更新指定用户的密码哈希
func (r *UserRepository) UpdatePassword(id uint, passwordHash string) error {
	return r.db.Model(&model.User{}).Where("id = ?", id).Update("password_hash", passwordHash).Error
}
