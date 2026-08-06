package adapter

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/studio-b12/gowebdav"
)

// WebDavConfig WebDAV 路径源配置（存于 Source.ConfigJSON）
type WebDavConfig struct {
	URL      string `json:"url"`      // WebDAV 服务地址，如 https://nas.example.com:5006
	LanURL   string `json:"lan_url"`  // 内网地址（可选），可达时优先使用
	Username string `json:"username"` // 用户名
	Password string `json:"password"` // 密码
	Insecure bool   `json:"insecure"` // 是否跳过 TLS 证书校验（自签名场景）
}

// WebDavAdapter WebDAV 存储适配器。
// 基于 gowebdav 客户端；ReadStream 通过 ReadStreamRange 透传 HTTP Range 头。
// basePath 为服务器上的挂载点根路径，所有相对路径限制在其内。
type WebDavAdapter struct {
	client   *gowebdav.Client
	basePath string // 挂载点根路径（POSIX 风格，无尾 "/"）
	network  string // 实际使用的链路："lan" 内网 / "wan" 外网
}

// NewWebDavAdapter 创建 WebDAV 适配器
func NewWebDavAdapter(cfg *WebDavConfig, basePath string) (*WebDavAdapter, error) {
	if strings.TrimSpace(cfg.URL) == "" {
		return nil, errors.New("WebDAV 配置缺少 url")
	}
	// 配置了内网地址时优先探测内网，可达则使用内网连接，否则回退公网地址
	url := cfg.URL
	network := "wan"
	if lan := strings.TrimSpace(cfg.LanURL); lan != "" && probeURL(lan, 3*time.Second) {
		url = lan
		network = "lan"
	}
	client := gowebdav.NewClient(url, cfg.Username, cfg.Password)
	client.SetTimeout(30 * time.Second)
	// 自定义 Transport：提高每主机空闲连接上限（默认仅 2）。
	// 适配器被 SourceService 缓存后，Transport 长期复用，
	// 流式 Range 高频请求的连接得以入池复用，减少 TIME_WAIT 堆积。
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   32,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
	if cfg.Insecure {
		// 用户显式配置跳过自签名证书校验
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec
	}
	client.SetTransport(transport)

	base := "/" + strings.Trim(path.Clean("/"+basePath), "/")
	if base == "/" {
		base = ""
	}
	return &WebDavAdapter{client: client, basePath: base, network: network}, nil
}

// Network 返回实际使用的链路："lan" 内网 / "wan" 外网
func (a *WebDavAdapter) Network() string { return a.network }

// probeURL 短超时探测地址可达性，收到任意 HTTP 响应（含 401/404）即视为可达
func probeURL(rawURL string, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return false
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return true
}

// resolve 将相对路径解析为服务器上的完整路径，并强制限制在 basePath 内。
func (a *WebDavAdapter) resolve(p string) (string, error) {
	cleaned := path.Clean("/" + p)
	if strings.Contains(cleaned, "..") {
		return "", ErrForbidden
	}
	return a.basePath + cleaned, nil
}

// rel 将服务器完整路径转回相对 basePath 的路径
func (a *WebDavAdapter) rel(full string) string {
	r := strings.TrimPrefix(full, a.basePath)
	if r == "" {
		return "/"
	}
	return r
}

// mapErr 将 gowebdav 错误映射为适配器统一错误
func mapErr(err error) error {
	if err == nil {
		return nil
	}
	if gowebdav.IsErrNotFound(err) || errors.Is(err, os.ErrNotExist) {
		return ErrNotExist
	}
	return err
}

// toFileInfo 将 os.FileInfo 转换为统一 FileInfo
func (a *WebDavAdapter) toFileInfo(full string, fi os.FileInfo) FileInfo {
	size := fi.Size()
	if fi.IsDir() {
		size = 0
	}
	return FileInfo{
		Name:    fi.Name(),
		Path:    a.rel(full),
		Size:    size,
		IsDir:   fi.IsDir(),
		ModTime: fi.ModTime(),
	}
}

// Test 连接测试：Stat 挂载点根路径
func (a *WebDavAdapter) Test(ctx context.Context) error {
	root := a.basePath
	if root == "" {
		root = "/"
	}
	fi, err := a.client.Stat(root)
	if err != nil {
		return mapErr(err)
	}
	if !fi.IsDir() {
		return ErrNotDirectory
	}
	return nil
}

// List 列出目录内容（目录在前，按名称排序），自动隐藏 .trash 目录
func (a *WebDavAdapter) List(ctx context.Context, p string) ([]FileInfo, error) {
	full, err := a.resolve(p)
	if err != nil {
		return nil, err
	}
	entries, err := a.client.ReadDir(full)
	if err != nil {
		return nil, mapErr(err)
	}

	infos := make([]FileInfo, 0, len(entries))
	for _, fi := range entries {
		if full == a.basePath && fi.Name() == TrashDirName {
			continue
		}
		infos = append(infos, a.toFileInfo(path.Join(full, fi.Name()), fi))
	}
	sort.Slice(infos, func(i, j int) bool {
		if infos[i].IsDir != infos[j].IsDir {
			return infos[i].IsDir
		}
		return strings.ToLower(infos[i].Name) < strings.ToLower(infos[j].Name)
	})
	return infos, nil
}

