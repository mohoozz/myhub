package service

import (
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"

	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 浏览器模块业务错误
var (
	ErrInvalidURL       = errors.New("无效的 URL（仅支持 http/https）")
	ErrInvalidCursor    = errors.New("无效的分页游标")
	ErrBookmarkNotFound = errors.New("书签不存在")
	ErrHistoryNotFound  = errors.New("历史记录不存在")
	ErrShortcutNotFound = errors.New("快捷入口不存在")
	ErrShortcutExists   = errors.New("该网址已存在快捷入口")
)

// 入库字段防御性上限（SQLite 不强制 VARCHAR 长度，入库前统一裁剪）
const (
	maxTitleRunes = 170 // 约 510 字节，兼容中文标题
	maxURLBytes   = 2048
	maxFaviconLen = 16384 // 超长 data URI 直接丢弃
)

// HistoryItemInput 历史上报单条输入（VisitedAt 零值表示用服务器当前时间）
type HistoryItemInput struct {
	Title     string
	URL       string
	Favicon   string
	VisitedAt time.Time
}

// ShortcutUpdate 快捷入口更新输入（指针字段区分"未提供"与"置空"）
type ShortcutUpdate struct {
	ID        uint
	Title     *string
	URL       *string
	SortOrder *int
}

// BookmarkUpdate 书签更新输入（指针字段区分"未提供"与"置空"）
type BookmarkUpdate struct {
	ID      uint
	Title   *string
	URL     *string
	Favicon *string
}

// BrowserService 浏览器书签/历史/快捷入口业务逻辑
type BrowserService struct {
	repo *repository.BrowserRepository
}

// NewBrowserService 创建 BrowserService
func NewBrowserService(repo *repository.BrowserRepository) *BrowserService {
	return &BrowserService{repo: repo}
}

// ---------- 书签 ----------

// ListBookmarks 书签列表（按创建时间降序）
func (s *BrowserService) ListBookmarks() ([]model.Bookmark, error) {
	return s.repo.ListBookmarks()
}

// AddBookmark 添加书签：URL 唯一，重复添加幂等（更新标题/favicon 后返回既有记录，created=false）
func (s *BrowserService) AddBookmark(title, rawURL, favicon string) (*model.Bookmark, bool, error) {
	u, err := NormalizeURL(rawURL)
	if err != nil {
		return nil, false, err
	}
	title = clipRunes(strings.TrimSpace(title), maxTitleRunes)
	favicon = clipFavicon(favicon)

	existing, err := s.repo.GetBookmarkByURL(u)
	switch {
	case err == nil:
		// 幂等：已收藏过则按最新信息补齐标题/favicon
		changed := false
		if title != "" && title != existing.Title {
			existing.Title = title
			changed = true
		}
		if favicon != "" && favicon != existing.Favicon {
			existing.Favicon = favicon
			changed = true
		}
		if changed {
			if err := s.repo.SaveBookmark(existing); err != nil {
				return nil, false, err
			}
		}
		return existing, false, nil
	case errors.Is(err, gorm.ErrRecordNotFound):
		// 不存在，走新建
	default:
		return nil, false, err
	}

	b := &model.Bookmark{Title: title, URL: u, Favicon: favicon}
	if err := s.repo.SaveBookmark(b); err != nil {
		return nil, false, err
	}
	return b, true, nil
}

// RemoveBookmark 删除书签：ID 优先，其次按 URL；两者均未提供时报书签不存在
func (s *BrowserService) RemoveBookmark(id uint, rawURL string) error {
	if id > 0 {
		if err := s.repo.DeleteBookmarkByID(id); err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrBookmarkNotFound
			}
			return err
		}
		return nil
	}
	if rawURL != "" {
		u, err := NormalizeURL(rawURL)
		if err != nil {
			return err
		}
		if err := s.repo.DeleteBookmarkByURL(u); err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrBookmarkNotFound
			}
			return err
		}
		return nil
	}
	return ErrBookmarkNotFound
}

