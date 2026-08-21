package service

import (
	"errors"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// setupBrowserTest 构建基于内存数据库的 BrowserService
func setupBrowserTest(t *testing.T) *BrowserService {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&model.Bookmark{}, &model.BrowserHistory{}, &model.BrowserShortcut{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	return NewBrowserService(repository.NewBrowserRepository(db))
}

// TestBookmarkIdempotentAdd 书签重复添加幂等：不新建记录，更新标题/favicon
func TestBookmarkIdempotentAdd(t *testing.T) {
	svc := setupBrowserTest(t)

	b1, created, err := svc.AddBookmark("示例站", "https://example.com/page#frag", "")
	if err != nil {
		t.Fatalf("首次添加失败: %v", err)
	}
	if !created {
		t.Fatal("首次添加应 created=true")
	}
	if b1.URL != "https://example.com/page" {
		t.Fatalf("URL 应去除 fragment，实际: %s", b1.URL)
	}

	b2, created, err := svc.AddBookmark("新标题", "https://example.com/page", "https://example.com/favicon.ico")
	if err != nil {
		t.Fatalf("重复添加失败: %v", err)
	}
	if created {
		t.Fatal("重复添加应幂等，created=false")
	}
	if b2.ID != b1.ID {
		t.Fatalf("重复添加应返回既有记录，got id=%d want=%d", b2.ID, b1.ID)
	}
	if b2.Title != "新标题" || b2.Favicon != "https://example.com/favicon.ico" {
		t.Fatalf("重复添加应更新标题/favicon，实际: %+v", b2)
	}

	list, err := svc.ListBookmarks()
	if err != nil {
		t.Fatalf("列表失败: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("书签应只有 1 条，实际 %d 条", len(list))
	}

	// 无效 URL 拒绝
	if _, _, err := svc.AddBookmark("t", "not-a-url", ""); !errors.Is(err, ErrInvalidURL) {
		t.Fatalf("无效 URL 应返回 ErrInvalidURL，实际: %v", err)
	}
}

// TestBookmarkRemove 书签删除：按 ID 与按 URL
func TestBookmarkRemove(t *testing.T) {
	svc := setupBrowserTest(t)
	b, _, err := svc.AddBookmark("A", "https://a.com", "")
	if err != nil {
		t.Fatal(err)
	}
	c, _, err := svc.AddBookmark("C", "https://c.com", "")
	if err != nil {
		t.Fatal(err)
	}

	if err := svc.RemoveBookmark(b.ID, ""); err != nil {
		t.Fatalf("按 ID 删除失败: %v", err)
	}
	if err := svc.RemoveBookmark(0, "https://c.com"); err != nil {
		t.Fatalf("按 URL 删除失败: %v", err)
	}
	if err := svc.RemoveBookmark(9999, ""); !errors.Is(err, ErrBookmarkNotFound) {
		t.Fatalf("删除不存在书签应返回 ErrBookmarkNotFound，实际: %v", err)
	}
	_ = c
}

// TestHistoryCursorPagination 历史上报与游标分页：visited_at 降序、逐页推进、无遗漏无重复
func TestHistoryCursorPagination(t *testing.T) {
	svc := setupBrowserTest(t)

	base := time.Date(2026, 8, 21, 10, 0, 0, 0, time.UTC)
	items := make([]HistoryItemInput, 0, 10)
	for i := 0; i < 10; i++ {
		items = append(items, HistoryItemInput{
			Title:     time.Unix(0, 0).Add(time.Duration(i) * time.Minute).Format("15:04"),
			URL:       "https://example.com/" + string(rune('a'+i)),
			VisitedAt: base.Add(time.Duration(i) * time.Minute),
		})
	}
	inserted, err := svc.ReportHistory(items)
	if err != nil {
		t.Fatalf("上报失败: %v", err)
	}
	if inserted != 10 {
		t.Fatalf("应入库 10 条，实际 %d 条", inserted)
	}

	// 无效 URL 条目跳过；有效条目显式指定一个最新的访问时间
	n, err := svc.ReportHistory([]HistoryItemInput{
		{URL: "javascript:alert(1)"},
		{URL: "https://valid.com", VisitedAt: base.Add(20 * time.Minute)},
	})
	if err != nil || n != 1 {
		t.Fatalf("无效条目应跳过，期望 1 实际 %d, err=%v", n, err)
	}

	// 每页 3 条，逐页取完
	var got []string
	cursor := ""
	pages := 0
	for {
		list, next, err := svc.ListHistory(cursor, 3)
		if err != nil {
			t.Fatalf("分页失败: %v", err)
		}
		for _, it := range list {
			got = append(got, it.URL)
		}
		pages++
		if next == "" || len(list) == 0 {
			break
		}
		cursor = next
		if pages > 10 {
			t.Fatal("分页疑似死循环")
		}
	}
	if len(got) != 11 {
		t.Fatalf("分页应取到全部 11 条（含 valid.com），实际 %d 条", len(got))
	}
	// 第一条为最后访问的 valid.com（显式指定了最新时间）
	if got[0] != "https://valid.com" {
		t.Fatalf("首条应为最新记录，实际: %s", got[0])
	}

	// 非法游标
	if _, _, err := svc.ListHistory("bad-cursor", 10); !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("非法游标应返回 ErrInvalidCursor，实际: %v", err)
	}

	// 单条删除 + 清空
	list, _, _ := svc.ListHistory("", 1)
	if err := svc.DeleteHistory(list[0].ID); err != nil {
		t.Fatalf("单条删除失败: %v", err)
	}
	if err := svc.DeleteHistory(99999); !errors.Is(err, ErrHistoryNotFound) {
		t.Fatalf("删除不存在记录应返回 ErrHistoryNotFound，实际: %v", err)
	}
	if err := svc.ClearHistory(); err != nil {
		t.Fatalf("清空失败: %v", err)
	}
	empty, next, _ := svc.ListHistory("", 10)
	if len(empty) != 0 || next != "" {
		t.Fatalf("清空后应为空，实际 %d 条", len(empty))
	}
}

// TestShortcutCRUDAndReorder 快捷入口：添加（标题兜底/查重）、更新、重排、删除
func TestShortcutCRUDAndReorder(t *testing.T) {
	svc := setupBrowserTest(t)

	// 标题为空时用域名兜底；sort_order 追加
	s1, err := svc.AddShortcut("", "https://nav.example.com/path")
	if err != nil {
		t.Fatalf("添加失败: %v", err)
	}
	if s1.Title != "nav.example.com" {
		t.Fatalf("空标题应回退域名，实际: %s", s1.Title)
	}
	if s1.SortOrder != 1 {
		t.Fatalf("首个 sort_order 应为 1，实际: %d", s1.SortOrder)
	}

	s2, err := svc.AddShortcut("B 站", "https://bilibili.com")
	if err != nil {
		t.Fatal(err)
	}
	s3, err := svc.AddShortcut("GitHub", "https://github.com")
	if err != nil {
		t.Fatal(err)
	}

	// URL 查重
	if _, err := svc.AddShortcut("重复", "https://github.com/"); !errors.Is(err, ErrShortcutExists) {
		t.Fatalf("重复 URL 应返回 ErrShortcutExists，实际: %v", err)
	}

	// 重排：3,1,2
	if err := svc.ReorderShortcuts([]uint{s3.ID, s1.ID, s2.ID}); err != nil {
		t.Fatalf("重排失败: %v", err)
	}
	list, err := svc.ListShortcuts()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 3 {
		t.Fatalf("应有 3 个快捷入口，实际 %d 个", len(list))
	}
	wantOrder := []uint{s3.ID, s1.ID, s2.ID}
	for i, sc := range list {
		if sc.ID != wantOrder[i] {
			t.Fatalf("重排后顺序错误，位置 %d 期望 id=%d 实际 id=%d", i, wantOrder[i], sc.ID)
		}
	}

	// 更新标题与 URL（换成新 URL 成功；换成已有 URL 冲突）
	newTitle := "哔哩哔哩"
	updated, err := svc.UpdateShortcut(ShortcutUpdate{ID: s2.ID, Title: &newTitle})
	if err != nil {
		t.Fatalf("更新失败: %v", err)
	}
	if updated.Title != newTitle {
		t.Fatalf("更新后标题应为 %q，实际 %q", newTitle, updated.Title)
	}
	dupURL := "https://nav.example.com/path"
	if _, err := svc.UpdateShortcut(ShortcutUpdate{ID: s2.ID, URL: &dupURL}); !errors.Is(err, ErrShortcutExists) {
		t.Fatalf("更新为已有 URL 应返回 ErrShortcutExists，实际: %v", err)
	}
	if _, err := svc.UpdateShortcut(ShortcutUpdate{ID: 9999}); !errors.Is(err, ErrShortcutNotFound) {
		t.Fatalf("更新不存在的入口应返回 ErrShortcutNotFound，实际: %v", err)
	}

	// 删除
	if err := svc.RemoveShortcut(s1.ID); err != nil {
		t.Fatalf("删除失败: %v", err)
	}
	if err := svc.RemoveShortcut(s1.ID); !errors.Is(err, ErrShortcutNotFound) {
		t.Fatalf("重复删除应返回 ErrShortcutNotFound，实际: %v", err)
	}
}
