package parser

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	_ "image/gif"  // DecodeConfig 格式注册
	_ "image/jpeg" // DecodeConfig 格式注册
	_ "image/png"  // DecodeConfig 格式注册
	"io"
	"path"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/nwaples/rardecode/v2"
	_ "golang.org/x/image/bmp"  // DecodeConfig 格式注册
	_ "golang.org/x/image/webp" // DecodeConfig 格式注册
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

// ImageSize 从图片流解码像素尺寸（仅读文件头，开销极小）；
// 支持 jpeg/png/gif/webp/bmp，avif 走 ISOBMFF 容器 ispe 盒兜底
// 解析，其余不识别的格式返回 0,0。
func ImageSize(r io.Reader) (int, int) {
	// 读入少量头部字节：先走注册解码器，失败后按 avif 容器兜底
	head, _ := io.ReadAll(io.LimitReader(r, 64<<10))
	cfg, _, err := image.DecodeConfig(bytes.NewReader(head))
	if err == nil {
		return cfg.Width, cfg.Height
	}
	return avifSize(head)
}

// avifSize 解析 AVIF（HEIF/ISOBMFF 容器）尺寸：ftyp 品牌校验后
// 沿 meta → iprp → ipco → ispe 盒层级取宽高。无 Go 解码器可用，
// 仅作兜底；解析失败返回 0,0（客户端按实测宽高比回退）。
func avifSize(data []byte) (int, int) {
	if len(data) < 12 || string(data[4:8]) != "ftyp" {
		return 0, 0
	}
	if brand := string(data[8:12]); brand != "avif" && brand != "avis" {
		return 0, 0
	}
	meta := findISOBMFFBox(data, "meta")
	if len(meta) < 4 {
		return 0, 0
	}
	iprp := findISOBMFFBox(meta[4:], "iprp") // meta 为 FullBox，跳过版本/标志
	ipco := findISOBMFFBox(iprp, "ipco")
	ispe := findISOBMFFBox(ipco, "ispe")
	if len(ispe) < 12 { // FullBox 4 字节 + 宽高各 4 字节
		return 0, 0
	}
	w := binary.BigEndian.Uint32(ispe[4:8])
	h := binary.BigEndian.Uint32(ispe[8:12])
	if w == 0 || h == 0 {
		return 0, 0
	}
	return int(w), int(h)
}

// findISOBMFFBox 在盒序列中查找指定类型的盒，返回其负载（不含盒头）。
func findISOBMFFBox(data []byte, typ string) []byte {
	for len(data) >= 8 {
		size := uint64(binary.BigEndian.Uint32(data[0:4]))
		header := 8
		if size == 1 { // largesize
			if len(data) < 16 {
				return nil
			}
			size = binary.BigEndian.Uint64(data[8:16])
			header = 16
		}
		if size == 0 { // 延伸至末尾
			size = uint64(len(data))
		}
		if size < uint64(header) || size > uint64(len(data)) {
			return nil
		}
		if string(data[4:8]) == typ {
			return data[header:size]
		}
		data = data[size:]
	}
	return nil
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
