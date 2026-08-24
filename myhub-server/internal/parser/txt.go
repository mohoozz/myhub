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
	"golang.org/x/text/encoding/unicode"
	"golang.org/x/text/transform"
)

// 编码名常量
const (
	EncodingUTF8    = "utf-8"
	EncodingGBK     = "gbk"
	EncodingBig5    = "big5"
	EncodingUTF16LE = "utf-16le"
	EncodingUTF16BE = "utf-16be"
)

// UTF-16 BOM
var (
	bomUTF16LE = []byte{0xFF, 0xFE}
	bomUTF16BE = []byte{0xFE, 0xFF}
)

// IsUTF16 判断编码名是否为 UTF-16 系列
func IsUTF16(name string) bool {
	return name == EncodingUTF16LE || name == EncodingUTF16BE
}

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

// DetectEncoding 检测文本编码：优先按 BOM 判定 UTF-8 / UTF-16 LE / UTF-16 BE；
// 无 BOM 时按 NUL 奇偶分布识别 UTF-16；UTF-8 合法直接判定；
// 否则比较 GBK/Big5 解码乱码数。
func DetectEncoding(sample []byte) string {
	if bytes.HasPrefix(sample, []byte{0xEF, 0xBB, 0xBF}) {
		return EncodingUTF8
	}
	if bytes.HasPrefix(sample, bomUTF16LE) {
		return EncodingUTF16LE
	}
	if bytes.HasPrefix(sample, bomUTF16BE) {
		return EncodingUTF16BE
	}
	// 无 BOM 的 UTF-16（部分导出工具产物）：ASCII 字符的 UTF-16 码元
	// 高字节为 0x00，全部落在同一奇偶位；需置于 utf8.Valid 之前，
	// 因为纯 ASCII 的 UTF-16 字节序列本身是合法 UTF-8（含 NUL）。
	if enc := detectUTF16NoBOM(sample); enc != "" {
		return enc
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

// detectUTF16NoBOM 无 BOM UTF-16 启发式判定：要求 NUL 字节占样本 20% 以上
// 且全部集中于单一奇偶位（另一奇偶位无 NUL），避免误判含 NUL 的二进制。
// NUL 在奇数位为 UTF-16LE（低位在前），偶数位为 UTF-16BE。
func detectUTF16NoBOM(sample []byte) string {
	if len(sample) < 8 {
		return ""
	}
	var evenNul, oddNul int
	for i, b := range sample {
		if b == 0 {
			if i%2 == 0 {
				evenNul++
			} else {
				oddNul++
			}
		}
	}
	if oddNul*10 >= len(sample)*2 && evenNul == 0 {
		return EncodingUTF16LE
	}
	if evenNul*10 >= len(sample)*2 && oddNul == 0 {
		return EncodingUTF16BE
	}
	return ""
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

// DecoderFor 返回指定编码的解码器；utf-8 返回 nil（无需转换）。
// UTF-16 使用 UseBOM：段首出现 BOM（如卷首/全文从文件偏移 0 读取）时
// 自动消费并按 BOM 指定字节序解码，否则按既定字节序。
func DecoderFor(name string) encoding.Encoding {
	switch name {
	case EncodingGBK:
		return simplifiedchinese.GBK
	case EncodingBig5:
		return traditionalchinese.Big5
	case EncodingUTF16LE:
		return unicode.UTF16(unicode.LittleEndian, unicode.UseBOM)
	case EncodingUTF16BE:
		return unicode.UTF16(unicode.BigEndian, unicode.UseBOM)
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
// 按行扫描（GBK/Big5/UTF-8 的多字节字符均不含 0x0A，按 \n 切分安全；
// UTF-16 按码元边界切分，见 buildUTF16Index），
// 记录每个章节标题行的原始字节偏移。
// 未识别到任何章节时返回单章节"全文"。
func BuildTXTIndex(r io.Reader, encName string, fileSize int64) []Chapter {
	if IsUTF16(encName) {
		return buildUTF16Index(r, encName, fileSize)
	}

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

	return finalizeChapters(chapters, fileSize)
}

// buildUTF16Index 构建 UTF-16 编码 TXT 的章节索引。
//
// 与单/双字节编码不同，UTF-16 的换行符是两字节码元（LE: 0A 00 / BE: 00 0A），
// 直接按 0x0A 字节切分会把码元从中间劈开导致解码错位。这里以 2 字节码元
// 为最小单位流式扫描，仅在完整换行码元处切行，保证每行均可独立解码，
// 且记录的章节起始字节偏移始终码元对齐（供内容区间读取精确回读）。
func buildUTF16Index(r io.Reader, encName string, fileSize int64) []Chapter {
	le := encName == EncodingUTF16LE
	br := bufio.NewReaderSize(r, 64*1024)

	var chapters []Chapter
	var lineStart int64 // 当前行起始绝对字节偏移
	var line []byte

	// 不手动跳过 BOM：若文件头带 BOM（FF FE / FE FF），它随第一行一起
	// 解码，由 UseBOM 解码器自动消费。这样首行即章节标题时 Start=0，
	// 与 UTF-8/GBK 行为一致（不会产生仅含 BOM 的空"卷首"章节）。
	flush := func(raw []byte, start int64) {
		title := trimLine(DecodeString(encName, raw))
		if isChapterTitle(title) {
			chapters = append(chapters, Chapter{Title: title, Start: start})
		}
	}

	pos := int64(0)
	buf := make([]byte, 64*1024)
	var carry byte // 跨块被切开的码元首字节
	hasCarry := false
	for {
		n, err := br.Read(buf)
		chunk := buf[:n]
		data := chunk
		dataStart := pos // data[0] 的绝对字节偏移
		if hasCarry {
			// 拼接上一块残留的单字节，保持码元对齐
			data = make([]byte, 1+n)
			data[0] = carry
			copy(data[1:], chunk)
			hasCarry = false
			dataStart = pos - 1
		}
		pos += int64(n)

		// 仅处理完整码元；末尾单字节留待下一块拼接
		processLen := len(data) &^ 1
		for i := 0; i < processLen; i += 2 {
			isNL := (le && data[i] == 0x0A && data[i+1] == 0x00) ||
				(!le && data[i] == 0x00 && data[i+1] == 0x0A)
			line = append(line, data[i], data[i+1])
			if isNL {
				flush(line, lineStart)
				line = line[:0]
				lineStart = dataStart + int64(i) + 2
			}
		}
		if processLen < len(data) {
			carry = data[processLen]
			hasCarry = true
		}
		if err != nil {
			break // io.EOF 或读错误均结束
		}
	}
	if len(line) > 0 {
		flush(line, lineStart)
	}
	return finalizeChapters(chapters, fileSize)
}

// finalizeChapters 章节收尾：无章节时返回单章节"全文"；
// 首章节之前的内容作为"卷首"；补齐各章节结束偏移。
func finalizeChapters(chapters []Chapter, fileSize int64) []Chapter {
	if len(chapters) == 0 {
		return []Chapter{{Title: "全文", Start: 0, End: fileSize}}
	}
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
