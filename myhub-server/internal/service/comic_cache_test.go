package service

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"myhub-server/internal/adapter"
	"myhub-server/internal/model"
)

// mockRemoteAdapter 模拟远程存储适配器（仅 Stat/ReadStream 生效）。
type mockRemoteAdapter struct {
	statErr   error
	streamErr error
	size      int64
	modTime   time.Time
	content   []byte
	// rangeCalls 记录 ReadStream 被调用的次数（每次代表一次远端 Range 请求）
	rangeCalls int
}

func (m *mockRemoteAdapter) List(ctx context.Context, p string) ([]adapter.FileInfo, error) {
	return nil, errors.New("mock List 未实现")
}
func (m *mockRemoteAdapter) Stat(ctx context.Context, p string) (*adapter.FileInfo, error) {
	if m.statErr != nil {
		return nil, m.statErr
	}
	return &adapter.FileInfo{Name: p, Size: m.size, ModTime: m.modTime}, nil
}
func (m *mockRemoteAdapter) ReadStream(ctx context.Context, p string, offset, length int64) (io.ReadCloser, error) {
	m.rangeCalls++
	if m.streamErr != nil {
		return nil, m.streamErr
	}
	if offset < 0 || offset >= int64(len(m.content)) {
		return io.NopCloser(bytes.NewReader(nil)), nil
	}
	end := offset + length
	if end > int64(len(m.content)) {
		end = int64(len(m.content))
	}
	if length < 0 {
		end = int64(len(m.content))
	}
	return io.NopCloser(bytes.NewReader(m.content[offset:end])), nil
}
func (m *mockRemoteAdapter) WriteStream(ctx context.Context, p string, r io.Reader, size int64) error {
	return errors.New("mock WriteStream 未实现")
}
func (m *mockRemoteAdapter) Move(ctx context.Context, src, dst string) error {
	return errors.New("mock Move 未实现")
}
func (m *mockRemoteAdapter) Copy(ctx context.Context, src, dst string) error {
	return errors.New("mock Copy 未实现")
}
func (m *mockRemoteAdapter) Delete(ctx context.Context, p string) (string, error) {
	return "", errors.New("mock Delete 未实现")
}
func (m *mockRemoteAdapter) Restore(ctx context.Context, trashPath, originalPath string) error {
	return errors.New("mock Restore 未实现")
}
func (m *mockRemoteAdapter) Purge(ctx context.Context, trashPath string) error {
	return errors.New("mock Purge 未实现")
}
func (m *mockRemoteAdapter) Mkdir(ctx context.Context, p string) error {
	return errors.New("mock Mkdir 未实现")
}
func (m *mockRemoteAdapter) Test(ctx context.Context) error {
	return errors.New("mock Test 未实现")
}

func newCacheTestService(t *testing.T, maxMB int) *ComicService {
	t.Helper()
	return &ComicService{
		cacheDir:      t.TempDir(),
		cacheMaxBytes: int64(maxMB) << 20,
	}
}

func TestCachedReaderAtRangeCache(t *testing.T) {
	svc := newCacheTestService(t, 64)
	ctx := context.Background()
	// 构造一个 200KB 内容（跨多个 64KB 块），模拟大压缩包
	content := bytes.Repeat([]byte("0123456789abcdef"), 200<<10/16) // 200KB
	a := &mockRemoteAdapter{
		size:    int64(len(content)),
		modTime: time.Now().Add(-time.Hour),
		content: content,
	}
	src := &model.Source{ID: 1}
	p := "/comics/a.cbz"

	ra, size, err := svc.openCachedReaderAt(ctx, a, src.ID, p)
	if err != nil {
		t.Fatalf("打开失败: %v", err)
	}
	if size != int64(len(content)) {
		t.Fatalf("size = %d, 期望 %d", size, len(content))
	}

	// 只读取第 0 块（前 64KB）——不应下载整包
	buf0 := make([]byte, 1024)
	n, err := ra.ReadAt(buf0, 0)
	if err != nil && err != io.EOF {
		t.Fatalf("ReadAt 失败: %v", err)
	}
	if n != 1024 || !bytes.Equal(buf0, content[:1024]) {
		t.Fatal("第 0 块内容不正确")
	}
	// 只应触发 1 次远端 Range 请求（该块整体下载）
	if a.rangeCalls != 1 {
		t.Errorf("读取 1 块应触发 1 次请求，实际 %d", a.rangeCalls)
	}

	// 再次读取同一块——命中磁盘缓存，不再请求
	buf0b := make([]byte, 2048)
	n, _ = ra.ReadAt(buf0b, 0)
	if n != 2048 || !bytes.Equal(buf0b, content[:2048]) {
		t.Fatal("再次读取块内容不正确")
	}
	if a.rangeCalls != 1 {
		t.Errorf("命中缓存后不应重复请求，实际 %d", a.rangeCalls)
	}

	// 读取跨块区域（第 0 块尾部 + 第 1 块头部）——只额外下载第 1 块
	off := int64(comicBlockSize - 100)
	span := make([]byte, 200)
	n, _ = ra.ReadAt(span, off)
	if n != 200 || !bytes.Equal(span, content[off:off+200]) {
		t.Fatal("跨块读取内容不正确")
	}
	if a.rangeCalls != 2 {
		t.Errorf("跨块应触发第 2 次请求，实际 %d", a.rangeCalls)
	}
}

