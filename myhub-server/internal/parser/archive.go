package parser

import (
	"archive/zip"
	"errors"
	"io"
	"path"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/nwaples/rardecode/v2"
)

// 压缩包相关错误
var (
	ErrNotArchive  = errors.New("不是支持的压缩包格式（zip/cbz/rar/cbr）")
	ErrEntryNotFound = errors.New("压缩包内条目不存在")
)

// ArchiveEntry 压缩包条目
type ArchiveEntry struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	IsDir bool   `json:"is_dir"`
}

// imageExts 漫画页图片扩展名
var imageExts = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true,
	".webp": true, ".bmp": true, ".avif": true,
}

// IsImageName 判断文件名是否为图片
func IsImageName(name string) bool {
	return imageExts[strings.ToLower(path.Ext(name))]
}

// NaturalLess 自然排序比较：page2 < page10（数字段按数值比较）
func NaturalLess(a, b string) bool {
	ra, rb := []rune(strings.ToLower(a)), []rune(strings.ToLower(b))
	i, j := 0, 0
	for i < len(ra) && j < len(rb) {
		if unicode.IsDigit(ra[i]) && unicode.IsDigit(rb[j]) {
			// 提取完整数字段比较数值
			si, sj := i, j
			for i < len(ra) && unicode.IsDigit(ra[i]) {
				i++
			}
			for j < len(rb) && unicode.IsDigit(rb[j]) {
				j++
			}
			na, _ := strconv.ParseUint(string(ra[si:i]), 10, 64)
			nb, _ := strconv.ParseUint(string(rb[sj:j]), 10, 64)
			if na != nb {
				return na < nb
			}
			continue
		}
		if ra[i] != rb[j] {
			return ra[i] < rb[j]
		}
		i++
		j++
	}
	return len(ra) < len(rb)
}

// NaturalSort 自然排序（原地）
func NaturalSort(names []string) {
	sort.Slice(names, func(i, j int) bool { return NaturalLess(names[i], names[j]) })
}

// ListZIP 读取 ZIP 中央目录，返回全部条目（目录在前，自然排序）
func ListZIP(ra io.ReaderAt, size int64) ([]ArchiveEntry, error) {
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return nil, ErrNotArchive
	}
	return zipEntries(zr), nil
}

// zipEntries 转换 zip 条目列表
func zipEntries(zr *zip.Reader) []ArchiveEntry {
	entries := make([]ArchiveEntry, 0, len(zr.File))
	for _, f := range zr.File {
		entries = append(entries, ArchiveEntry{
			Name:  f.Name,
			Size:  int64(f.UncompressedSize64),
			IsDir: f.FileInfo().IsDir(),
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir
		}
		return NaturalLess(entries[i].Name, entries[j].Name)
	})
	return entries
}

// ZIPImagePages 返回 ZIP 内图片页列表（自然排序）
func ZIPImagePages(ra io.ReaderAt, size int64) ([]ArchiveEntry, error) {
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return nil, ErrNotArchive
	}
	var pages []ArchiveEntry
	for _, f := range zr.File {
		if !f.FileInfo().IsDir() && IsImageName(f.Name) {
			pages = append(pages, ArchiveEntry{Name: f.Name, Size: int64(f.UncompressedSize64)})
		}
	}
	sort.Slice(pages, func(i, j int) bool { return NaturalLess(pages[i].Name, pages[j].Name) })
	return pages, nil
}

// OpenZIPEntry 打开 ZIP 内指定条目流
func OpenZIPEntry(ra io.ReaderAt, size int64, name string) (io.ReadCloser, error) {
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return nil, ErrNotArchive
	}
	for _, f := range zr.File {
		if f.Name == name {
			return f.Open()
		}
	}
	return nil, ErrEntryNotFound
}

// SniffZIPComic ZIP 内容嗅探：图片占比 ≥ 90% 且 ≥ 3 张 → 漫画
func SniffZIPComic(ra io.ReaderAt, size int64) (bool, error) {
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return false, ErrNotArchive
	}
	files, images := 0, 0
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		files++
		if IsImageName(f.Name) {
			images++
		}
	}
	if files == 0 || images < 3 {
		return false, nil
	}
	return float64(images)/float64(files) >= 0.9, nil
}

// ListRAR 顺序扫描 RAR 条目（目录在前，自然排序）
func ListRAR(r io.Reader) ([]ArchiveEntry, error) {
	rr, err := rardecode.NewReader(r)
	if err != nil {
		return nil, ErrNotArchive
	}
	var entries []ArchiveEntry
	for {
		h, err := rr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		entries = append(entries, ArchiveEntry{
			Name:  h.Name,
			Size:  h.UnPackedSize,
			IsDir: h.IsDir,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir
		}
		return NaturalLess(entries[i].Name, entries[j].Name)
	})
	return entries, nil
}

// RARImagePages 返回 RAR 内图片页列表（自然排序）
func RARImagePages(r io.Reader) ([]ArchiveEntry, error) {
	entries, err := ListRAR(r)
	if err != nil {
		return nil, err
	}
	var pages []ArchiveEntry
	for _, e := range entries {
		if !e.IsDir && IsImageName(e.Name) {
			pages = append(pages, e)
		}
	}
	return pages, nil
}

// ExtractRAREntry 从 RAR 中解出指定条目（顺序扫描，写到 w）
func ExtractRAREntry(r io.Reader, name string, w io.Writer) error {
	rr, err := rardecode.NewReader(r)
	if err != nil {
		return ErrNotArchive
	}
	for {
		h, err := rr.Next()
		if err == io.EOF {
			return ErrEntryNotFound
		}
		if err != nil {
			return err
		}
		if h.Name == name && !h.IsDir {
			_, err := rr.WriteTo(w)
			return err
		}
	}
}
