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
	"sync"

	"myhub-server/internal/adapter"
	"myhub-server/internal/model"
	"myhub-server/internal/parser"
	"myhub-server/internal/repository"
)

// 阅读器相关业务错误
var (
	ErrChapterOutOfRange = errors.New("章节序号超出范围")
	ErrIndexBuilding     = errors.New("索引构建中，请稍后重试")
	ErrNotNovel          = errors.New("不是支持的小说格式（txt/epub）")
)

const (
	// novelAsyncThreshold 大文件异步建索引阈值（4MB）
	novelAsyncThreshold = 4 << 20
	// novelPageSize 索引未就绪时的固定分页字节数（32KB 原始字节）
	novelPageSize = 32 << 10
	// epubMaxBytes WebDAV 源 EPUB 加载上限（512MB）
	epubMaxBytes = 512 << 20
	// encodingSampleSize 编码检测采样字节数
	encodingSampleSize = 64 << 10
)

// ChapterView 章节视图（不含字节区间细节）
type ChapterView struct {
	Index int    `json:"index"`
	Title string `json:"title"`
}

// NovelChaptersResult 章节列表响应
type NovelChaptersResult struct {
	Ready    bool          `json:"ready"` // false 表示索引构建中
	Encoding string        `json:"encoding,omitempty"`
	Chapters []ChapterView `json:"chapters,omitempty"`
	Total    int           `json:"total"`
}

// NovelContentResult 章节内容响应
type NovelContentResult struct {
	Ready   bool   `json:"ready"`
	Chapter int    `json:"chapter"`
	Title   string `json:"title"`
	Content string `json:"content"`
	Total   int    `json:"total"` // 就绪时为章节总数；未就绪时为固定分页总页数
}

// ReaderService 小说阅读业务逻辑
type ReaderService struct {
	sourceSvc *SourceService
	novelRepo *repository.NovelIndexRepository

	mu       sync.Mutex
	building map[string]bool // key: "sourceID|path"，标记后台建索引进行中
}

// NewReaderService 创建 ReaderService
func NewReaderService(sourceSvc *SourceService, novelRepo *repository.NovelIndexRepository) *ReaderService {
	return &ReaderService{
		sourceSvc: sourceSvc,
		novelRepo: novelRepo,
		building:  make(map[string]bool),
	}
}

// loadCachedIndex 读取缓存索引；文件大小变化则视为失效
func (s *ReaderService) loadCachedIndex(sourceID uint, p string, fileSize int64) (*model.NovelIndex, []parser.Chapter) {
	idx, err := s.novelRepo.GetByPath(sourceID, p)
	if err != nil || idx.FileSize != fileSize {
		return nil, nil
	}
	var chapters []parser.Chapter
	if err := json.Unmarshal([]byte(idx.ChaptersJSON), &chapters); err != nil || len(chapters) == 0 {
		return nil, nil
	}
	return idx, chapters
}

// buildIndex 构建并缓存索引（同步执行）
func (s *ReaderService) buildIndex(ctx context.Context, sourceID uint, p string, fileSize int64) ([]parser.Chapter, string, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, "", err
	}

	// 采样检测编码
	sampleRC, err := a.ReadStream(ctx, p, 0, encodingSampleSize)
	if err != nil {
		return nil, "", err
	}
	sample, _ := io.ReadAll(sampleRC)
	_ = sampleRC.Close()
	encName := parser.DetectEncoding(sample)

	// 全量流式扫描
	rc, err := a.ReadStream(ctx, p, 0, -1)
	if err != nil {
		return nil, "", err
	}
	chapters := parser.BuildTXTIndex(rc, encName, fileSize)
	_ = rc.Close()

	// 缓存入库
	data, _ := json.Marshal(chapters)
	if err := s.novelRepo.Upsert(&model.NovelIndex{
		SourceID:     sourceID,
		FilePath:     p,
		Encoding:     encName,
		ChaptersJSON: string(data),
		FileSize:     fileSize,
	}); err != nil {
		return nil, "", fmt.Errorf("索引缓存写入失败: %w", err)
	}
	return chapters, encName, nil
}

// GetNovelChapters 获取章节列表；大文件未缓存时后台异步建索引
func (s *ReaderService) GetNovelChapters(ctx context.Context, sourceID uint, p string) (*NovelChaptersResult, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
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

	// 缓存命中
	if idx, chapters := s.loadCachedIndex(sourceID, p, fi.Size); idx != nil {
		return chaptersResult(chapters, idx.Encoding), nil
	}

	key := fmt.Sprintf("%d|%s", sourceID, p)
	s.mu.Lock()
	if s.building[key] {
		s.mu.Unlock()
		return &NovelChaptersResult{Ready: false}, nil
	}

	// 大文件：后台异步建索引
	if fi.Size > novelAsyncThreshold {
		s.building[key] = true
		s.mu.Unlock()
		go func() {
			defer func() {
				s.mu.Lock()
				delete(s.building, key)
				s.mu.Unlock()
			}()
			_, _, _ = s.buildIndex(context.Background(), sourceID, p, fi.Size)
		}()
		return &NovelChaptersResult{Ready: false}, nil
	}
	s.mu.Unlock()

	// 小文件：同步建索引
	chapters, encName, err := s.buildIndex(ctx, sourceID, p, fi.Size)
	if err != nil {
		return nil, err
	}
	return chaptersResult(chapters, encName), nil
}