func TestCachedReaderAtInvalidate(t *testing.T) {
	svc := newCacheTestService(t, 64)
	ctx := context.Background()
	contentA := bytes.Repeat([]byte("a"), 200<<10)
	a := &mockRemoteAdapter{
		size:    int64(len(contentA)),
		modTime: time.Now().Add(-time.Hour),
		content: contentA,
	}
	src := &model.Source{ID: 2}
	p := "/comics/b.cbz"

	ra, _, err := svc.openCachedReaderAt(ctx, a, src.ID, p)
	if err != nil {
		t.Fatalf("首次打开失败: %v", err)
	}
	buf := make([]byte, 4096)
	_, _ = ra.ReadAt(buf, 0)
	if a.rangeCalls != 1 {
		t.Fatalf("首次应请求 1 次，实际 %d", a.rangeCalls)
	}

	// 源文件变化（大小 + 修改时间）→ 缓存失效，重新打开应重建
	contentB := bytes.Repeat([]byte("b"), 300<<10)
	a.size = int64(len(contentB))
	a.modTime = a.modTime.Add(2 * time.Hour)
	a.content = contentB

	ra2, size2, err := svc.openCachedReaderAt(ctx, a, src.ID, p)
	if err != nil {
		t.Fatalf("失效后重新打开失败: %v", err)
	}
	if size2 != int64(len(contentB)) {
		t.Fatalf("size = %d, 期望 %d", size2, len(contentB))
	}
	buf2 := make([]byte, 4096)
	n, _ := ra2.ReadAt(buf2, 0)
	if n != 4096 || !bytes.Equal(buf2, contentB[:4096]) {
		t.Fatal("失效后内容未更新")
	}
	if a.rangeCalls != 2 {
		t.Errorf("失效后应重新请求 1 次，实际 %d", a.rangeCalls)
	}
}

func TestCachedReaderAtFallbackWhenRemoteDown(t *testing.T) {
	svc := newCacheTestService(t, 64)
	ctx := context.Background()
	content := bytes.Repeat([]byte("c"), 100<<10)
	a := &mockRemoteAdapter{
		size:    int64(len(content)),
		modTime: time.Now().Add(-time.Hour),
		content: content,
	}
	src := &model.Source{ID: 3}
	p := "/comics/c.cbz"

	ra, _, err := svc.openCachedReaderAt(ctx, a, src.ID, p)
	if err != nil {
		t.Fatalf("首次打开失败: %v", err)
	}
	_, _ = ra.ReadAt(make([]byte, 4096), 0) // 下载第 0 块
	if a.rangeCalls != 1 {
		t.Fatalf("首次应请求 1 次，实际 %d", a.rangeCalls)
	}

	// 远端不可达：回退已有块缓存（第 0 块可命中）
	a.statErr = errors.New("remote unreachable")
	ra2, size2, err := svc.openCachedReaderAt(ctx, a, src.ID, p)
	if err != nil {
		t.Fatalf("远端不可达应回退缓存，实际报错: %v", err)
	}
	if size2 != int64(len(content)) {
		t.Fatalf("回退 size = %d, 期望 %d", size2, len(content))
	}
	buf := make([]byte, 4096)
	n, err := ra2.ReadAt(buf, 0)
	if err != nil || n != 4096 || !bytes.Equal(buf, content[:4096]) {
		t.Fatal("回退缓存读取失败")
	}
	if a.rangeCalls != 1 {
		t.Errorf("回退不应触发下载，实际 %d 次", a.rangeCalls)
	}
}

func TestEvictCacheBySize(t *testing.T) {
	svc := newCacheTestService(t, 0)
	// 上限 1MB，两个文件各约 0.8MB 的内容（各 13 个 64KB 块），写入后应清理最旧的
	svc.cacheMaxBytes = 1 << 20
	ctx := context.Background()
	contentA := bytes.Repeat([]byte("A"), 800<<10)
	contentB := bytes.Repeat([]byte("B"), 800<<10)
	src := &model.Source{ID: 4}

	a := &mockRemoteAdapter{size: int64(len(contentA)), modTime: time.Now().Add(-time.Hour), content: contentA}
	ra, _, err := svc.openCachedReaderAt(ctx, a, src.ID, "/x/a.cbz")
	if err != nil {
		t.Fatalf("打开 A 失败: %v", err)
	}
	// 读取整个 A 触发全部块下载
	allA := make([]byte, len(contentA))
	_, _ = io.ReadFull(io.NewSectionReader(ra, 0, int64(len(contentA))), allA)

	b := &mockRemoteAdapter{size: int64(len(contentB)), modTime: time.Now(), content: contentB}
	rb, _, err := svc.openCachedReaderAt(ctx, b, src.ID, "/x/b.cbz")
	if err != nil {
		t.Fatalf("打开 B 失败: %v", err)
	}
	allB := make([]byte, len(contentB))
	_, _ = io.ReadFull(io.NewSectionReader(rb, 0, int64(len(contentB))), allB)

	// 重新打开 A 触发清理：总大小 1.6MB > 1MB，最旧的 A 的块应被删除
	ra2, _, err := svc.openCachedReaderAt(ctx, a, src.ID, "/x/a.cbz")
	if err != nil {
		t.Fatalf("A 被清理后重新打开失败: %v", err)
	}
	buf := make([]byte, 4096)
	n, _ := ra2.ReadAt(buf, 0)
	if n != 4096 || !bytes.Equal(buf, contentA[:4096]) {
		t.Fatal("A 重新下载内容不正确")
	}
	// A 共 13 块：首次读全部 13 次 + 清理后重读 1 次 = 14 次
	if a.rangeCalls != 14 {
		t.Errorf("A 应被清理后重新请求 1 次（共 14），实际 %d 次", a.rangeCalls)
	}
	// B 的块应仍在缓存（未被清理）：仍为首次读全部的 13 次
	if b.rangeCalls != 13 {
		t.Errorf("B 不应被清理（保持 13 次），实际请求 %d 次", b.rangeCalls)
	}
}