// Stat 获取单个文件/目录元信息
func (a *WebDavAdapter) Stat(ctx context.Context, p string) (*FileInfo, error) {
	full, err := a.resolve(p)
	if err != nil {
		return nil, err
	}
	fi, err := a.client.Stat(full)
	if err != nil {
		return nil, mapErr(err)
	}
	info := a.toFileInfo(full, fi)
	return &info, nil
}

// ReadStream 流式读取，Range 请求头透传到 WebDAV 服务端
func (a *WebDavAdapter) ReadStream(ctx context.Context, p string, offset, length int64) (io.ReadCloser, error) {
	full, err := a.resolve(p)
	if err != nil {
		return nil, err
	}
	if offset <= 0 && length < 0 {
		rc, err := a.client.ReadStream(full)
		return rc, mapErr(err)
	}
	if length < 0 {
		length = 0 // gowebdav: length=0 表示读到末尾
	}
	rc, err := a.client.ReadStreamRange(full, offset, length)
	return rc, mapErr(err)
}

// WriteStream 流式上传（覆盖已存在文件），自动创建父目录
func (a *WebDavAdapter) WriteStream(ctx context.Context, p string, r io.Reader, size int64) error {
	full, err := a.resolve(p)
	if err != nil {
		return err
	}
	if err := a.client.MkdirAll(path.Dir(full), 0o755); err != nil {
		return mapErr(err)
	}
	if size >= 0 {
		return mapErr(a.client.WriteStreamWithLength(full, r, size, 0o644))
	}
	return mapErr(a.client.WriteStream(full, r, 0o644))
}

// Move 移动/重命名（服务端 MOVE，不覆盖已存在目标）
func (a *WebDavAdapter) Move(ctx context.Context, src, dst string) error {
	srcFull, err := a.resolve(src)
	if err != nil {
		return err
	}
	dstFull, err := a.resolve(dst)
	if err != nil {
		return err
	}
	if err := a.client.MkdirAll(path.Dir(dstFull), 0o755); err != nil {
		return mapErr(err)
	}
	return mapErr(a.client.Rename(srcFull, dstFull, false))
}

// Copy 复制（服务端 COPY，不覆盖已存在目标；目录是否递归取决于服务端实现）
func (a *WebDavAdapter) Copy(ctx context.Context, src, dst string) error {
	srcFull, err := a.resolve(src)
	if err != nil {
		return err
	}
	dstFull, err := a.resolve(dst)
	if err != nil {
		return err
	}
	if err := a.client.MkdirAll(path.Dir(dstFull), 0o755); err != nil {
		return mapErr(err)
	}
	return mapErr(a.client.Copy(srcFull, dstFull, false))
}

// Delete 逻辑删除：移入 .trash/<时间戳>_<原名>，返回回收站内相对路径
func (a *WebDavAdapter) Delete(ctx context.Context, p string) (string, error) {
	if path.Clean("/"+p) == "/" {
		return "", ErrForbidden // 不允许删除挂载点根
	}
	full, err := a.resolve(p)
	if err != nil {
		return "", err
	}
	if _, err := a.client.Stat(full); err != nil {
		return "", mapErr(err)
	}

	trashDir := a.basePath + "/" + TrashDirName
	if err := a.client.MkdirAll(trashDir, 0o755); err != nil {
		return "", mapErr(err)
	}

	name := fmt.Sprintf("%s_%s", time.Now().Format("20060102150405"), path.Base(full))
	trashFull := path.Join(trashDir, name)
	for i := 1; ; i++ {
		if _, err := a.client.Stat(trashFull); err != nil {
			break
		}
		trashFull = path.Join(trashDir, fmt.Sprintf("%s_%d", name, i))
	}

	if err := a.client.Rename(full, trashFull, false); err != nil {
		return "", mapErr(err)
	}
	return a.rel(trashFull), nil
}

// Restore 从回收站还原到原始路径
func (a *WebDavAdapter) Restore(ctx context.Context, trashPath, originalPath string) error {
	trashFull, err := a.resolve(trashPath)
	if err != nil {
		return err
	}
	if path.Dir(trashFull) != a.basePath+"/"+TrashDirName {
		return fmt.Errorf("%w：仅允许从 %s 目录还原", ErrForbidden, TrashDirName)
	}
	origFull, err := a.resolve(originalPath)
	if err != nil {
		return err
	}
	if _, err := a.client.Stat(origFull); err == nil {
		return fmt.Errorf("%w: %s", ErrTargetExists, originalPath)
	}
	if err := a.client.MkdirAll(path.Dir(origFull), 0o755); err != nil {
		return mapErr(err)
	}
	return mapErr(a.client.Rename(trashFull, origFull, false))
}

// Purge 物理删除回收站内文件（仅限 .trash 目录内）
func (a *WebDavAdapter) Purge(ctx context.Context, trashPath string) error {
	full, err := a.resolve(trashPath)
	if err != nil {
		return err
	}
	if path.Dir(full) != a.basePath+"/"+TrashDirName {
		return fmt.Errorf("%w：仅允许清空 %s 目录内文件", ErrForbidden, TrashDirName)
	}
	return mapErr(a.client.RemoveAll(full))
}

// Mkdir 新建目录（递归创建父目录）
func (a *WebDavAdapter) Mkdir(ctx context.Context, p string) error {
	full, err := a.resolve(p)
	if err != nil {
		return err
	}
	return mapErr(a.client.MkdirAll(full, 0o755))
}
