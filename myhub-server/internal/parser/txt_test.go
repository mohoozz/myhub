package parser

import (
	"bytes"
	"strings"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
)

func TestDetectEncoding(t *testing.T) {
	if got := DetectEncoding([]byte("hello world 你好")); got != EncodingUTF8 {
		t.Errorf("UTF-8 文本检测为 %s", got)
	}
	if got := DetectEncoding([]byte{0xEF, 0xBB, 0xBF, 'a'}); got != EncodingUTF8 {
		t.Errorf("BOM 检测为 %s", got)
	}
	gbkBytes, _ := simplifiedchinese.GBK.NewEncoder().Bytes([]byte("这是一段中文文本，用于编码检测。第一章 开始"))
	if got := DetectEncoding(gbkBytes); got != EncodingGBK {
		t.Errorf("GBK 文本检测为 %s", got)
	}
}

func TestDetectEncoding_UTF16(t *testing.T) {
	leBytes, _ := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).
		NewEncoder().Bytes([]byte("你好，第一章 开始"))
	if got := DetectEncoding(leBytes); got != EncodingUTF16LE {
		t.Errorf("UTF-16LE（BOM）检测为 %s", got)
	}
	beBytes, _ := unicode.UTF16(unicode.BigEndian, unicode.UseBOM).
		NewEncoder().Bytes([]byte("你好，第一章 开始"))
	if got := DetectEncoding(beBytes); got != EncodingUTF16BE {
		t.Errorf("UTF-16BE（BOM）检测为 %s", got)
	}
	// 无 BOM 的 UTF-16LE（ASCII 为主，NUL 集中在奇数位）
	noBom := []byte{'h', 0, 'i', 0, ' ', 0, 't', 0, 'h', 0, 'e', 0, 'r', 0, 'e', 0}
	if got := DetectEncoding(noBom); got != EncodingUTF16LE {
		t.Errorf("无 BOM UTF-16LE 检测为 %s", got)
	}
	// 普通 UTF-8 含少量 NUL 不应被误判为 UTF-16
	if got := DetectEncoding([]byte("ab\x00cd\x00efgh")); got != EncodingUTF8 {
		t.Errorf("含少量 NUL 的 UTF-8 检测为 %s", got)
	}
}

func TestDecodeString_UTF16(t *testing.T) {
	src := "卷首内容。\n第一章 启程\n正文。"
	leBytes, _ := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).
		NewEncoder().Bytes([]byte(src))
	got := DecodeString(EncodingUTF16LE, leBytes)
	// 段首 BOM 应被消费，且解码后无替换符
	if got != src {
		t.Errorf("UTF-16LE 解码结果不符: %q", got)
	}
	if strings.Contains(got, "\uFFFD") || strings.Contains(got, "\uFEFF") {
		t.Errorf("UTF-16LE 解码残留 BOM/替换符: %q", got)
	}
}

func TestBuildTXTIndex_UTF16(t *testing.T) {
	content := "简介内容\n第一章 开始\n正文一\n第二章 继续\n正文二\n"
	leBytes, _ := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).
		NewEncoder().Bytes([]byte(content))

	chapters := BuildTXTIndex(bytes.NewReader(leBytes), EncodingUTF16LE, int64(len(leBytes)))
	if len(chapters) != 3 { // 卷首 + 2 章
		t.Fatalf("章节数 = %d，期望 3: %+v", len(chapters), chapters)
	}
	if chapters[0].Title != "卷首" || chapters[1].Title != "第一章 开始" || chapters[2].Title != "第二章 继续" {
		t.Errorf("UTF-16 章节标题不符: %+v", chapters)
	}
	// 字节区间回读验证：各章节内容可独立解码且包含标题
	for i, ch := range chapters {
		text := DecodeString(EncodingUTF16LE, leBytes[ch.Start:ch.End])
		if i > 0 && !strings.Contains(text, ch.Title) {
			t.Errorf("区间 %q 不含标题 %q", text, ch.Title)
		}
		if strings.Contains(text, "\uFFFD") {
			t.Errorf("章节 %d 解码出现替换符: %q", i, text)
		}
	}
	if chapters[2].End != int64(len(leBytes)) {
		t.Errorf("末章 End = %d，期望 %d", chapters[2].End, len(leBytes))
	}
}

func TestBuildTXTIndex_UTF16BE(t *testing.T) {
	content := "第一章 启程\n正文一\n第二章 归途\n正文二\n"
	beBytes, _ := unicode.UTF16(unicode.BigEndian, unicode.UseBOM).
		NewEncoder().Bytes([]byte(content))

	chapters := BuildTXTIndex(bytes.NewReader(beBytes), EncodingUTF16BE, int64(len(beBytes)))
	if len(chapters) != 2 { // 首行即标题（BOM 随行解码），无卷首
		t.Fatalf("章节数 = %d，期望 2: %+v", len(chapters), chapters)
	}
	if chapters[0].Title != "第一章 启程" || chapters[1].Title != "第二章 归途" {
		t.Errorf("UTF-16BE 章节标题解码错误: %+v", chapters)
	}
	// 字节区间回读验证（BE 内容解码正确）
	for _, ch := range chapters {
		text := DecodeString(EncodingUTF16BE, beBytes[ch.Start:ch.End])
		if !strings.Contains(text, ch.Title) {
			t.Errorf("区间 %q 不含标题 %q", text, ch.Title)
		}
	}
}

