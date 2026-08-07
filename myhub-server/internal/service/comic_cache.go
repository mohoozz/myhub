package service

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"myhub-server/internal/adapter"
)

// comicCacheMeta 漫画按块缓存元数据：源文件大小与修改时间，用于失效校验。
type comicCacheMeta struct {
	Size    int64     `json:"size"`
	ModTime time.Time `json:"mod_time"`
}

// comicBlockSize 单个缓存块大小。
const comicBlockSize int64 = 64 << 10 // 64KB

// cachedReaderAt 对远程源（如 WebDAV）提供支持 Range 随机读取的
// io.ReaderAt 实现，并把读到的字节**按固定块**缓存到服务器磁盘。
//
// 与"整包下载"不同，它按需读取：ZIP/CBZ 解析中央目录只需读文件尾部，
// 取某页只需读该页附近的压缩块——首次阅读不下载整个压缩包，翻到哪页
// 才下载哪一页的字节块。二次阅读时已缓存块直接命中磁盘，无需访问远程。
type cachedReaderAt struct {
	a         adapter.IStorageAdapter
	p         string
	path      string // 块缓存文件基础路径（键 = SHA1(sourceID:path)）
	size      int64  // 源文件总大小
	blockSize int64  // 单个缓存块大小
	blockMu   sync.Map // 块索引 → *sync.Mutex，防并发重复下载同一块
}

// blockCount 缓存块总数。
func (c *cachedReaderAt) blockCount() int64 {
	if c.size <= 0 {
		return 0
	}
	return (c.size + c.blockSize - 1) / c.blockSize
}

// ReadAt 实现 io.ReaderAt：按需 Range 读取远程并把整块落盘缓存。
func (c *cachedReaderAt) ReadAt(p []byte, off int64) (int, error) {
	if off < 0 || off >= c.size {
		return 0, io.EOF
	}
	if len(p) == 0 {
		return 0, nil
	}
	n := 0
	remaining := p
	for off < c.size && len(remaining) > 0 {
		block := off / c.blockSize
		blockStart := block * c.blockSize
		within := int(off - blockStart)
		blockEnd := blockStart + c.blockSize
		if blockEnd > c.size {
			blockEnd = c.size
		}
		avail := int(blockEnd - off)
		if avail <= 0 {
			break
		}
		want := len(remaining)
		if want > avail {
			want = avail
		}
		seg, err := c.loadBlock(block)
		if err != nil {
			return n, err
		}
		copy(remaining[:want], seg[within:within+want])
		remaining = remaining[want:]
		n += want
		off += int64(want)
	}
	if n == 0 {
		return 0, io.EOF
	}
	return n, nil
}

// loadBlock 返回第 block 块的字节：优先读磁盘缓存；未命中且持有远程
// 适配器时 Range 下载整块并落盘；回退模式（远端不可达构建，a 为 nil）
// 仅读磁盘，未命中直接报错。
func (c *cachedReaderAt) loadBlock(block int64) ([]byte, error) {
	// 已缓存则直接读盘
	if b, err := os.ReadFile(c.blockPath(block)); err == nil {
		return b, nil
	}
	if c.a == nil {
		return nil, fmt.Errorf("远端不可用且缓存块未命中（block %d）", block)
	}
	// 每块互斥，防并发重复下载
	mu := c.blockMutex(block)
	mu.Lock()
	defer mu.Unlock()
	// 双检：等待期间其他协程可能已下载
	if b, err := os.ReadFile(c.blockPath(block)); err == nil {
		return b, nil
	}

	start := block * c.blockSize
	length := c.blockSize
	if start+length > c.size {
		length = c.size - start
	}
	rc, err := c.a.ReadStream(context.Background(), c.p, start, length)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(c.path), 0o755); err == nil {
		_ = os.WriteFile(c.blockPath(block), data, 0o644)
	}
	return data, nil
}

// blockMutex 获取指定块的下载互斥锁（懒创建）。
func (c *cachedReaderAt) blockMutex(block int64) *sync.Mutex {
	v, _ := c.blockMu.LoadOrStore(block, &sync.Mutex{})
	return v.(*sync.Mutex)
}

// blockPath 返回第 block 块的缓存文件路径。
func (c *cachedReaderAt) blockPath(block int64) string {
	return fmt.Sprintf("%s.%d", c.path, block)
}

// Close 无持有资源需显式关闭（块文件常驻磁盘复用）。
func (c *cachedReaderAt) Close() error { return nil }

