package parser

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"mime"
	"path"
	"strings"

	"golang.org/x/net/html"
)

// EPUB 相关错误
var (
	ErrNotEPUB      = errors.New("不是有效的 EPUB 文件")
	ErrItemNotFound = errors.New("EPUB 条目不存在")
	ErrNoTOC        = errors.New("EPUB 缺少目录")
)

// ManifestItem OPF manifest 条目
type ManifestItem struct {
	ID         string `json:"id"`
	Href       string `json:"href"` // 已解析为 zip 内完整路径
	MediaType  string `json:"media_type"`
	Properties string `json:"properties"`
}

// TOCItem 目录项
type TOCItem struct {
	Title string `json:"title"`
	Href  string `json:"href"` // zip 内完整路径
}

// EPUB 解包结果
type EPUB struct {
	zr       *zip.Reader
	Title    string
	Author   string
	Cover    string // 封面在 zip 内的完整路径（可能为空）
	Manifest map[string]ManifestItem
	Spine    []string // idref 阅读顺序
	TOC      []TOCItem
	IsComic  bool // 图集型（漫画）判定：图片占比 ≥ 90%，或一页一图型（页面以图为主）
}

// OPF XML 结构
type opfPackage struct {
	Metadata struct {
		Title   []string `xml:"title"`   // 匹配 dc:title（按本地名）
		Creator []string `xml:"creator"` // 匹配 dc:creator
		Meta    []struct {
			Name    string `xml:"name,attr"`
			Content string `xml:"content,attr"`
		} `xml:"meta"`
	} `xml:"metadata"`
	Manifest struct {
		Items []struct {
			ID         string `xml:"id,attr"`
			Href       string `xml:"href,attr"`
			MediaType  string `xml:"media-type,attr"`
			Properties string `xml:"properties,attr"`
		} `xml:"item"`
	} `xml:"manifest"`
	Spine struct {
		TOC      string `xml:"toc,attr"`
		ItemRefs []struct {
			IDRef string `xml:"idref,attr"`
		} `xml:"itemref"`
	} `xml:"spine"`
}

type containerXML struct {
	Rootfiles struct {
		Rootfile struct {
			FullPath string `xml:"full-path,attr"`
		} `xml:"rootfile"`
	} `xml:"rootfiles"`
}

// OpenEPUB 解包 EPUB（ZIP）文件，解析 OPF 元数据与目录
func OpenEPUB(ra io.ReaderAt, size int64) (*EPUB, error) {
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return nil, ErrNotEPUB
	}
	e := &EPUB{zr: zr, Manifest: make(map[string]ManifestItem)}

	files := make(map[string]*zip.File, len(zr.File))
	for _, f := range zr.File {
		files[f.Name] = f
	}

	// container.xml → OPF 路径
	opfPath, err := readOPFPath(files)
	if err != nil {
		return nil, err
	}
	opfDir := path.Dir(opfPath)

	// 解析 OPF
	var pkg opfPackage
	if err := readXML(files, opfPath, &pkg); err != nil {
		return nil, err
	}

	if len(pkg.Metadata.Title) > 0 {
		e.Title = pkg.Metadata.Title[0]
	}
	if len(pkg.Metadata.Creator) > 0 {
		e.Author = pkg.Metadata.Creator[0]
	}

	coverID := ""
	for _, m := range pkg.Metadata.Meta {
		if m.Name == "cover" {
			coverID = m.Content
		}
	}
	for _, it := range pkg.Manifest.Items {
		full := resolveHref(opfDir, it.Href)
		e.Manifest[it.ID] = ManifestItem{ID: it.ID, Href: full, MediaType: it.MediaType, Properties: it.Properties}
		// EPUB3 封面：properties="cover-image"；EPUB2：meta cover 指向条目 ID
		if strings.Contains(it.Properties, "cover-image") {
			e.Cover = full
		}
		if coverID != "" && it.ID == coverID {
			e.Cover = full
		}
	}
	for _, ref := range pkg.Spine.ItemRefs {
		e.Spine = append(e.Spine, ref.IDRef)
	}

	// 目录：优先 EPUB3 nav，其次 NCX
	e.TOC = e.parseTOC(files, opfDir, pkg.Spine.TOC)

	e.detectComic(files)

	return e, nil
}

