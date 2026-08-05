package parser

import (
	"archive/zip"
	"bytes"
	"strings"
	"testing"
)

// buildTestEPUB 构造最小可用 EPUB（novel 型，EPUB3 nav 目录）
func buildTestEPUB(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	files := map[string]string{
		"mimetype": "application/epub+zip",
		"META-INF/container.xml": `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>`,
		"OEBPS/content.opf": `<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试之书</dc:title>
    <dc:creator>作者甲</dc:creator>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>`,
		"OEBPS/nav.xhtml": `<html xmlns="http://www.w3.org/1999/xhtml"><body>
<nav epub:type="toc"><ol>
<li><a href="ch1.xhtml">第一章</a></li>
<li><a href="ch2.xhtml">第二章</a></li>
</ol></nav></body></html>`,
		"OEBPS/ch1.xhtml": `<html><body><p>第一章正文</p></body></html>`,
		"OEBPS/ch2.xhtml": `<html><body><p>第二章正文</p><img src="cover.jpg"/></body></html>`,
	}
	for name, content := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	// 封面图片（伪 JPEG 字节）
	w, err := zw.Create("OEBPS/cover.jpg")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte{0xFF, 0xD8, 0xFF, 0xD9}); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestOpenEPUB_Meta(t *testing.T) {
	data := buildTestEPUB(t)
	e, err := OpenEPUB(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatalf("OpenEPUB 失败: %v", err)
	}
	if e.Title != "测试之书" || e.Author != "作者甲" {
		t.Errorf("元数据错误: title=%q author=%q", e.Title, e.Author)
	}
	if e.Cover != "OEBPS/cover.jpg" {
		t.Errorf("封面路径错误: %q", e.Cover)
	}
	if e.CoverItemID() != "cover" {
		t.Errorf("封面 ID 错误: %q", e.CoverItemID())
	}
	if e.IsComic {
		t.Error("文字型 EPUB 不应判为图集型")
	}
}

func TestOpenEPUB_TOC(t *testing.T) {
	data := buildTestEPUB(t)
	e, err := OpenEPUB(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(e.TOC) != 2 {
		t.Fatalf("目录项 = %d，期望 2: %+v", len(e.TOC), e.TOC)
	}
	if e.TOC[0].Title != "第一章" || e.TOC[0].Href != "OEBPS/ch1.xhtml" {
		t.Errorf("目录项 0 错误: %+v", e.TOC[0])
	}
}

func TestOpenEPUB_ReadItem(t *testing.T) {
	data := buildTestEPUB(t)
	e, err := OpenEPUB(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}

	htmlData, mt, err := e.ReadItem("c1")
	if err != nil {
		t.Fatal(err)
	}
	if mt != "application/xhtml+xml" {
		t.Errorf("media type = %q", mt)
	}
	if !strings.Contains(string(htmlData), "第一章正文") {
		t.Errorf("章节内容错误: %q", htmlData)
	}

	imgData, mt, err := e.ReadItem("cover")
	if err != nil {
		t.Fatal(err)
	}
	if mt != "image/jpeg" || len(imgData) != 4 {
		t.Errorf("封面资源错误: mt=%q len=%d", mt, len(imgData))
	}

	if _, _, err := e.ReadItem("nonexist"); err != ErrItemNotFound {
		t.Errorf("不存在条目应返回 ErrItemNotFound，得到: %v", err)
	}
}

func TestOpenEPUB_ComicDetection(t *testing.T) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	files := map[string]string{
		"META-INF/container.xml": `<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf"/></rootfiles>
</container>`,
		"content.opf": `<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="p1" href="1.jpg" media-type="image/jpeg"/>
    <item id="p2" href="2.jpg" media-type="image/jpeg"/>
    <item id="p3" href="3.jpg" media-type="image/jpeg"/>
    <item id="p4" href="4.jpg" media-type="image/jpeg"/>
    <item id="p5" href="5.jpg" media-type="image/jpeg"/>
    <item id="p6" href="6.jpg" media-type="image/jpeg"/>
    <item id="p7" href="7.jpg" media-type="image/jpeg"/>
    <item id="p8" href="8.jpg" media-type="image/jpeg"/>
    <item id="p9" href="9.jpg" media-type="image/jpeg"/>
    <item id="idx" href="index.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="idx"/></spine>
</package>`,
	}
	for name, content := range files {
		w, _ := zw.Create(name)
		_, _ = w.Write([]byte(content))
	}
	_ = zw.Close()

	e, err := OpenEPUB(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	if !e.IsComic {
		t.Error("图片占比 90% 应判为图集型")
	}
}

func TestOpenEPUB_Invalid(t *testing.T) {
	if _, err := OpenEPUB(bytes.NewReader([]byte("not a zip")), 9); err != ErrNotEPUB {
		t.Errorf("非 zip 应返回 ErrNotEPUB，得到: %v", err)
	}
}