// openCachedReaderAt 打开远程源的按块缓存 ReaderAt：
//
//   - 远端 Stat 成功且与缓存元数据一致 → 复用已下载的块缓存；
//   - 不一致或无元数据 → 重建块缓存（删除旧块文件）并写入新元数据；
//   - 远端不可达时尽力回退已有块缓存，避免网络抖动打断阅读。
//
// 返回的 io.ReaderAt 可安全并发使用。
func (s *ComicService) openCachedReaderAt(ctx context.Context, a adapter.IStorageAdapter, sourceID uint, p string) (io.ReaderAt, int64, error) {
	if err := os.MkdirAll(s.cacheDir, 0o755); err != nil {
		return nil, 0, err
	}
	key := comicCacheKey(sourceID, p)
	basePath := filepath.Join(s.cacheDir, key)
	metaPath := basePath + ".meta"

	fi, err := a.Stat(ctx, p)
	if err != nil {
		// 远端元信息获取失败：尽力回退已有块缓存
		if ra, ok := s.tryCachedReaderAt(basePath); ok {
			return ra, ra.size, nil
		}
		return nil, 0, err
	}
	size, modTime := fi.Size, fi.ModTime

	if !s.metaMatches(metaPath, size, modTime) {
		s.resetCache(basePath)
		if meta, err := json.Marshal(comicCacheMeta{Size: size, ModTime: modTime}); err == nil {
			_ = os.WriteFile(metaPath, meta, 0o644)
		}
	}

	c := &cachedReaderAt{
		a:         a,
		p:         p,
		path:      basePath,
		size:      size,
		blockSize: comicBlockSize,
	}
	s.evictCache()
	return c, size, nil
}

// tryCachedReaderAt 读取元数据并尝试构建块缓存 ReaderAt（远端不可达回退用）。
func (s *ComicService) tryCachedReaderAt(basePath string) (*cachedReaderAt, bool) {
	b, err := os.ReadFile(basePath + ".meta")
	if err != nil {
		return nil, false
	}
	var meta comicCacheMeta
	if err := json.Unmarshal(b, &meta); err != nil {
		return nil, false
	}
	// 需存在至少一个块文件才算可用
	entries, err := os.ReadDir(s.cacheDir)
	if err != nil {
		return nil, false
	}
	prefix := filepath.Base(basePath) + "."
	found := false
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), prefix) && !strings.HasSuffix(e.Name(), ".meta") {
			found = true
			break
		}
	}
	if !found {
		return nil, false
	}
	return &cachedReaderAt{
		a:         nil,
		p:         "",
		path:      basePath,
		size:      meta.Size,
		blockSize: comicBlockSize,
	}, true
}

// metaMatches 元数据与远端大小/修改时间是否一致。
func (s *ComicService) metaMatches(metaPath string, size int64, modTime time.Time) bool {
	b, err := os.ReadFile(metaPath)
	if err != nil {
		return false
	}
	var meta comicCacheMeta
	if err := json.Unmarshal(b, &meta); err != nil {
		return false
	}
	return meta.Size == size && meta.ModTime.Equal(modTime)
}

// resetCache 删除某缓存键下全部块文件与元数据（源变化时重建）。
func (s *ComicService) resetCache(basePath string) {
	prefix := filepath.Base(basePath) + "."
	entries, err := os.ReadDir(s.cacheDir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), prefix) {
			_ = os.Remove(filepath.Join(s.cacheDir, e.Name()))
		}
	}
	_ = os.Remove(basePath + ".meta")
}

// comicCacheKey 缓存键：源 ID + 路径的 SHA1。
func comicCacheKey(sourceID uint, p string) string {
	sum := sha1.Sum([]byte(fmt.Sprintf("%d:%s", sourceID, p)))
	return hex.EncodeToString(sum[:])
}

// evictCache 缓存目录总大小超过上限时，按修改时间删除最旧缓存文件（尽力而为）。
func (s *ComicService) evictCache() {
	if s.cacheMaxBytes <= 0 {
		return
	}
	entries, err := os.ReadDir(s.cacheDir)
	if err != nil {
		return
	}

	type cachedFile struct {
		path string
		mod  time.Time
	}
	var files []cachedFile
	var total int64
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".meta") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		total += info.Size()
		files = append(files, cachedFile{
			path: filepath.Join(s.cacheDir, name),
			mod:  info.ModTime(),
		})
	}
	if total <= s.cacheMaxBytes {
		return
	}

	sort.Slice(files, func(i, j int) bool { return files[i].mod.Before(files[j].mod) })
	for _, f := range files {
		if total <= s.cacheMaxBytes {
			break
		}
		if info, err := os.Stat(f.path); err == nil {
			total -= info.Size()
		}
		_ = os.Remove(f.path)
	}
	// 清理孤儿元数据（无对应块文件的 .meta）
	seen := map[string]bool{}
	entries2, _ := os.ReadDir(s.cacheDir)
	for _, e := range entries2 {
		seen[e.Name()] = true
	}
	for _, e := range entries2 {
		name := e.Name()
		if strings.HasSuffix(name, ".meta") {
			base := strings.TrimSuffix(name, ".meta")
			hasBlock := false
			for k := range seen {
				if k == base {
					continue
				}
				if strings.HasPrefix(k, base+".") {
					hasBlock = true
					break
				}
			}
			if !hasBlock {
				_ = os.Remove(filepath.Join(s.cacheDir, name))
			}
		}
	}
}
