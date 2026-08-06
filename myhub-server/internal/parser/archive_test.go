package parser

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"image/png"
	"testing"

	"golang.org/x/image/bmp"
)

func TestNaturalSort(t *testing.T) {
	names := []string{"page10.jpg", "page2.jpg", "Page1.jpg", "page20.jpg", "page3.png"}
	NaturalSort(names)
	want := []string{"Page1.jpg", "page2.jpg", "page3.png", "page10.jpg", "page20.jpg"}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("自然排序错误: %v，期望 %v", names, want)
		}
	}
}

func TestNaturalLess(t *testing.T) {
	cases := [][2]string{
		{"a2", "a10"},
		{"2.jpg", "10.jpg"},
		{"vol1_ch2", "vol1_ch10"},
		{"abc", "abd"},
	}
	for _, c := range cases {
		if !NaturalLess(c[0], c[1]) {
			t.Errorf("NaturalLess(%q, %q) 应为 true", c[0], c[1])
		}
		if NaturalLess(c[1], c[0]) {
			t.Errorf("NaturalLess(%q, %q) 应为 false", c[1], c[0])
		}
	}
}

// buildTestZIP 构造测试 ZIP
func buildTestZIP(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, data := range entries {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func fakeJPEG() []byte { return []byte{0xFF, 0xD8, 0xFF, 0xD9} }

// encodeImage 用指定编码器生成 13x7 测试图片
func encodeImage(t *testing.T, encode func(*bytes.Buffer, image.Image) error) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 13, 7))
	var buf bytes.Buffer
	if err := encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// buildWebPLossless 手工构造最小 VP8L（无损 webp）头部：
// RIFF/WEBP 容器 + VP8L 块，0x2F 签名后按位打包 宽高-1（各 14 位）。
func buildWebPLossless(width, height uint32) []byte {
	var bits uint32 = (width - 1) | ((height - 1) << 14)
	vp8l := []byte{0x2F, byte(bits), byte(bits >> 8), byte(bits >> 16), byte(bits >> 24)}
	chunk := make([]byte, 8+len(vp8l))
	copy(chunk[0:4], "VP8L")
	binary.LittleEndian.PutUint32(chunk[4:8], uint32(len(vp8l)))
	copy(chunk[8:], vp8l)
	riff := make([]byte, 12+len(chunk))
	copy(riff[0:4], "RIFF")
	binary.LittleEndian.PutUint32(riff[4:8], uint32(4+len(chunk)))
	copy(riff[8:12], "WEBP")
	copy(riff[12:], chunk)
	return riff
}

// buildAVIF 手工构造最小 AVIF 容器（ftyp + meta/iprp/ipco/ispe）
func buildAVIF(width, height uint32) []byte {
	box := func(typ string, payload []byte) []byte {
		b := make([]byte, 8+len(payload))
		binary.BigEndian.PutUint32(b[0:4], uint32(len(b)))
		copy(b[4:8], typ)
		copy(b[8:], payload)
		return b
	}
	ispePayload := make([]byte, 12) // FullBox 版本/标志 4 字节 + 宽高
	binary.BigEndian.PutUint32(ispePayload[4:8], width)
	binary.BigEndian.PutUint32(ispePayload[8:12], height)
	ipco := box("ipco", box("ispe", ispePayload))
	iprp := box("iprp", ipco)
	meta := box("meta", append(make([]byte, 4), iprp...)) // FullBox 版本/标志
	ftyp := box("ftyp", append([]byte("avif"), make([]byte, 8)...))
	return append(ftyp, meta...)
}

func TestImageSize_Formats(t *testing.T) {
	cases := map[string][]byte{
		"jpeg": encodeImage(t, func(b *bytes.Buffer, i image.Image) error {
			return jpeg.Encode(b, i, nil)
		}),
		"png": encodeImage(t, func(b *bytes.Buffer, i image.Image) error {
			return png.Encode(b, i)
		}),
		"webp": buildWebPLossless(13, 7),
		"bmp": encodeImage(t, func(b *bytes.Buffer, i image.Image) error {
			return bmp.Encode(b, i)
		}),
		"avif": buildAVIF(13, 7),
	}
	for format, data := range cases {
		w, h := ImageSize(bytes.NewReader(data))
		if w != 13 || h != 7 {
			t.Errorf("%s: ImageSize = %dx%d，期望 13x7", format, w, h)
		}
	}
	// 非图片数据返回 0,0
	if w, h := ImageSize(bytes.NewReader([]byte("not an image"))); w != 0 || h != 0 {
		t.Errorf("非图片: ImageSize = %dx%d，期望 0x0", w, h)
	}
}

func TestZIPImagePages(t *testing.T) {
	data := buildTestZIP(t, map[string][]byte{
		"p10.jpg": fakeJPEG(),
		"p2.jpg":  fakeJPEG(),
		"p1.jpg":  fakeJPEG(),
		"note.txt": []byte("hi"),
	})
	pages, err := ZIPImagePages(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(pages) != 3 {
		t.Fatalf("页数 = %d，期望 3", len(pages))
	}
	if pages[0].Name != "p1.jpg" || pages[1].Name != "p2.jpg" || pages[2].Name != "p10.jpg" {
		t.Errorf("页序错误: %+v", pages)
	}
}

func TestSniffZIPComic(t *testing.T) {
	// 3 图 1 文本 → 占比 75%，不是漫画
	notComic := buildTestZIP(t, map[string][]byte{
		"a.jpg": fakeJPEG(), "b.jpg": fakeJPEG(), "c.jpg": fakeJPEG(), "doc.txt": []byte("x"),
	})
	is, err := SniffZIPComic(bytes.NewReader(notComic), int64(len(notComic)))
	if err != nil || is {
		t.Errorf("75%% 图片占比不应判为漫画: is=%v err=%v", is, err)
	}

	// 9 图 1 文本 → 90%，是漫画
	entries := map[string][]byte{"doc.txt": []byte("x")}
	for _, n := range []string{"1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg", "7.jpg", "8.jpg", "9.jpg"} {
		entries[n] = fakeJPEG()
	}
	comic := buildTestZIP(t, entries)
	is, err = SniffZIPComic(bytes.NewReader(comic), int64(len(comic)))
	if err != nil || !is {
		t.Errorf("90%% 图片占比应判为漫画: is=%v err=%v", is, err)
	}
}

func TestListZIP_And_OpenEntry(t *testing.T) {
	data := buildTestZIP(t, map[string][]byte{
		"dir/b.txt": []byte("world"),
		"a.txt":     []byte("hello"),
	})
	entries, err := ListZIP(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("条目数 = %d，期望 2", len(entries))
	}

	rc, err := OpenZIPEntry(bytes.NewReader(data), int64(len(data)), "dir/b.txt")
	if err != nil {
		t.Fatal(err)
	}
	content := make([]byte, 5)
	_, _ = rc.Read(content)
	_ = rc.Close()
	if string(content) != "world" {
		t.Errorf("条目内容 = %q", content)
	}

	if _, err := OpenZIPEntry(bytes.NewReader(data), int64(len(data)), "ghost.txt"); err != ErrEntryNotFound {
		t.Errorf("不存在条目应返回 ErrEntryNotFound，得到: %v", err)
	}
}
