package parser

import (
	"bytes"
	"strings"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
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
