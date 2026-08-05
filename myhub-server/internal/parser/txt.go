// Package parser 内容解析层：TXT 章节索引/编码检测、EPUB 解包等。
package parser

import (
	"bufio"
	"bytes"
	"io"
	"regexp"
	"unicode/utf8"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/traditionalchinese"
	"golang.org/x/text/transform"
)

// 编码名常量
const (
	EncodingUTF8 = "utf-8"
	EncodingGBK  = "gbk"
	EncodingBig5 = "big5"
)

// Chapter 章节（字节区间基于原始文件字节，与编码无关）
type Chapter struct {
	Title string `json:"title"`
	Start int64  `json:"start"` // 起始字节偏移（含）
	End   int64  `json:"end"`   // 结束字节偏移（不含）
}

// 章节标题正则（在解码后的文本行上匹配）
var chapterPatterns = []*regexp.Regexp{
	// 第x章/回/节/卷/部/集/篇（中文或阿拉伯数字）
	regexp.MustCompile(`^\s*第[0-9０-９零一二三四五六七八九十百千万两]+[章回节卷部集篇].{0,50}$`),
	// Chapter 1 / Chap 2 / Section 3 / Part IV
	regexp.MustCompile(`(?i)^\s*(chapter|chap|section|part)\s+[0-9ivxlcdm]+.{0,50}$`),
	// 序章/楔子/前言/尾声/番外 等
	regexp.MustCompile(`^\s*(序章|楔子|前言|引子|尾声|后记|番外篇?).{0,30}$`),
}

// maxTitleRunes 标题行最大字符数，避免正文误判
const maxTitleRunes = 60

// DetectEncoding 检测文本编码：UTF-8 合法直接判定；否则比较 GBK/Big5 解码乱码数
func DetectEncoding(sample []byte) string {
	if bytes.HasPrefix(sample, []byte{0xEF, 0xBB, 0xBF}) {
		return EncodingUTF8
	}
	if utf8.Valid(sample) {
		return EncodingUTF8
	}
	gbkBad := countBadChars(simplifiedchinese.GBK, sample)
	big5Bad := countBadChars(traditionalchinese.Big5, sample)
	if gbkBad <= big5Bad {
		return EncodingGBK
	}
	return EncodingBig5
}

// countBadChars 用指定编码解码，统计替换符（U+FFFD）数量
func countBadChars(enc encoding.Encoding, sample []byte) int {
	decoded, err := enc.NewDecoder().Bytes(sample)
	if err != nil {
		// 解码出错的部分按较多乱码处理
		return utf8.RuneCount(sample) + 1
	}
	return bytes.Count(decoded, []byte("�"))
}

// DecoderFor 返回指定编码的解码器；utf-8 返回 nil（无需转换）
func DecoderFor(name string) encoding.Encoding {
	switch name {
	case EncodingGBK:
		return simplifiedchinese.GBK
	case EncodingBig5:
		return traditionalchinese.Big5
	default:
		return nil
	}
}

// DecodeString 将原始字节按编码解码为 UTF-8 字符串
func DecodeString(name string, raw []byte) string {
	enc := DecoderFor(name)
	if enc == nil {
		return string(bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF}))
	}
	decoded, err := enc.NewDecoder().Bytes(raw)
	if err != nil {
		// 容错：用 transform 尽量解码
		decoded, _, _ = transform.Bytes(enc.NewDecoder(), raw)
	}
	return string(decoded)
}

// isChapterTitle 判断解码后的文本行是否为章节标题
func isChapterTitle(line string) bool {
	line = trimLine(line)
	if line == "" || utf8.RuneCountInString(line) > maxTitleRunes {
		return false
	}
	for _, p := range chapterPatterns {
		if p.MatchString(line) {
			return true
		}
	}
	return false
}

func trimLine(s string) string {
	return string(bytes.TrimSpace([]byte(s)))
}

// BuildTXTIndex 流式构建 TXT 章节索引。
// r 为原始字节流，encName 为 DetectEncoding 的结果，fileSize 为文件总字节数。
// 按行扫描（GBK/Big5/UTF-8 的多字节字符均不含 0x0A，按 \n 切分安全），
// 记录每个章节标题行的原始字节偏移。
// 未识别到任何章节时返回单章节"全文"。
func BuildTXTIndex(r io.Reader, encName string, fileSize int64) []Chapter {
	br := bufio.NewReaderSize(r, 64*1024)
	var chapters []Chapter
	var offset int64

	for {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			text := DecodeString(encName, line)
			if isChapterTitle(text) {
				chapters = append(chapters, Chapter{
					Title: trimLine(text),
					Start: offset,
				})
			}
			offset += int64(len(line))
		}
		if err != nil {
			break // io.EOF 或读错误均结束
		}
	}

	if len(chapters) == 0 {
		return []Chapter{{Title: "全文", Start: 0, End: fileSize}}
	}

	// 首章节之前的内容（封面/简介等）作为"卷首"章节
	if chapters[0].Start > 0 {
		chapters = append([]Chapter{{Title: "卷首", Start: 0}}, chapters...)
	}
	for i := range chapters {
		if i+1 < len(chapters) {
			chapters[i].End = chapters[i+1].Start
		} else {
			chapters[i].End = fileSize
		}
	}
	return chapters
}
