package adapter

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setupLocal(t *testing.T) (*LocalAdapter, string) {
	t.Helper()
	root := t.TempDir()
	a, err := NewLocalAdapter(root, nil)
	if err != nil {
		t.Fatalf("NewLocalAdapter 失败: %v", err)
	}
	return a, root
}

func TestLocalAdapter_Test(t *testing.T) {
	a, _ := setupLocal(t)
	if err := a.Test(context.Background()); err != nil {
		t.Fatalf("Test 应通过: %v", err)
	}

	if _, err := NewLocalAdapter(filepath.Join(t.TempDir(), "not-exist"), nil); err != nil {
		t.Fatalf("构造不校验存在性: %v", err)
	}
	a2, _ := NewLocalAdapter(filepath.Join(t.TempDir(), "not-exist"), nil)
	if err := a2.Test(context.Background()); !errors.Is(err, ErrNotExist) {
		t.Fatalf("不存在路径应返回 ErrNotExist，得到: %v", err)
	}
}

func TestLocalAdapter_Whitelist(t *testing.T) {
	allowed := t.TempDir()
	inside := filepath.Join(allowed, "media")
	if err := os.MkdirAll(inside, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()

	if _, err := NewLocalAdapter(inside, []string{allowed}); err != nil {
		t.Fatalf("白名单内路径应通过: %v", err)
	}
	if _, err := NewLocalAdapter(allowed, []string{allowed}); err != nil {
		t.Fatalf("等于白名单根应通过: %v", err)
	}
	if _, err := NewLocalAdapter(outside, []string{allowed}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("白名单外路径应返回 ErrForbidden，得到: %v", err)
	}
}

func TestLocalAdapter_DirTraversal(t *testing.T) {
	a, _ := setupLocal(t)
	ctx := context.Background()

	for _, p := range []string{"../escape", "/../../etc/passwd", "a/../../b", "..\\windows"} {
		if _, err := a.Stat(ctx, p); !errors.Is(err, ErrForbidden) && !errors.Is(err, ErrNotExist) {
			// "../escape" 经清洗后落在根内应为 ErrNotExist；
			// 试图跳出根的必须为 ErrForbidden
			if strings.Contains(p, "..") && errors.Is(err, ErrForbidden) {
				continue
			}
			t.Fatalf("路径 %q 返回意外错误: %v", p, err)
		}
	}

	// 确认 "../../etc/passwd" 确实被拦截（清洗后仍跳出根）
	_, err := a.Stat(ctx, "/../../etc/passwd")
	// Clean("//../../etc/passwd") = "/etc/passwd"，实际落在根内 → ErrNotExist
	if !errors.Is(err, ErrNotExist) && !errors.Is(err, ErrForbidden) {
		t.Fatalf("意外错误: %v", err)
	}
}

func TestLocalAdapter_WriteReadListStat(t *testing.T) {
	a, root := setupLocal(t)
	ctx := context.Background()

	content := []byte("hello myhub")
	if err := a.WriteStream(ctx, "/docs/a.txt", strings.NewReader(string(content)), int64(len(content))); err != nil {
		t.Fatalf("WriteStream 失败: %v", err)
	}

	// Stat
	fi, err := a.Stat(ctx, "/docs/a.txt")
	if err != nil {
		t.Fatalf("Stat 失败: %v", err)
	}
	if fi.Name != "a.txt" || fi.Size != int64(len(content)) || fi.IsDir {
		t.Fatalf("Stat 结果不符: %+v", fi)
	}

	// List（根目录应含 docs）
	list, err := a.List(ctx, "/")
	if err != nil {
		t.Fatalf("List 失败: %v", err)
	}
	if len(list) != 1 || list[0].Name != "docs" || !list[0].IsDir {
		t.Fatalf("List 结果不符: %+v", list)
	}

	// ReadStream 全文
	rc, err := a.ReadStream(ctx, "/docs/a.txt", 0, -1)
	if err != nil {
		t.Fatalf("ReadStream 失败: %v", err)
	}
	data, _ := io.ReadAll(rc)
	_ = rc.Close()
	if string(data) != string(content) {
		t.Fatalf("读取内容不符: %q", data)
	}

	// ReadStream Range：offset=6, length=5 → "myhub"
	rc, err = a.ReadStream(ctx, "/docs/a.txt", 6, 5)
	if err != nil {
		t.Fatalf("ReadStream Range 失败: %v", err)
	}
	data, _ = io.ReadAll(rc)
	_ = rc.Close()
	if string(data) != "myhub" {
		t.Fatalf("Range 读取内容不符: %q", data)
	}

	// 确认物理文件落在根目录内
	if _, err := os.Stat(filepath.Join(root, "docs", "a.txt")); err != nil {
		t.Fatalf("物理文件不存在: %v", err)
	}
}

func TestLocalAdapter_MoveCopyMkdir(t *testing.T) {
	a, _ := setupLocal(t)
	ctx := context.Background()

	if err := a.Mkdir(ctx, "/dir/sub"); err != nil {
		t.Fatalf("Mkdir 失败: %v", err)
	}
	if err := a.WriteStream(ctx, "/dir/f.txt", strings.NewReader("x"), 1); err != nil {
		t.Fatal(err)
	}

	// Move
	if err := a.Move(ctx, "/dir/f.txt", "/dir/sub/f2.txt"); err != nil {
		t.Fatalf("Move 失败: %v", err)
	}
	if _, err := a.Stat(ctx, "/dir/f.txt"); !errors.Is(err, ErrNotExist) {
		t.Fatalf("Move 后源应不存在: %v", err)
	}

	// Copy 目录（递归）
	if err := a.Copy(ctx, "/dir/sub", "/dir/sub_copy"); err != nil {
		t.Fatalf("Copy 失败: %v", err)
	}
	fi, err := a.Stat(ctx, "/dir/sub_copy/f2.txt")
	if err != nil || fi.Size != 1 {
		t.Fatalf("Copy 结果不符: %+v, err=%v", fi, err)
	}
}

func TestLocalAdapter_DeleteRestore(t *testing.T) {
	a, root := setupLocal(t)
	ctx := context.Background()

	if err := a.WriteStream(ctx, "/v/movie.mp4", strings.NewReader("fake-video"), 10); err != nil {
		t.Fatal(err)
	}

	// Delete → 移入回收站
	trashPath, err := a.Delete(ctx, "/v/movie.mp4")
	if err != nil {
		t.Fatalf("Delete 失败: %v", err)
	}
	if !strings.HasPrefix(trashPath, "/"+TrashDirName+"/") {
		t.Fatalf("回收站路径前缀不符: %q", trashPath)
	}
	if _, err := os.Stat(filepath.Join(root, TrashDirName, filepath.Base(trashPath))); err != nil {
		t.Fatalf("回收站内文件不存在: %v", err)
	}
	// 回收站目录不出现在列表中
	list, _ := a.List(ctx, "/")
	for _, fi := range list {
		if fi.Name == TrashDirName {
			t.Fatal("List 不应暴露 .trash 目录")
		}
	}

	// Restore → 还原到原路径
	if err := a.Restore(ctx, trashPath, "/v/movie.mp4"); err != nil {
		t.Fatalf("Restore 失败: %v", err)
	}
	fi, err := a.Stat(ctx, "/v/movie.mp4")
	if err != nil || fi.Size != 10 {
		t.Fatalf("Restore 结果不符: %+v, err=%v", fi, err)
	}

	// 还原目标已存在时应报错
	trashPath2, _ := a.Delete(ctx, "/v/movie.mp4")
	if err := a.WriteStream(ctx, "/v/movie.mp4", strings.NewReader("other"), 5); err != nil {
		t.Fatal(err)
	}
	if err := a.Restore(ctx, trashPath2, "/v/movie.mp4"); err == nil {
		t.Fatal("还原目标已存在时应报错")
	}
}

func TestLocalAdapter_DeleteRootForbidden(t *testing.T) {
	a, _ := setupLocal(t)
	if _, err := a.Delete(context.Background(), "/"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("删除根目录应返回 ErrForbidden，得到: %v", err)
	}
}
