package adapter

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// LocalAdapter 本地磁盘存储适配器。
// 基于 os 包实现；构造时校验挂载点根目录在白名单内；
// 所有相对路径解析后强制限制在根目录内，防止目录穿越。
type LocalAdapter struct {
	root string // 挂载点根目录（绝对路径，已解析符号链接）
}

// NewLocalAdapter 创建本地适配器。
// root 为挂载点根目录；allowedRoots 非空时 root 必须等于或位于其中之一内部。
func NewLocalAdapter(root string, allowedRoots []string) (*LocalAdapter, error) {
	if strings.TrimSpace(root) == "" {
		return nil, ErrEmptyPath
	}

	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("解析挂载点失败: %w", err)
	}
	// 解析符号链接，得到真实路径用于前缀校验
	real, err := filepath.EvalSymlinks(abs)
	if err == nil {
		abs = real
	}

	// 白名单校验
	if len(allowedRoots) > 0 {
		allowed := false
		for _, ar := range allowedRoots {
			arAbs, err := filepath.Abs(ar)
			if err != nil {
				continue
			}
			if r, err := filepath.EvalSymlinks(arAbs); err == nil {
				arAbs = r
			}
			if pathWithin(arAbs, abs) {
				allowed = true
				break
			}
		}
		if !allowed {
			return nil, fmt.Errorf("%w：挂载点 %q 不在白名单内", ErrForbidden, root)
		}
	}

	return &LocalAdapter{root: abs}, nil
}

// Root 返回挂载点根目录（绝对路径）
func (a *LocalAdapter) Root() string { return a.root }

// pathWithin 判断 p 是否等于 parent 或位于其内部
func pathWithin(parent, p string) bool {
	parent = filepath.Clean(parent)
	p = filepath.Clean(p)
	if p == parent {
		return true
	}
	return strings.HasPrefix(p, parent+string(os.PathSeparator))
}

// resolve 将相对路径解析为绝对路径，并强制限制在根目录内。
// 输入 "/a/b" 或 "a/b" 均可；空或 "/" 表示根目录。
func (a *LocalAdapter) resolve(path string) (string, error) {
	// 先按 POSIX 风格清洗，使 "/" 与 "\" 均可传入；
	// filepath.Clean 以 "/" 为根清洗可消除所有 ".." 上跳
	cleaned := filepath.Clean(string(filepath.Separator) + filepath.ToSlash(path))
	full := filepath.Join(a.root, cleaned)

	if !pathWithin(a.root, full) {
		return "", ErrForbidden
	}

	// 路径已存在时，解析符号链接后再次校验，防止通过链接跳出根目录
	if _, err := os.Lstat(full); err == nil {
		if real, err := filepath.EvalSymlinks(full); err == nil && !pathWithin(a.root, real) {
			return "", ErrForbidden
		}
	}
	return full, nil
}

// rel 将绝对路径转回相对根目录的 POSIX 风格路径
func (a *LocalAdapter) rel(full string) string {
	r, err := filepath.Rel(a.root, full)
	if err != nil || r == "." {
		return "/"
	}
	return "/" + filepath.ToSlash(r)
}

// toFileInfo 将 fs.FileInfo 转换为统一 FileInfo
func (a *LocalAdapter) toFileInfo(full string, fi fs.FileInfo) FileInfo {
	size := fi.Size()
	if fi.IsDir() {
		size = 0
	}
	return FileInfo{
		Name:    fi.Name(),
		Path:    a.rel(full),
		Size:    size,
		IsDir:   fi.IsDir(),
		ModTime: fi.ModTime(),
	}
}

// Test 连接测试：根目录必须存在且为目录
func (a *LocalAdapter) Test(ctx context.Context) error {
	fi, err := os.Stat(a.root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotExist
		}
		return err
	}
	if !fi.IsDir() {
		return ErrNotDirectory
	}
	return nil
}

// List 列出目录内容（目录在前，按名称排序），自动隐藏 .trash 目录
func (a *LocalAdapter) List(ctx context.Context, path string) ([]FileInfo, error) {
	full, err := a.resolve(path)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(full)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotExist
		}
		return nil, err
	}

	infos := make([]FileInfo, 0, len(entries))
	for _, e := range entries {
		// 回收站目录不在列表中暴露
		if full == a.root && e.Name() == TrashDirName {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue // 跳过无法读取的条目（如权限不足）
		}
		infos = append(infos, a.toFileInfo(filepath.Join(full, e.Name()), fi))
	}

	sort.Slice(infos, func(i, j int) bool {
		if infos[i].IsDir != infos[j].IsDir {
			return infos[i].IsDir
		}
		return strings.ToLower(infos[i].Name) < strings.ToLower(infos[j].Name)
	})
	return infos, nil
}

// Stat 获取单个文件/目录元信息
func (a *LocalAdapter) Stat(ctx context.Context, path string) (*FileInfo, error) {
	full, err := a.resolve(path)
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(full)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotExist
		}
		return nil, err
	}
	info := a.toFileInfo(full, fi)
	return &info, nil
}