func chaptersResult(chapters []parser.Chapter, encName string) *NovelChaptersResult {
	views := make([]ChapterView, 0, len(chapters))
	for i, ch := range chapters {
		views = append(views, ChapterView{Index: i, Title: ch.Title})
	}
	return &NovelChaptersResult{Ready: true, Encoding: encName, Chapters: views, Total: len(views)}
}

// GetNovelContent 获取章节内容（按字节区间读取并解码为 UTF-8）。
// 索引未就绪时按固定分页返回（chapter 参数为页号）。
func (s *ReaderService) GetNovelContent(ctx context.Context, sourceID uint, p string, chapter int) (*NovelContentResult, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, err
	}

	// 索引就绪：按章节区间返回
	if idx, chapters := s.loadCachedIndex(sourceID, p, fi.Size); idx != nil {
		if chapter < 0 || chapter >= len(chapters) {
			return nil, ErrChapterOutOfRange
		}
		ch := chapters[chapter]
		content, err := s.readRange(ctx, a, p, ch.Start, ch.End-ch.Start, idx.Encoding)
		if err != nil {
			return nil, err
		}
		return &NovelContentResult{
			Ready: true, Chapter: chapter, Title: ch.Title,
			Content: content, Total: len(chapters),
		}, nil
	}

	// 未就绪：固定分页（原始字节，按页号切）
	if chapter < 0 {
		return nil, ErrChapterOutOfRange
	}
	start := int64(chapter) * novelPageSize
	if start >= fi.Size {
		return nil, ErrChapterOutOfRange
	}
	length := int64(novelPageSize)
	if start+length > fi.Size {
		length = fi.Size - start
	}

	// 采样检测编码（前台快速路径）
	sampleRC, err := a.ReadStream(ctx, p, 0, encodingSampleSize)
	if err != nil {
		return nil, err
	}
	sample, _ := io.ReadAll(sampleRC)
	_ = sampleRC.Close()
	encName := parser.DetectEncoding(sample)

	content, err := s.readRange(ctx, a, p, start, length, encName)
	if err != nil {
		return nil, err
	}
	totalPages := int((fi.Size + novelPageSize - 1) / novelPageSize)
	return &NovelContentResult{
		Ready: false, Chapter: chapter, Title: fmt.Sprintf("第 %d 页", chapter+1),
		Content: content, Total: totalPages,
	}, nil
}

// readRange 读取字节区间并解码为 UTF-8 字符串
func (s *ReaderService) readRange(ctx context.Context, a adapter.IStorageAdapter, p string, offset, length int64, encName string) (string, error) {
	rc, err := a.ReadStream(ctx, p, offset, length)
	if err != nil {
		return "", err
	}
	defer rc.Close()
	raw, err := io.ReadAll(rc)
	if err != nil {
		return "", err
	}
	return parser.DecodeString(encName, raw), nil
}

// --- EPUB ---

// EpubMetaResult EPUB 元数据响应
type EpubMetaResult struct {
	Title   string          `json:"title"`
	Author  string          `json:"author"`
	CoverID string          `json:"cover_id"` // 封面 manifest ID，经 resource 接口取
	IsComic bool            `json:"is_comic"`
	TOC     []parser.TOCItem `json:"toc"`
}

// openEPUB 打开 EPUB：本地源直接文件随机访问，WebDAV 源加载到内存
func (s *ReaderService) openEPUB(ctx context.Context, sourceID uint, p string) (*parser.EPUB, io.Closer, error) {
	a, _, err := s.sourceSvc.GetAdapter(sourceID)
	if err != nil {
		return nil, nil, err
	}
	fi, err := a.Stat(ctx, p)
	if err != nil {
		return nil, nil, err
	}
	if fi.IsDir {
		return nil, nil, adapter.ErrIsDirectory
	}

	// 本地源：直接打开文件，避免全量加载
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

	// 其他源：读入内存
	if fi.Size > epubMaxBytes {
		return nil, nil, fmt.Errorf("EPUB 文件过大（>%dMB）", epubMaxBytes>>20)
	}
	rc, err := a.ReadStream(ctx, p, 0, -1)
	if err != nil {
		return nil, nil, err
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, nil, err
	}
	e, err := parser.OpenEPUB(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, nil, err
	}
	return e, nil, nil
}

// GetEpubMeta 获取 EPUB 元数据
func (s *ReaderService) GetEpubMeta(ctx context.Context, sourceID uint, p string) (*EpubMetaResult, error) {
	e, closer, err := s.openEPUB(ctx, sourceID, p)
	if err != nil {
		return nil, err
	}
	if closer != nil {
		defer closer.Close()
	}
	return &EpubMetaResult{
		Title:   e.Title,
		Author:  e.Author,
		CoverID: e.CoverItemID(),
		IsComic: e.IsComic,
		TOC:     e.TOC,
	}, nil
}

// GetEpubChapter 获取章节 HTML 内容
func (s *ReaderService) GetEpubChapter(ctx context.Context, sourceID uint, p, id string) ([]byte, error) {
	e, closer, err := s.openEPUB(ctx, sourceID, p)
	if err != nil {
		return nil, err
	}
	if closer != nil {
		defer closer.Close()
	}
	data, _, err := e.ReadItem(id)
	return data, err
}

// GetEpubResource 获取静态资源（图片/CSS 等），返回内容与 MediaType
func (s *ReaderService) GetEpubResource(ctx context.Context, sourceID uint, p, id string) ([]byte, string, error) {
	e, closer, err := s.openEPUB(ctx, sourceID, p)
	if err != nil {
		return nil, "", err
	}
	if closer != nil {
		defer closer.Close()
	}
	return e.ReadItem(id)
}