// detectComic 图集型（漫画）判定，满足任一条件即为漫画：
//  1. manifest 中图片条目占比 ≥ 90%，或纯图册（无 XHTML 文档条目）
//  2. "一页一图"型：spine 页面绝大多数内嵌图片且几乎没有文字
//     （如 Kindle Comic Converter 生成的日漫 EPUB：每个 XHTML 恰好一张图）
//
// 仅当图片条目数接近文档数时（疑似漫画）才做内容级扫描，避免
// 每次打开小说都逐个解析章节页面。
func (e *EPUB) detectComic(files map[string]*zip.File) {
	images, docs := 0, 0
	for _, it := range e.Manifest {
		if strings.HasPrefix(it.MediaType, "image/") {
			images++
		} else if it.MediaType == "application/xhtml+xml" || it.MediaType == "text/html" {
			docs++
		}
	}
	if images > 0 && docs > 0 && float64(images)/float64(images+docs) >= 0.9 ||
		images > 0 && docs == 0 {
		e.IsComic = true
		return
	}
	// 图片占比不足以判定：仅当图片量接近页数时才值得扫描页面内容
	if docs == 0 || images < int(float64(docs)*0.3) {
		return
	}
	pages, pagesWithImg, textChars := 0, 0, 0
	for i, idref := range e.Spine {
		if i >= 1000 { // 防御：漫画页数上限
			break
		}
		it, ok := e.Manifest[idref]
		if !ok || (it.MediaType != "application/xhtml+xml" && it.MediaType != "text/html") {
			continue
		}
		pages++
		data, err := e.readItemLimit(it.Href, 256<<10)
		if err != nil {
			continue
		}
		imgs, chars := analyzeXHTML(data)
		if imgs > 0 {
			pagesWithImg++
		}
		textChars += chars
	}
	// 绝大多数页面含图且平均每页可见文字 < 300 字符 → 页面主体为图
	if pages > 0 && float64(pagesWithImg)/float64(pages) >= 0.8 && textChars < pages*300 {
		e.IsComic = true
	}
}

// readItemLimit 读取 zip 内文件内容，限制最大读取量（用于漫画判定扫描）
func (e *EPUB) readItemLimit(href string, limit int64) ([]byte, error) {
	for _, f := range e.zr.File {
		if f.Name == href {
			rc, err := f.Open()
			if err != nil {
				return nil, err
			}
			defer rc.Close()
			return io.ReadAll(io.LimitReader(rc, limit))
		}
	}
	return nil, ErrItemNotFound
}

// analyzeXHTML 扫描单个 XHTML 页面：统计内嵌图片数与可见文字量。
// 使用 html tokenizer 避免误计 <script>/<style> 内容，且不受标签大小写影响。
func analyzeXHTML(data []byte) (imgCount, textChars int) {
	z := html.NewTokenizer(bytes.NewReader(data))
	skip := 0 // 当前处于 script/style 的嵌套深度
	for {
		tt := z.Next()
		switch tt {
		case html.ErrorToken:
			return
		case html.StartTagToken:
			name, _ := z.TagName()
			sn := string(name)
			if sn == "img" {
				imgCount++
			}
			if sn == "script" || sn == "style" {
				skip++
			}
		case html.SelfClosingTagToken:
			// XHTML 自闭合标签（<img .../>）在 tokenizer 中单独输出
			name, _ := z.TagName()
			if string(name) == "img" {
				imgCount++
			}
		case html.EndTagToken:
			name, _ := z.TagName()
			sn := string(name)
			if (sn == "script" || sn == "style") && skip > 0 {
				skip--
			}
		case html.TextToken:
			if skip > 0 {
				continue
			}
			for _, b := range bytes.TrimSpace(z.Text()) {
				if b != ' ' && b != '\t' && b != '\n' && b != '\r' && b != '\u00a0' {
					textChars++
				}
			}
		}
	}
}

// readOPFPath 读取 META-INF/container.xml 获取 OPF 文件路径
func readOPFPath(files map[string]*zip.File) (string, error) {
	var c containerXML
	if err := readXML(files, "META-INF/container.xml", &c); err != nil {
		return "", ErrNotEPUB
	}
	if c.Rootfiles.Rootfile.FullPath == "" {
		return "", ErrNotEPUB
	}
	return c.Rootfiles.Rootfile.FullPath, nil
}

// resolveHref 将相对 href 解析为 zip 内完整路径
func resolveHref(baseDir, href string) string {
	// 去掉锚点
	if i := strings.Index(href, "#"); i >= 0 {
		href = href[:i]
	}
	return path.Clean(path.Join(baseDir, href))
}

// ResolveHref 导出版：将相对 href（如 XHTML 内 img src）解析为 zip 内完整路径
func ResolveHref(baseDir, href string) string {
	return resolveHref(baseDir, href)
}

// ExtractPageImages 从 XHTML 页面内容中提取全部 <img src> 引用（原样，未解析相对路径）。
// 用于"一页一图"型漫画按 spine 顺序还原阅读顺序。
func ExtractPageImages(data []byte) []string {
	z := html.NewTokenizer(bytes.NewReader(data))
	var refs []string
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			return refs
		}
		if tt != html.StartTagToken && tt != html.SelfClosingTagToken {
			continue
		}
		name, _ := z.TagName()
		if string(name) != "img" {
			continue
		}
		for {
			k, v, more := z.TagAttr()
			if string(k) == "src" && strings.TrimSpace(string(v)) != "" {
				refs = append(refs, string(v))
				break
			}
			if !more {
				break
			}
		}
	}
}

