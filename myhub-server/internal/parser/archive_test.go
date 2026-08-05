package parser

import (
	"archive/zip"
	"bytes"
	"testing"
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
