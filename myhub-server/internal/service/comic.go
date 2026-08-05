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
}

// ComicService 漫画阅读业务逻辑
type ComicService struct {
	sourceSvc  *SourceService
	configRepo *repository.ConfigRepository
}

// NewComicService 创建 ComicService
func NewComicService(sourceSvc *SourceService, configRepo *repository.ConfigRepository) *ComicService {
	return &ComicService{sourceSvc: sourceSvc, configRepo: configRepo}
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

// openReaderAt 打开随机访问 Reader：本地源直接文件，其他源加载内存
func (s *ComicService) openReaderAt(ctx context.Context, sourceID uint, p string) (io.ReaderAt, int64, io.Closer, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, 0, nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, 0, nil, err
	}
	if la, ok := a.(*adapter.LocalAdapter); ok {
		abs := filepath.Join(la.Root(), filepath.FromSlash(strings.TrimPrefix(p, "/")))
		f, err := os.Open(abs)
		if err != nil {
			return nil, 0, nil, err
		}
		return f, fi.Size, f, nil
	}
	rc, err := a.ReadStream(ctx, p, 0, -1)
	if err != nil {
		return nil, 0, nil, err
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, 512<<20))
	if err != nil {
		return nil, 0, nil, err
	}
	return bytes.NewReader(data), int64(len(data)), nil, nil
}

// openStream 打开顺序读取流（RAR 用）
func (s *ComicService) openStream(ctx context.Context, sourceID uint, p string) (io.ReadCloser, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	return a.ReadStream(ctx, p, 0, -1)
}

// Pages 漫画页列表（ZIP/CBZ 中央目录，RAR/CBR 顺序扫描，EPUB 图集按 spine/manifest）
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
		entries, err := parser.ZIPImagePages(ra, size)
		if err != nil {
			return nil, err
		}
		return toComicPages(entries), nil

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
		return s.epubPages(ctx, sourceID, p)

	default:
		return nil, parser.ErrNotArchive
	}
}

// epubPages EPUB 图集页列表：spine 顺序中的图片条目；无 spine 图片时回退 manifest 图片自然排序
func (s *ComicService) epubPages(ctx context.Context, sourceID uint, p string) ([]ComicPage, error) {
	e, closer, err := s.openEPUBViaReader(ctx, sourceID, p)
	if err != nil {
		return nil, err
	}
	if closer != nil {
		defer closer.Close()
	}

	var pages []ComicPage
	for _, idref := range e.Spine {
		if it, ok := e.Manifest[idref]; ok && strings.HasPrefix(it.MediaType, "image/") {
			pages = append(pages, ComicPage{Index: len(pages), Name: it.Href})
		}
	}
	if len(pages) == 0 {
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
	}
	if len(pages) == 0 {
		return nil, ErrNotComic
	}
	return pages, nil
}

// openEPUBViaReader 复用 ReaderService 的 EPUB 打开逻辑（独立实例避免循环依赖）
func (s *ComicService) openEPUBViaReader(ctx context.Context, sourceID uint, p string) (*parser.EPUB, io.Closer, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, nil, err
	}
	if la, ok := a.(*adapter.LocalAdapter); ok {
		abs := filepath.Join(la.Root(), filepath.FromSlash(strings.TrimPrefix(p, "/")))
		f, err := os.Open(abs)
		if err != nil {
			return nil, nil, err
		}
		e, err := parser.OpenEPUB(f, fi.Size)
		if err != nil {
			_ = f.Close()
			return nil, nil, err
		}
		return e, f, nil
	}
	rc, err := a.ReadStream(ctx, p, 0, -1)
	if err != nil {
		return nil, nil, err
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, 512<<20))
	if err != nil {
		return nil, nil, err
	}
	e, err := parser.OpenEPUB(bytes.NewReader(data), int64(len(data)))
	return e, nil, err
}

// toComicPages 转换条目为页列表
func toComicPages(entries []parser.ArchiveEntry) []ComicPage {
	pages := make([]ComicPage, 0, len(entries))
	for _, e := range entries {
		pages = append(pages, ComicPage{Index: len(pages), Name: e.Name, Size: e.Size})
	}
	return pages
}

// Page 返回单页图片内容（页码从 0 开始，与 Pages 返回的 index 对应）
func (s *ComicService) Page(ctx context.Context, sourceID uint, p string, n int) ([]byte, string, error) {
	if n < 0 {
		return nil, "", ErrPageOutOfRange
	}
	pages, err := s.Pages(ctx, sourceID, p)
	if err != nil {
		return nil, "", err
	}
	if n >= len(pages) {
		return nil, "", ErrPageOutOfRange
	}
	name := pages[n].Name

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
		rc, err := parser.OpenZIPEntry(ra, size, name)
		if err != nil {
			return nil, "", err
		}
		defer rc.Close()
		data, err := io.ReadAll(rc)
		return data, name, err

	case ".rar", ".cbr":
		rc, err := s.openStream(ctx, sourceID, p)
		if err != nil {
			return nil, "", err
		}
		defer rc.Close()
		var buf bytes.Buffer
		if err := parser.ExtractRAREntry(rc, name, &buf); err != nil {
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
		data, err := e.ReadByHref(name)
		return data, name, err

	default:
		return nil, "", parser.ErrNotArchive
	}
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
