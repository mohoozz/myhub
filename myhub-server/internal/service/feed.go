package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"myhub-server/internal/config"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// 动态模块业务错误
var (
	ErrFeedUnavailable = errors.New("动态抓取服务不可用")
	ErrFeedItemNotFound = errors.New("动态条目不存在")
	ErrWatchLaterNotFound = errors.New("稍后观看条目不存在")
	ErrWatchLaterExists = errors.New("已在稍后观看")
)

// FeedService 动态模块业务逻辑。
//
// 数据源分两路：
//   - 动态条目、订阅源、抓取触发 → 代理到 myhub-feed（Python 服务）；
//   - 已读游标、稍后观看 → 本地 SQLite（myhub-feed 不提供这些能力）。
//
// 动态条目在列表查询时按 myhub-feed 增量接口（/api/items?since_id=）拉取到
// 本地 feed_items 表缓存，从而支持按发布时间降序 + id 游标的无限滚动。
type FeedService struct {
	feedRepo *repository.FeedRepository
	baseURL  string
	client   *http.Client
}

// NewFeedService 创建 FeedService
func NewFeedService(cfg *config.Config, feedRepo *repository.FeedRepository) *FeedService {
	base := cfg.Feed.BaseURL
	if base == "" {
		base = "http://127.0.0.1:8100"
	}
	for len(base) > 0 && base[len(base)-1] == '/' {
		base = base[:len(base)-1]
	}
	return &FeedService{
		feedRepo: feedRepo,
		baseURL:  base,
		client:   &http.Client{Timeout: 60 * time.Second},
	}
}

// ---------- myhub-feed 代理 HTTP ----------

