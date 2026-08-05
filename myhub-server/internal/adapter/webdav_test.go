package adapter

import (
	"context"
	"errors"
	"io"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/net/webdav"
)

// setupWebDav 基于 x/net/webdav 的内存文件系统启动测试 WebDAV 服务
func setupWebDav(t *testing.T) *WebDavAdapter {
	t.Helper()
	handler := &webdav.Handler{
		Prefix:     "/dav",
		FileSystem: webdav.NewMemFS(),
		LockSystem: webdav.NewMemLS(),
	}
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)

	a, err := NewWebDavAdapter(&WebDavConfig{URL: srv.URL + "/dav"}, "/")
	if err != nil {
		t.Fatalf("NewWebDavAdapter 失败: %v", err)
	}
	return a
}

func TestWebDavAdapter_Test(t *testing.T) {
	a := setupWebDav(t)
	if err := a.Test(context.Background()); err != nil {
		t.Fatalf("Test 应通过: %v", err)
	}
}

func TestWebDavAdapter_WriteReadListStat(t *testing.T) {
	a := setupWebDav(t)
	ctx := context.Background()

	content := "hello webdav"
	if err := a.WriteStream(ctx, "/docs/a.txt", strings.NewReader(content), int64(len(content))); err != nil {
		t.Fatalf("WriteStream 失败: %v", err)
	}

	fi, err := a.Stat(ctx, "/docs/a.txt")
	if err != nil {
		t.Fatalf("Stat 失败: %v", err)
	}
	if fi.Name != "a.txt" || fi.Size != int64(len(content)) || fi.IsDir {
		t.Fatalf("Stat 结果不符: %+v", fi)
	}

	list, err := a.List(ctx, "/")
	if err != nil {
		t.Fatalf("List 失败: %v", err)
	}
	if len(list) != 1 || list[0].Name != "docs" || !list[0].IsDir {
		t.Fatalf("List 结果不符: %+v", list)
	}

	// 全文读取
	rc, err := a.ReadStream(ctx, "/docs/a.txt", 0, -1)
	if err != nil {
		t.Fatalf("ReadStream 失败: %v", err)
	}
	data, _ := io.ReadAll(rc)
	_ = rc.Close()
	if string(data) != content {
		t.Fatalf("读取内容不符: %q", data)
	}

	// Range 读取：offset=6, length=6 → "webdav"
	rc, err = a.ReadStream(ctx, "/docs/a.txt", 6, 6)
	if err != nil {
		t.Fatalf("ReadStream Range 失败: %v", err)
	}
	data, _ = io.ReadAll(rc)
	_ = rc.Close()
	if string(data) != "webdav" {
		t.Fatalf("Range 读取内容不符: %q", data)
	}
}

func TestWebDavAdapter_MoveCopyMkdir(t *testing.T) {
	a := setupWebDav(t)
	ctx := context.Background()

	if err := a.Mkdir(ctx, "/dir/sub"); err != nil {
		t.Fatalf("Mkdir 失败: %v", err)
	}
	if err := a.WriteStream(ctx, "/dir/f.txt", strings.NewReader("x"), 1); err != nil {
		t.Fatal(err)
	}

	if err := a.Move(ctx, "/dir/f.txt", "/dir/sub/f2.txt"); err != nil {
		t.Fatalf("Move 失败: %v", err)
	}
	if _, err := a.Stat(ctx, "/dir/f.txt"); !errors.Is(err, ErrNotExist) {
		t.Fatalf("Move 后源应不存在: %v", err)
	}

	if err := a.Copy(ctx, "/dir/sub/f2.txt", "/dir/f3.txt"); err != nil {
		t.Fatalf("Copy 失败: %v", err)
	}
	fi, err := a.Stat(ctx, "/dir/f3.txt")
	if err != nil || fi.Size != 1 {
		t.Fatalf("Copy 结果不符: %+v, err=%v", fi, err)
	}
}

func TestWebDavAdapter_DeleteRestore(t *testing.T) {
	a := setupWebDav(t)
	ctx := context.Background()

	if err := a.WriteStream(ctx, "/v/movie.mp4", strings.NewReader("fake-video"), 10); err != nil {
		t.Fatal(err)
	}

	trashPath, err := a.Delete(ctx, "/v/movie.mp4")
	if err != nil {
		t.Fatalf("Delete 失败: %v", err)
	}
	if !strings.HasPrefix(trashPath, "/"+TrashDirName+"/") {
		t.Fatalf("回收站路径前缀不符: %q", trashPath)
	}
	if _, err := a.Stat(ctx, "/v/movie.mp4"); !errors.Is(err, ErrNotExist) {
		t.Fatalf("删除后原路径应不存在: %v", err)
	}

	if err := a.Restore(ctx, trashPath, "/v/movie.mp4"); err != nil {
		t.Fatalf("Restore 失败: %v", err)
	}
	fi, err := a.Stat(ctx, "/v/movie.mp4")
	if err != nil || fi.Size != 10 {
		t.Fatalf("Restore 结果不符: %+v, err=%v", fi, err)
	}
}

func TestWebDavAdapter_DirTraversal(t *testing.T) {
	a := setupWebDav(t)
	if _, err := a.Stat(context.Background(), "/../../etc/passwd"); !errors.Is(err, ErrForbidden) && !errors.Is(err, ErrNotExist) {
		t.Fatalf("意外错误: %v", err)
	}
}

func TestWebDavAdapter_DeleteRootForbidden(t *testing.T) {
	a := setupWebDav(t)
	if _, err := a.Delete(context.Background(), "/"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("删除根应返回 ErrForbidden，得到: %v", err)
	}
}