func TestBuildTXTIndex_UTF16NoChapters(t *testing.T) {
	content := "没有章节标记的文本。\n第二行。\n"
	leBytes, _ := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).
		NewEncoder().Bytes([]byte(content))

	chapters := BuildTXTIndex(bytes.NewReader(leBytes), EncodingUTF16LE, int64(len(leBytes)))
	if len(chapters) != 1 || chapters[0].Title != "全文" {
		t.Fatalf("无章节时应返回单章节全文: %+v", chapters)
	}
	if chapters[0].Start != 0 || chapters[0].End != int64(len(leBytes)) {
		t.Errorf("全文区间错误: %+v", chapters[0])
	}
	// 全文内容（含 BOM 前缀）应完整解码
	if got := DecodeString(EncodingUTF16LE, leBytes); got != content {
		t.Errorf("全文解码不符: %q", got)
	}
}

func TestBuildTXTIndex_UTF8(t *testing.T) {
	content := "简介内容\n第一章 开始\n正文一\n第二章 继续\n正文二\n第三章 结束\n正文三\n"
	chapters := BuildTXTIndex(strings.NewReader(content), EncodingUTF8, int64(len(content)))

	if len(chapters) != 4 { // 卷首 + 3 章
		t.Fatalf("章节数 = %d，期望 4: %+v", len(chapters), chapters)
	}
	if chapters[0].Title != "卷首" || chapters[1].Title != "第一章 开始" {
		t.Errorf("章节标题不符: %+v", chapters[:2])
	}
	// 验证字节区间内容正确
	raw := []byte(content)
	for i, ch := range chapters {
		text := string(raw[ch.Start:ch.End])
		if !strings.Contains(text, ch.Title) && i > 0 {
			t.Errorf("章节 %d 区间内容不含标题: %q", i, text)
		}
	}
	if chapters[3].End != int64(len(content)) {
		t.Errorf("末章 End = %d，期望 %d", chapters[3].End, len(content))
	}
}

func TestBuildTXTIndex_GBK(t *testing.T) {
	utf8Content := "第一章 启程\n正文一\n第二章 归途\n正文二\n"
	gbkBytes, err := simplifiedchinese.GBK.NewEncoder().Bytes([]byte(utf8Content))
	if err != nil {
		t.Fatal(err)
	}
	chapters := BuildTXTIndex(bytes.NewReader(gbkBytes), EncodingGBK, int64(len(gbkBytes)))

	if len(chapters) != 2 {
		t.Fatalf("章节数 = %d，期望 2: %+v", len(chapters), chapters)
	}
	if chapters[0].Title != "第一章 启程" || chapters[1].Title != "第二章 归途" {
		t.Errorf("GBK 章节标题解码错误: %+v", chapters)
	}
	// 字节区间回读验证
	for _, ch := range chapters {
		text := DecodeString(EncodingGBK, gbkBytes[ch.Start:ch.End])
		if !strings.Contains(text, ch.Title) {
			t.Errorf("区间 %q 不含标题 %q", text, ch.Title)
		}
	}
}

func TestBuildTXTIndex_EnglishChapters(t *testing.T) {
	content := "Chapter 1\nbody one\nChapter 2: The Return\nbody two\n"
	chapters := BuildTXTIndex(strings.NewReader(content), EncodingUTF8, int64(len(content)))
	if len(chapters) != 2 {
		t.Fatalf("章节数 = %d，期望 2: %+v", len(chapters), chapters)
	}
}

func TestBuildTXTIndex_NoChapters(t *testing.T) {
	content := "没有章节标记的文本。\n第二行。\n"
	chapters := BuildTXTIndex(strings.NewReader(content), EncodingUTF8, int64(len(content)))
	if len(chapters) != 1 || chapters[0].Title != "全文" {
		t.Fatalf("无章节时应返回单章节全文: %+v", chapters)
	}
	if chapters[0].Start != 0 || chapters[0].End != int64(len(content)) {
		t.Errorf("全文区间错误: %+v", chapters[0])
	}
}

func TestBuildTXTIndex_BodyTextNotMatched(t *testing.T) {
	// 正文中提到"第三章"但超长（>60字符）不应误判
	longLine := "他说第三章的内容很精彩，" + strings.Repeat("确实如此，", 20)
	content := longLine + "\n第一章 真正的章节\n正文\n"
	chapters := BuildTXTIndex(strings.NewReader(content), EncodingUTF8, int64(len(content)))
	if len(chapters) != 2 || chapters[1].Title != "第一章 真正的章节" {
		t.Fatalf("长正文行不应被识别为章节: %+v", chapters)
	}
}
