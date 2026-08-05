package adapter

import (
	"context"
	"errors"
	"io"
	"time"
)

// TrashDirName 回收站目录名（位于挂载点根目录下）
const TrashDirName = ".trash"

// 适配器层统一错误
var (
	ErrNotExist     = errors.New("路径不存在")
	ErrNotDirectory = errors.New("不是目录")
	ErrIsDirectory  = errors.New("是目录")
	ErrForbidden    = errors.New("路径越权：不在挂载点范围内")
	ErrEmptyPath    = errors.New("路径不能为空")
	ErrTargetExists = errors.New("目标已存在")
)

// FileInfo 统一的文件/目录元信息
type FileInfo struct {
	Name    string    `json:"name"`     // 文件/目录名
	Path    string    `json:"path"`     // 相对挂载点的路径（正斜杠分隔）
	Size    int64     `json:"size"`     // 字节数，目录为 0
	IsDir   bool      `json:"is_dir"`   // 是否目录
	ModTime time.Time `json:"mod_time"` // 修改时间
}

// IStorageAdapter 存储适配器接口。
// 所有 path 均为相对挂载点根目录的路径（"/" 表示根），实现方负责防目录穿越。
// ReadStream 的 length < 0 表示从 offset 读到文件末尾。
// Delete 为逻辑删除：移入挂载点下的 .trash/ 目录，返回回收站相对路径。
type IStorageAdapter interface {
	// List 列出目录内容（目录在前，按名称排序）
	List(ctx context.Context, path string) ([]FileInfo, error)
	// Stat 获取单个文件/目录元信息
	Stat(ctx context.Context, path string) (*FileInfo, error)
	// ReadStream 流式读取，支持 Range（offset/length）
	ReadStream(ctx context.Context, path string, offset, length int64) (io.ReadCloser, error)
	// WriteStream 流式写入（覆盖已存在文件），size 未知时传 -1
	WriteStream(ctx context.Context, path string, r io.Reader, size int64) error
	// Move 同源移动/重命名
	Move(ctx context.Context, src, dst string) error
	// Copy 同源复制（支持目录递归）
	Copy(ctx context.Context, src, dst string) error
	// Delete 逻辑删除：移入 .trash/，返回回收站内相对路径
	Delete(ctx context.Context, path string) (trashPath string, err error)
	// Restore 从回收站还原到原始路径
	Restore(ctx context.Context, trashPath, originalPath string) error
	// Purge 物理删除回收站内文件（彻底删除，不可恢复）
	Purge(ctx context.Context, trashPath string) error
	// Mkdir 新建目录（递归创建父目录）
	Mkdir(ctx context.Context, path string) error
	// Test 连接测试：验证挂载点可用
	Test(ctx context.Context) error
}
