package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"myhub-server/internal/adapter"
	"myhub-server/internal/parser"
	"myhub-server/internal/repository"
)

// 漫画相关业务错误
var (
	ErrNotComic       = errors.New("不是漫画文件")
	ErrPageOutOfRange = errors.New("页码超出范围")
)

// comicOverrideKey 手动覆盖标记的配置键
func comicOverrideKey(sourceID uint, p string) string {
	return fmt.Sprintf("comic_override:%d:%s", sourceID, p)
}

// ComicDetectResult 漫画识别结果
type ComicDetectResult struct {
	IsComic bool   `json:"is_comic"`
	Reason  string `json:"reason"` // override/ext/source/sniff/epub/none
}

// ComicPage 漫画页信息
type ComicPage struct {
	Index int    `json:"index"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	// 图片像素尺寸（仅 ZIP/CBZ、EPUB 提供，供客户端精确计算
	// 条漫页高与进度恢复；RAR 顺序扫描代价高不提供，为 0）
	Width  int `json:"width"`
	Height int `json:"height"`
}

// ComicService 漫画阅读业务逻辑
type ComicService struct {
	sourceSvc  *SourceService
	configRepo *repository.ConfigRepository
	// 远程源漫画按块缓存目录与容量上限（<=0 不限制），见 comic_cache.go
	cacheDir      string
	cacheMaxBytes int64
}

// NewComicService 创建 ComicService
func NewComicService(sourceSvc *SourceService, configRepo *repository.ConfigRepository, cacheDir string, cacheMaxMB int) *ComicService {
	return &ComicService{
		sourceSvc:      sourceSvc,
		configRepo:     configRepo,
		cacheDir:       cacheDir,
		cacheMaxBytes:  int64(cacheMaxMB) << 20,
	}
}

// Detect 漫画识别：手动覆盖 > 扩展名 > 路径源标记 > 内容嗅探
func (s *ComicService) Detect(ctx context.Context, sourceID uint, p string) (*ComicDetectResult, error) {
	a, source, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, err
	}
	if fi.IsDir {
		return nil, adapter.ErrIsDirectory
	}

	// 1. 手动覆盖
	if v, err := s.configRepo.Get(comicOverrideKey(sourceID, p)); err == nil && v != "" {
		return &ComicDetectResult{IsComic: v == "true", Reason: "override"}, nil
	}

	ext := strings.ToLower(filepath.Ext(p))

	// 2. 扩展名优先
	if ext == ".cbz" || ext == ".cbr" {
		return &ComicDetectResult{IsComic: true, Reason: "ext"}, nil
	}

	// 3. 路径源标记为漫画库（config_json 含 "comic_library":true）
	if isComicLibrary(source.ConfigJSON) && isArchiveExt(ext) {
		return &ComicDetectResult{IsComic: true, Reason: "source"}, nil
	}

	// 4. EPUB：按图集型判定
	if ext == ".epub" {
		e, closer, err := s.openEPUBViaReader(ctx, sourceID, p)
		if err != nil {
			return nil, err
		}
		if closer != nil {
			defer closer.Close()
		}
		return &ComicDetectResult{IsComic: e.IsComic, Reason: "epub"}, nil
	}

	// 5. ZIP 内容嗅探
	if ext == ".zip" {
		ra, size, closer, err := s.openReaderAt(ctx, sourceID, p)
		if err != nil {
			return nil, err
		}
		if closer != nil {
			defer closer.Close()
		}
		isComic, err := parser.SniffZIPComic(ra, size)
		if err != nil {
			return nil, err
		}
		if isComic {
			return &ComicDetectResult{IsComic: true, Reason: "sniff"}, nil
		}
	}

	return &ComicDetectResult{IsComic: false, Reason: "none"}, nil
}

// isComicLibrary 解析路径源 config_json 中的漫画库标记
func isComicLibrary(configJSON string) bool {
	if configJSON == "" {
		return false
	}
	var cfg struct {
		ComicLibrary bool `json:"comic_library"`
	}
	return json.Unmarshal([]byte(configJSON), &cfg) == nil && cfg.ComicLibrary
}

// isArchiveExt 是否为压缩包扩展名
func isArchiveExt(ext string) bool {
	switch ext {
	case ".zip", ".cbz", ".rar", ".cbr":
		return true
	}
	return false
}

// SetOverride 手动覆盖漫画标记
func (s *ComicService) SetOverride(sourceID uint, p string, isComic bool) error {
	v := "false"
	if isComic {
		v = "true"
	}
	return s.configRepo.Set(comicOverrideKey(sourceID, p), v)
}

// openReaderAt 打开随机访问 Reader（ZIP/CBZ/EPUB 用）：
//   - 本地源：直接读文件；
//   - 远程源（如 WebDAV）：按块 Range 缓存 ReaderAt，按需下载页面字节块，
//     避免整包下载，二次阅读命中本地磁盘缓存。
func (s *ComicService) openReaderAt(ctx context.Context, sourceID uint, p string) (io.ReaderAt, int64, io.Closer, error) {
	a, source, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, 0, nil, err
	}
	if la, ok := a.(*adapter.LocalAdapter); ok {
		abs := filepath.Join(la.Root(), filepath.FromSlash(strings.TrimPrefix(p, "/")))
		f, err := os.Open(abs)
		if err != nil {
			return nil, 0, nil, err
		}
		st, err := f.Stat()
		if err != nil {
			_ = f.Close()
			return nil, 0, nil, err
		}
		return f, st.Size(), f, nil
	}
	ra, size, err := s.openCachedReaderAt(ctx, a, source.ID, p)
	if err != nil {
		return nil, 0, nil, err
	}
	return ra, size, nopCloser{}, nil
}

// nopCloser 空关闭器（cachedReaderAt 的 Close 为空，无需持有磁盘句柄）。
type nopCloser struct{}

func (nopCloser) Close() error { return nil }

// openStream 打开顺序读取流（RAR/CBR 用）：RAR 必须顺序解压，无法按块
// Range 随机读，故始终走远程流式（本地源直接读文件）。
func (s *ComicService) openStream(ctx context.Context, sourceID uint, p string) (io.ReadCloser, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	if la, ok := a.(*adapter.LocalAdapter); ok {
		abs := filepath.Join(la.Root(), filepath.FromSlash(strings.TrimPrefix(p, "/")))
		return os.Open(abs)
	}
	return a.ReadStream(ctx, p, 0, -1)
}

// Pages 漫画页列表（ZIP/CBZ 中央目录，RAR/CBR 顺序扫描，EPUB 图集按
// spine/manifest），并逐页解码图片尺寸（仅读文件头，供客户端条漫
// 模式精确计算页高与进度恢复；RAR 顺序扫描代价高不提供）。
func (s *ComicService) Pages(ctx context.Context, sourceID uint, p string) ([]ComicPage, error) {
	ext := strings.ToLower(filepath.Ext(p))
	switch ext {
	case ".zip", ".cbz":
		ra, size, closer, err := s.openReaderAt(ctx, sourceID, p)
		if err != nil {
			return nil, err
		}
		if closer != nil {
			defer closer.Close()
		}
		pages, err := zipComicPages(ra, size)
		if err != nil {
			return nil, err
		}
		fillZIPPageSizes(ra, size, pages)
		return pages, nil

	case ".rar", ".cbr":
		rc, err := s.openStream(ctx, sourceID, p)
		if err != nil {
			return nil, err
		}
		defer rc.Close()
		entries, err := parser.RARImagePages(rc)
		if err != nil {
			return nil, err
		}
		return toComicPages(entries), nil

	case ".epub":
		return s.epubPages(ctx, sourceID, p, true)

	default:
		return nil, parser.ErrNotArchive
	}
}

// zipComicPages ZIP 图片页列表（不含尺寸，Page 取图等轻量路径用）
func zipComicPages(ra io.ReaderAt, size int64) ([]ComicPage, error) {
	entries, err := parser.ZIPImagePages(ra, size)
	if err != nil {
		return nil, err
	}
	return toComicPages(entries), nil
}

// fillZIPPageSizes 逐页解码图片尺寸回填（仅读文件头，失败页保持 0）
func fillZIPPageSizes(ra io.ReaderAt, size int64, pages []ComicPage) {
	for i := range pages {
		rc, err := parser.OpenZIPEntry(ra, size, pages[i].Name)
		if err != nil {
			continue
		}
		pages[i].Width, pages[i].Height = parser.ImageSize(rc)
		_ = rc.Close()
	}
}

// epubPages EPUB 图集页列表：spine 顺序中的图片条目；无 spine 图片时
// 回退 manifest 图片自然排序。withSizes 时逐页解码图片尺寸回填
// （仅读文件头，失败页保持 0；Page 取图等轻量路径传 false）。
func (s *ComicService) epubPages(ctx context.Context, sourceID uint, p string, withSizes bool) ([]ComicPage, error) {
	e, closer, err := s.openEPUBViaReader(ctx, sourceID, p)
	if err != nil {
		return nil, err
	}
	if closer != nil {
		defer closer.Close()
	}

	pages := epubImagePages(e)
	if len(pages) == 0 {
		return nil, ErrNotComic
	}
	if withSizes {
		for i := range pages {
			data, err := e.ReadByHref(pages[i].Name)
			if err != nil {
				continue
			}
			pages[i].Width, pages[i].Height = parser.ImageSize(bytes.NewReader(data))
		}
	}
	return pages, nil
}

// openEPUBViaReader 复用 ReaderService 的 EPUB 打开逻辑（独立实例避免循环依赖）
func (s *ComicService) openEPUBViaReader(ctx context.Context, sourceID uint, p string) (*parser.EPUB, io.Closer, error) {
	ra, size, closer, err := s.openReaderAt(ctx, sourceID, p)
	if err != nil {
		return nil, nil, err
	}
	e, err := parser.OpenEPUB(ra, size)
	if err != nil {
		if closer != nil {
			_ = closer.Close()
		}
		return nil, nil, err
	}
	return e, closer, nil
}

// toComicPages 转换条目为页列表
func toComicPages(entries []parser.ArchiveEntry) []ComicPage {
	pages := make([]ComicPage, 0, len(entries))
	for _, e := range entries {
		pages = append(pages, ComicPage{Index: len(pages), Name: e.Name, Size: e.Size})
	}
	return pages
}

// Page 返回单页图片内容（页码从 0 开始，与 Pages 返回的 index 对应）。
// 页列表走轻量路径（不解码图片尺寸），避免每次取图全量扫描。
func (s *ComicService) Page(ctx context.Context, sourceID uint, p string, n int) ([]byte, string, error) {
	if n < 0 {
		return nil, "", ErrPageOutOfRange
	}
	ext := strings.ToLower(filepath.Ext(p))
	switch ext {
	case ".zip", ".cbz":
		ra, size, closer, err := s.openReaderAt(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		if closer != nil {
			defer closer.Close()
		}
		pages, err := zipComicPages(ra, size)
		if err != nil {
			return nil, "", err
		}
		if n >= len(pages) {
			return nil, "", ErrPageOutOfRange
		}
		rc, err := parser.OpenZIPEntry(ra, size, pages[n].Name)
		if err != nil {
			return nil, "", err
		}
		defer rc.Close()
		data, err := io.ReadAll(rc)
		return data, pages[n].Name, err

	case ".rar", ".cbr":
		rc, err := s.openStream(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		defer rc.Close()
		entries, err := parser.RARImagePages(rc)
		if err != nil {
			return nil, "", err
		}
		if n >= len(entries) {
			return nil, "", ErrPageOutOfRange
		}
		name := entries[n].Name
		rc2, err := s.openStream(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		defer rc2.Close()
		var buf bytes.Buffer
		if err := parser.ExtractRAREntry(rc2, name, &buf); err != nil {
			return nil, "", err
		}
		return buf.Bytes(), name, nil

	case ".epub":
		e, closer, err := s.openEPUBViaReader(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		if closer != nil {
			defer closer.Close()
		}
		pages := epubImagePages(e)
		if n >= len(pages) {
			return nil, "", ErrPageOutOfRange
		}
		data, err := e.ReadByHref(pages[n].Name)
		return data, pages[n].Name, err

	default:
		return nil, "", parser.ErrNotArchive
	}
}

// epubImagePages EPUB 图集页列表：spine 顺序中的图片条目；无 spine
// 图片时回退 manifest 图片自然排序。
func epubImagePages(e *parser.EPUB) []ComicPage {
	var pages []ComicPage
	for _, idref := range e.Spine {
		if it, ok := e.Manifest[idref]; ok && strings.HasPrefix(it.MediaType, "image/") {
			pages = append(pages, ComicPage{Index: len(pages), Name: it.Href})
		}
	}
	if len(pages) > 0 {
		return pages
	}
	names := make([]string, 0, len(e.Manifest))
	for _, it := range e.Manifest {
		if strings.HasPrefix(it.MediaType, "image/") {
			names = append(names, it.Href)
		}
	}
	parser.NaturalSort(names)
	for _, n := range names {
		pages = append(pages, ComicPage{Index: len(pages), Name: n})
	}
	return pages
}

// ArchiveTree 普通压缩包文件树
func (s *ComicService) ArchiveTree(ctx context.Context, sourceID uint, p string) ([]parser.ArchiveEntry, error) {
	ext := strings.ToLower(filepath.Ext(p))
	switch ext {
	case ".zip", ".cbz":
		ra, size, closer, err := s.openReaderAt(ctx, sourceID, p)
		if err != nil {
			return nil, err
		}
		if closer != nil {
			defer closer.Close()
		}
		return parser.ListZIP(ra, size)

	case ".rar", ".cbr":
		rc, err := s.openStream(ctx, sourceID, p)
		if err != nil {
			return nil, err
		}
		defer rc.Close()
		return parser.ListRAR(rc)

	default:
		return nil, parser.ErrNotArchive
	}
}

// ArchiveFile 解出压缩包内单个文件
func (s *ComicService) ArchiveFile(ctx context.Context, sourceID uint, p, entry string) ([]byte, string, error) {
	if entry == "" || strings.Contains(entry, "..") {
		return nil, "", fmt.Errorf("非法的条目名")
	}
	ext := strings.ToLower(filepath.Ext(p))
	switch ext {
	case ".zip", ".cbz":
		ra, size, closer, err := s.openReaderAt(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		if closer != nil {
			defer closer.Close()
		}
		rc, err := parser.OpenZIPEntry(ra, size, entry)
		if err != nil {
			return nil, "", err
		}
		defer rc.Close()
		data, err := io.ReadAll(io.LimitReader(rc, 256<<20))
		return data, entry, err

	case ".rar", ".cbr":
		rc, err := s.openStream(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		defer rc.Close()
		var buf bytes.Buffer
		if err := parser.ExtractRAREntry(rc, entry, &buf); err != nil {
			return nil, "", err
		}
		return buf.Bytes(), entry, nil

	default:
		return nil, "", parser.ErrNotArchive
	}
}