// UpdateBookmark 更新书签标题/URL/favicon（指针字段区分"未提供"与"置空"）。
func (s *BrowserService) UpdateBookmark(in BookmarkUpdate) (*model.Bookmark, error) {
	if in.ID == 0 {
		return nil, ErrBookmarkNotFound
	}
	b, err := s.repo.GetBookmarkByID(in.ID)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrBookmarkNotFound
		}
		return nil, err
	}

	if in.Title != nil {
		b.Title = clipRunes(strings.TrimSpace(*in.Title), maxTitleRunes)
	}
	if in.URL != nil {
		u, err := NormalizeURL(*in.URL)
		if err != nil {
			return nil, err
		}
		b.URL = u
	}
	if in.Favicon != nil {
		b.Favicon = clipFavicon(*in.Favicon)
	}

	if err := s.repo.SaveBookmark(b); err != nil {
		return nil, err
	}
	return b, nil
}

// ---------- 历史 ----------

// ListHistory 历史分页（visited_at 降序），返回列表与下一页游标（空串表示没有更多）
func (s *BrowserService) ListHistory(cursor string, limit int) ([]model.BrowserHistory, string, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	var beforeMs int64
	var beforeID uint
	hasCursor := cursor != ""
	if hasCursor {
		ms, id, ok := parseHistoryCursor(cursor)
		if !ok {
			return nil, "", ErrInvalidCursor
		}
		beforeMs, beforeID = ms, id
	}

	items, err := s.repo.ListHistory(beforeMs, beforeID, hasCursor, limit)
	if err != nil {
		return nil, "", err
	}

	next := ""
	if len(items) == limit {
		last := items[len(items)-1]
		next = fmt.Sprintf("%d-%d", last.VisitedMs, last.ID)
	}
	return items, next, nil
}

// ReportHistory 批量上报访问历史：无效 URL 条目跳过，返回成功入库条数（单批最多 200 条）
func (s *BrowserService) ReportHistory(items []HistoryItemInput) (int, error) {
	if len(items) == 0 {
		return 0, nil
	}
	if len(items) > 200 {
		items = items[:200]
	}
	now := time.Now()
	rows := make([]model.BrowserHistory, 0, len(items))
	for _, it := range items {
		u, err := NormalizeURL(it.URL)
		if err != nil {
			continue
		}
		t := it.VisitedAt
		if t.IsZero() {
			t = now
		}
		rows = append(rows, model.BrowserHistory{
			Title:     clipRunes(strings.TrimSpace(it.Title), maxTitleRunes),
			URL:       u,
			Favicon:   clipFavicon(it.Favicon),
			VisitedAt: t,
			VisitedMs: t.UnixMilli(),
		})
	}
	if len(rows) == 0 {
		return 0, nil
	}
	if err := s.repo.CreateHistoryItems(rows); err != nil {
		return 0, err
	}
	return len(rows), nil
}

// DeleteHistory 删除单条历史
func (s *BrowserService) DeleteHistory(id uint) error {
	if id == 0 {
		return ErrHistoryNotFound
	}
	if err := s.repo.DeleteHistoryByID(id); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrHistoryNotFound
		}
		return err
	}
	return nil
}

// ClearHistory 清空历史
func (s *BrowserService) ClearHistory() error {
	return s.repo.ClearHistory()
}

// ---------- 快捷入口 ----------

// ListShortcuts 快捷入口列表（按 sort_order 升序）
func (s *BrowserService) ListShortcuts() ([]model.BrowserShortcut, error) {
	return s.repo.ListShortcuts()
}

// AddShortcut 添加快捷入口：sort_order 追加到末尾；标题为空时用域名兜底
func (s *BrowserService) AddShortcut(title, rawURL string) (*model.BrowserShortcut, error) {
	u, err := NormalizeURL(rawURL)
	if err != nil {
		return nil, err
	}
	title = clipRunes(strings.TrimSpace(title), maxTitleRunes)
	if title == "" {
		title = hostOf(u)
	}

	if _, err := s.repo.GetShortcutByURL(u); err == nil {
		return nil, ErrShortcutExists
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

	maxOrder, err := s.repo.MaxShortcutOrder()
	if err != nil {
		return nil, err
	}
	sc := &model.BrowserShortcut{Title: title, URL: u, SortOrder: maxOrder + 1}
	if err := s.repo.SaveShortcut(sc); err != nil {
		return nil, err
	}
	return sc, nil
}

// UpdateShortcut 更新快捷入口（仅更新提供的字段）
func (s *BrowserService) UpdateShortcut(up ShortcutUpdate) (*model.BrowserShortcut, error) {
	if up.ID == 0 {
		return nil, ErrShortcutNotFound
	}
	sc, err := s.repo.GetShortcutByID(up.ID)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrShortcutNotFound
		}
		return nil, err
	}

	if up.URL != nil {
		u, err := NormalizeURL(*up.URL)
		if err != nil {
			return nil, err
		}
		if u != sc.URL {
			existing, err := s.repo.GetShortcutByURL(u)
			if err == nil && existing.ID != sc.ID {
				return nil, ErrShortcutExists
			} else if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
				return nil, err
			}
			sc.URL = u
		}
	}
	if up.Title != nil {
		if t := clipRunes(strings.TrimSpace(*up.Title), maxTitleRunes); t != "" {
			sc.Title = t
		}
	}
	if up.SortOrder != nil {
		sc.SortOrder = *up.SortOrder
	}

	if err := s.repo.SaveShortcut(sc); err != nil {
		return nil, err
	}
	return sc, nil
}