// feedGet 请求 myhub-feed 的 GET 接口，返回解析后的 JSON body。
func (s *FeedService) feedGet(ctx context.Context, path string, query url.Values) (map[string]any, error) {
	u := s.baseURL + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrFeedUnavailable, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("myhub-feed 返回 %d: %s", resp.StatusCode, string(body))
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// feedPost 请求 myhub-feed 的 POST 接口（无 body）。
func (s *FeedService) feedPost(ctx context.Context, path string, query url.Values) (map[string]any, error) {
	u := s.baseURL + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrFeedUnavailable, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("myhub-feed 返回 %d: %s", resp.StatusCode, string(body))
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ---------- 动态条目 ----------

// syncItems 从 myhub-feed 增量拉取条目到本地缓存。
// myhub-feed 的 /api/items?since_id= 按自增 id 升序返回；本地记录已同步到的最大 id。
func (s *FeedService) syncItems(ctx context.Context) error {
	sinceID, err := s.feedRepo.MaxSourceID()
	if err != nil {
		return err
	}
	for {
		body, err := s.feedGet(ctx, "/api/items", url.Values{
			"since_id": {fmt.Sprintf("%d", sinceID)},
			"limit":    {"500"},
		})
		if err != nil {
			return err
		}
		items, _ := body["items"].([]any)
		if len(items) == 0 {
			return nil
		}
		for _, raw := range items {
			m, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			item, err := parseFeedItem(m)
			if err != nil {
				continue
			}
			if _, err := s.feedRepo.UpsertItem(item); err != nil {
				return err
			}
			if item.SourceID > sinceID {
				sinceID = item.SourceID
			}
		}
		if len(items) < 500 {
			return nil
		}
	}
}

// parseFeedItem 将 myhub-feed 的 items 元素映射为本地 FeedItem。
// 本地 ID 由 GORM 自增生成（作为前端游标），myhub-feed 的源库 id 存入 SourceID。
func parseFeedItem(m map[string]any) (*model.FeedItem, error) {
	item := &model.FeedItem{
		SourceID:    uint(toInt64(m["id"])),
		Platform:    toString(m["platform"]),
		ContentID:   toString(m["content_id"]),
		MediaType:   toString(m["media_type"]),
		Author:      toString(m["author"]),
		Title:       toString(m["title"]),
		Cover:       toString(m["cover"]),
		URL:         toString(m["url"]),
		Description: toString(m["description"]),
	}
	if item.MediaType == "" {
		item.MediaType = "video"
	}
	item.PublishedAt = toTime(m["published_at"])
	item.CreatedAt = toTime(m["created_at"])
	return item, nil
}

// List 动态列表：先同步 myhub-feed 最新条目，再按发布时间降序 + id 游标分页。
func (s *FeedService) List(ctx context.Context, beforeID uint, limit int) ([]model.FeedItem, error) {
	if limit < 1 || limit > 200 {
		limit = 20
	}
	// 同步失败不阻断列表（返回已有缓存），仅记录
	_ = s.syncItems(ctx)
	return s.feedRepo.ListItems(beforeID, limit)
}

// ---------- 已读游标 ----------

// MarkRead 更新已读游标到指定条目。
func (s *FeedService) MarkRead(ctx context.Context, feedItemID uint) error {
	item, err := s.feedRepo.GetItem(feedItemID)
	if err != nil {
		return ErrFeedItemNotFound
	}
	return s.feedRepo.SaveCursor(item.ID, item.PublishedAt)
}

// ReadAll 将游标推进到当前最新条目（全部标为已读）。
func (s *FeedService) ReadAll(ctx context.Context) error {
	_ = s.syncItems(ctx)
	items, err := s.feedRepo.ListItems(0, 1)
	if err != nil {
		return err
	}
	if len(items) == 0 {
		return nil
	}
	return s.feedRepo.SaveCursor(items[0].ID, items[0].PublishedAt)
}

// GetCursor 获取已读游标。
func (s *FeedService) GetCursor(ctx context.Context) (*model.FeedCursor, error) {
	return s.feedRepo.GetCursor()
}

// ---------- 订阅源（代理 myhub-feed） ----------

// ListSubscriptions 订阅源列表。
func (s *FeedService) ListSubscriptions(ctx context.Context) (map[string]any, error) {
	return s.feedGet(ctx, "/api/subscriptions", nil)
}

// AddSubscription 新增订阅源。
func (s *FeedService) AddSubscription(ctx context.Context, platform, target, name string) (map[string]any, error) {
	body := map[string]any{
		"platform": platform,
		"target":   target,
		"name":     name,
	}
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.baseURL+"/api/subscriptions", bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrFeedUnavailable, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("myhub-feed 返回 %d: %s", resp.StatusCode, string(data))
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// DeleteSubscription 删除订阅源。
func (s *FeedService) DeleteSubscription(ctx context.Context, id int, purge bool) (map[string]any, error) {
	q := url.Values{}
	if purge {
		q.Set("purge", "true")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, s.baseURL+fmt.Sprintf("/api/subscriptions/%d", id)+"?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrFeedUnavailable, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("myhub-feed 返回 %d: %s", resp.StatusCode, string(data))
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ---------- 抓取触发（代理 myhub-feed） ----------

// Fetch 手动触发抓取。
func (s *FeedService) Fetch(ctx context.Context, platform string, subscriptionID int) (map[string]any, error) {
	q := url.Values{}
	if platform != "" {
		q.Set("platform", platform)
	}
	if subscriptionID > 0 {
		q.Set("subscription_id", fmt.Sprintf("%d", subscriptionID))
	}
	return s.feedPost(ctx, "/api/fetch", q)
}

// ListLogs 抓取日志（代理 myhub-feed）。
func (s *FeedService) ListLogs(ctx context.Context, limit int) (map[string]any, error) {
	if limit < 1 {
		limit = 50
	}
	return s.feedGet(ctx, "/api/logs", url.Values{"limit": {fmt.Sprintf("%d", limit)}})
}

// ---------- 稍后观看（本地 SQLite） ----------

// ListWatchLater 稍后观看列表（返回关联动态条目详情）。
func (s *FeedService) ListWatchLater(ctx context.Context) ([]map[string]any, error) {
	list, err := s.feedRepo.ListWatchLater(200)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(list))
	for _, w := range list {
		item, err := s.feedRepo.GetItemByKey(w.Platform, w.ContentID)
		entry := map[string]any{
			"id":         w.ID,
			"platform":   w.Platform,
			"content_id": w.ContentID,
			"created_at": w.CreatedAt,
		}
		if err == nil && item != nil {
			entry["item"] = item
		}
		out = append(out, entry)
	}
	return out, nil
}

// AddWatchLater 加入稍后观看。
func (s *FeedService) AddWatchLater(ctx context.Context, platform, contentID string) (*model.WatchLater, error) {
	exists, err := s.feedRepo.ExistsWatchLater(platform, contentID)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, ErrWatchLaterExists
	}
	return s.feedRepo.AddWatchLater(platform, contentID)
}

// RemoveWatchLater 移出稍后观看。
func (s *FeedService) RemoveWatchLater(ctx context.Context, platform, contentID string) error {
	return s.feedRepo.RemoveWatchLater(platform, contentID)
}

// ---------- 辅助 ----------

func toString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func toInt64(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int64:
		return n
	case int:
		return int64(n)
	case json.Number:
		i, _ := n.Int64()
		return i
	}
	return 0
}

func toTime(v any) time.Time {
	if v == nil {
		return time.Time{}
	}
	s, ok := v.(string)
	if !ok || s == "" {
		return time.Time{}
	}
	// 优先 RFC3339（带时区）；失败则按朴素时间解析（视为 UTC），
	// 覆盖 myhub-feed 这种无时区输出的场景（time.RFC3339Nano 也兼容）。
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05", "2006-01-02 15:04:05"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}