// parseTOC 解析目录：优先 EPUB3 nav 文档，fallback NCX
func (e *EPUB) parseTOC(files map[string]*zip.File, opfDir, ncxID string) []TOCItem {
	// EPUB3：manifest 中 properties 含 nav 的条目
	for _, it := range e.Manifest {
		if strings.Contains(it.Properties, "nav") {
			if toc := e.parseNav(files, it.Href); len(toc) > 0 {
				return toc
			}
		}
	}
	// EPUB2：NCX
	if ncxID != "" {
		if it, ok := e.Manifest[ncxID]; ok {
			if toc := e.parseNCX(files, it.Href); len(toc) > 0 {
				return toc
			}
		}
	}
	// 兜底：扫描 media-type 为 ncx 的条目
	for _, it := range e.Manifest {
		if it.MediaType == "application/x-dtbncx+xml" {
			if toc := e.parseNCX(files, it.Href); len(toc) > 0 {
				return toc
			}
		}
	}
	// 最终兜底：用 spine 顺序生成目录
	var toc []TOCItem
	for i, idref := range e.Spine {
		if it, ok := e.Manifest[idref]; ok {
			toc = append(toc, TOCItem{Title: fmt.Sprintf("第 %d 节", i+1), Href: it.Href})
		}
	}
	return toc
}

// navPoint NCX 目录节点
type ncxNavMap struct {
	Points []struct {
		Label   string `xml:"navLabel>text"`
		Content struct {
			Src string `xml:"src,attr"`
		} `xml:"content"`
	} `xml:"navMap>navPoint"`
}

func (e *EPUB) parseNCX(files map[string]*zip.File, ncxPath string) []TOCItem {
	var nav ncxNavMap
	if err := readXML(files, ncxPath, &nav); err != nil {
		return nil
	}
	dir := path.Dir(ncxPath)
	var toc []TOCItem
	for _, p := range nav.Points {
		toc = append(toc, TOCItem{Title: strings.TrimSpace(p.Label), Href: resolveHref(dir, p.Content.Src)})
	}
	return toc
}

// parseNav 解析 EPUB3 nav XHTML 文档中的目录链接
func (e *EPUB) parseNav(files map[string]*zip.File, navPath string) []TOCItem {
	f, ok := files[navPath]
	if !ok {
		return nil
	}
	rc, err := f.Open()
	if err != nil {
		return nil
	}
	defer rc.Close()
	doc, err := html.Parse(rc)
	if err != nil {
		return nil
	}

	dir := path.Dir(navPath)
	var toc []TOCItem
	var walk func(n *html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode && n.Data == "a" {
			href := ""
			for _, attr := range n.Attr {
				if attr.Key == "href" {
					href = attr.Val
				}
			}
			if href != "" {
				text := strings.TrimSpace(extractText(n))
				if text != "" {
					toc = append(toc, TOCItem{Title: text, Href: resolveHref(dir, href)})
				}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	return toc
}

// extractText 提取节点全部文本
func extractText(n *html.Node) string {
	if n.Type == html.TextNode {
		return n.Data
	}
	var sb strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		sb.WriteString(extractText(c))
	}
	return sb.String()
}

// readXML 读取 zip 内 XML 文件并解析
func readXML(files map[string]*zip.File, name string, v interface{}) error {
	f, ok := files[name]
	if !ok {
		return fmt.Errorf("zip 内不存在 %s", name)
	}
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, 16<<20))
	if err != nil {
		return err
	}
	return xml.Unmarshal(data, v)
}

// ReadItem 按 manifest ID 读取条目内容与 MediaType。
// ID 未命中时按 zip 内完整路径（href）兜底读取——前端经 TOC 拿到的
// 章节地址与章节 HTML 中 img src 的相对路径解析结果均为 href。
func (e *EPUB) ReadItem(id string) ([]byte, string, error) {
	if it, ok := e.Manifest[id]; ok {
		data, err := e.ReadByHref(it.Href)
		return data, it.MediaType, err
	}
	data, err := e.ReadByHref(id)
	if err != nil {
		return nil, "", err
	}
	mt := mime.TypeByExtension(path.Ext(id))
	if mt == "" {
		mt = "application/octet-stream"
	}
	return data, mt, nil
}

// ReadByHref 按 zip 内路径读取内容
func (e *EPUB) ReadByHref(href string) ([]byte, error) {
	for _, f := range e.zr.File {
		if f.Name == href {
			rc, err := f.Open()
			if err != nil {
				return nil, err
			}
			defer rc.Close()
			return io.ReadAll(io.LimitReader(rc, 64<<20))
		}
	}
	return nil, ErrItemNotFound
}

// CoverItemID 返回封面条目的 manifest ID（无封面返回空）
func (e *EPUB) CoverItemID() string {
	if e.Cover == "" {
		return ""
	}
	for id, it := range e.Manifest {
		if it.Href == e.Cover {
			return id
		}
	}
	return ""
}