// ReorderShortcuts 按 ids 顺序批量重排（sort_order = 数组下标）
func (s *BrowserService) ReorderShortcuts(ids []uint) error {
	if len(ids) == 0 {
		return nil
	}
	return s.repo.UpdateShortcutOrders(ids)
}

// RemoveShortcut 删除快捷入口
func (s *BrowserService) RemoveShortcut(id uint) error {
	if id == 0 {
		return ErrShortcutNotFound
	}
	if err := s.repo.DeleteShortcutByID(id); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrShortcutNotFound
		}
		return err
	}
	return nil
}

// defaultShortcuts 首次启动预置的默认快捷入口（常用站点）。
var defaultShortcuts = []struct {
	Title string
	URL   string
}{
	{"百度", "https://www.baidu.com"},
	{"Bing", "https://www.bing.com"},
	{"GitHub", "https://github.com"},
	{"知乎", "https://www.zhihu.com"},
	{"哔哩哔哩", "https://www.bilibili.com"},
	{"YouTube", "https://www.youtube.com"},
	{"维基百科", "https://www.wikipedia.org"},
	{"豆瓣", "https://www.douban.com"},
}

// SeedDefaultShortcuts 首次启动预置默认快捷入口：仅当快捷入口表为空时执行。
func (s *BrowserService) SeedDefaultShortcuts() error {
	existing, err := s.repo.ListShortcuts()
	if err != nil {
		return err
	}
	if len(existing) > 0 {
		return nil // 已有快捷入口（用户可能已清空或自定义），不重复预置
	}
	for i, d := range defaultShortcuts {
		sc := &model.BrowserShortcut{
			Title:     d.Title,
			URL:       d.URL,
			SortOrder: i,
		}
		if err := s.repo.SaveShortcut(sc); err != nil {
			return err
		}
	}
	return nil
}

// ---------- 工具 ----------

// NormalizeURL 校验并规范化 URL：仅接受 http/https 且 host 非空，去除 fragment
func NormalizeURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > maxURLBytes {
		return "", ErrInvalidURL
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", ErrInvalidURL
	}
	u.Fragment = ""
	u.RawFragment = ""
	// 空路径的尾斜杠统一去除：https://a.com/ 与 https://a.com 视为同一 URL
	if u.Path == "/" && u.RawQuery == "" {
		u.Path = ""
	}
	result := u.String()
	if len(result) > maxURLBytes {
		return "", ErrInvalidURL
	}
	return result, nil
}

// hostOf 提取 URL 的主机名
func hostOf(rawURL string) string {
	if u, err := url.Parse(rawURL); err == nil {
		return u.Hostname()
	}
	return rawURL
}

// parseHistoryCursor 解析游标 "{visited_ms}-{id}"
func parseHistoryCursor(cursor string) (int64, uint, bool) {
	parts := strings.SplitN(cursor, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	ms, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || ms < 0 {
		return 0, 0, false
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil || id == 0 {
		return 0, 0, false
	}
	return ms, uint(id), true
}

// clipRunes 按 rune 数截断，防止超长输入
func clipRunes(s string, max int) string {
	if max <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max])
}

// clipFavicon favicon 长度限制（超长 data URI 直接丢弃）
func clipFavicon(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > maxFaviconLen {
		return ""
	}
	return s
}
