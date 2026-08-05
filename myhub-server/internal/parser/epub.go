package parser

import (
	"archive/zip"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"path"
	"strings"

	"golang.org/x/net/html"
)

// EPUB 相关错误
var (
	ErrNotEPUB       = errors.New("不是有效的 EPUB 文件")
	ErrItemNotFound  = errors.New("EPUB 条目不存在")
	ErrNoTOC         = errors.New("EPUB 缺少目录")
)

// ManifestItem OPF manifest 条目
type ManifestItem struct {
	ID         string `json:"id"`
	Href       string `json:"href"`       // 已解析为 zip 内完整路径
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
	IsComic  bool // 图集型（漫画）判定：图片占比 ≥ 90%
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

	// 图集型判定：图片条目占比 ≥ 90%
	images, docs := 0, 0
	for _, it := range e.Manifest {
		if strings.HasPrefix(it.MediaType, "image/") {
			images++
		} else if it.MediaType == "application/xhtml+xml" || it.MediaType == "text/html" {
			docs++
		}
	}
	e.IsComic = images > 0 && docs > 0 && float64(images)/float64(images+docs) >= 0.9 ||
		images > 0 && docs == 0

	return e, nil
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

// ReadItem 按 manifest ID 读取条目内容与 MediaType
func (e *EPUB) ReadItem(id string) ([]byte, string, error) {
	it, ok := e.Manifest[id]
	if !ok {
		return nil, "", ErrItemNotFound
	}
	data, err := e.ReadByHref(it.Href)
	return data, it.MediaType, err
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