// ReadStream 流式读取：offset 定位，length < 0 读到末尾
func (a *LocalAdapter) ReadStream(ctx context.Context, path string, offset, length int64) (io.ReadCloser, error) {
	full, err := a.resolve(path)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotExist
		}
		return nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	if fi.IsDir() {
		_ = f.Close()
		return nil, ErrIsDirectory
	}
	if offset > 0 {
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			_ = f.Close()
			return nil, err
		}
	}
	if length < 0 {
		return f, nil
	}
	return &readCloserWrapper{Reader: io.LimitReader(f, length), Closer: f}, nil
}

// WriteStream 流式写入（覆盖已存在文件），自动创建父目录
func (a *LocalAdapter) WriteStream(ctx context.Context, path string, r io.Reader, size int64) error {
	full, err := a.resolve(path)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return err
	}
	f, err := os.Create(full)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := io.Copy(f, r); err != nil {
		return err
	}
	return nil
}

// Move 移动/重命名；跨盘符时退化为复制+删除
func (a *LocalAdapter) Move(ctx context.Context, src, dst string) error {
	srcFull, err := a.resolve(src)
	if err != nil {
		return err
	}
	dstFull, err := a.resolve(dst)
	if err != nil {
		return err
	}
	if _, err := os.Stat(srcFull); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotExist
		}
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dstFull), 0o755); err != nil {
		return err
	}
	if err := os.Rename(srcFull, dstFull); err != nil {
		// 跨设备移动：复制后删除
		if err := copyPath(srcFull, dstFull); err != nil {
			return err
		}
		return os.RemoveAll(srcFull)
	}
	return nil
}

// Copy 复制文件或递归复制目录
func (a *LocalAdapter) Copy(ctx context.Context, src, dst string) error {
	srcFull, err := a.resolve(src)
	if err != nil {
		return err
	}
	dstFull, err := a.resolve(dst)
	if err != nil {
		return err
	}
	if _, err := os.Stat(srcFull); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotExist
		}
		return err
	}
	return copyPath(srcFull, dstFull)
}

// Delete 逻辑删除：移入 .trash/<时间戳>_<原名>，返回回收站内相对路径
func (a *LocalAdapter) Delete(ctx context.Context, path string) (string, error) {
	full, err := a.resolve(path)
	if err != nil {
		return "", err
	}
	if full == a.root {
		return "", ErrForbidden // 不允许删除根目录
	}
	if _, err := os.Stat(full); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", ErrNotExist
		}
		return "", err
	}

	trashDir := filepath.Join(a.root, TrashDirName)
	if err := os.MkdirAll(trashDir, 0o755); err != nil {
		return "", err
	}

	// 生成回收站内唯一文件名
	name := fmt.Sprintf("%s_%s", time.Now().Format("20060102150405"), filepath.Base(full))
	trashFull := filepath.Join(trashDir, name)
	for i := 1; ; i++ {
		if _, err := os.Lstat(trashFull); errors.Is(err, os.ErrNotExist) {
			break
		}
		trashFull = filepath.Join(trashDir, fmt.Sprintf("%s_%d", name, i))
	}

	if err := os.Rename(full, trashFull); err != nil {
		return "", err
	}
	return a.rel(trashFull), nil
}

// Restore 从回收站还原到原始路径（自动创建父目录；目标已存在时报错）
func (a *LocalAdapter) Restore(ctx context.Context, trashPath, originalPath string) error {
	trashFull, err := a.resolve(trashPath)
	if err != nil {
		return err
	}
	// 只允许从 .trash 目录内还原
	if filepath.Dir(trashFull) != filepath.Join(a.root, TrashDirName) {
		return fmt.Errorf("%w：仅允许从 %s 目录还原", ErrForbidden, TrashDirName)
	}
	origFull, err := a.resolve(originalPath)
	if err != nil {
		return err
	}
	if _, err := os.Stat(trashFull); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotExist
		}
		return err
	}
	if _, err := os.Lstat(origFull); err == nil {
		return fmt.Errorf("%w: %s", ErrTargetExists, originalPath)
	}
	if err := os.MkdirAll(filepath.Dir(origFull), 0o755); err != nil {
		return err
	}
	return os.Rename(trashFull, origFull)
}

// Purge 物理删除回收站内文件（仅限 .trash 目录内）
func (a *LocalAdapter) Purge(ctx context.Context, trashPath string) error {
	full, err := a.resolve(trashPath)
	if err != nil {
		return err
	}
	if filepath.Dir(full) != filepath.Join(a.root, TrashDirName) {
		return fmt.Errorf("%w：仅允许清空 %s 目录内文件", ErrForbidden, TrashDirName)
	}
	if _, err := os.Lstat(full); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotExist
		}
		return err
	}
	return os.RemoveAll(full)
}

// Mkdir 新建目录（递归创建父目录）
func (a *LocalAdapter) Mkdir(ctx context.Context, path string) error {
	full, err := a.resolve(path)
	if err != nil {
		return err
	}
	return os.MkdirAll(full, 0o755)
}

// readCloserWrapper 将 LimitReader 与底层文件句柄组合为 ReadCloser
type readCloserWrapper struct {
	io.Reader
	io.Closer
}

// copyPath 复制文件或递归复制目录
func copyPath(src, dst string) error {
	fi, err := os.Stat(src)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return copyFile(src, dst)
	}
	if err := os.MkdirAll(dst, fi.Mode()); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

// copyFile 流式复制单个文件
func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}
