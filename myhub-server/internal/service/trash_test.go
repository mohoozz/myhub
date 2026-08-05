package service

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"myhub-server/internal/config"
	"myhub-server/internal/model"
	"myhub-server/internal/repository"
)

// setupTrashTest 构建基于临时目录与内存数据库的 TrashService
func setupTrashTest(t *testing.T) (*TrashService, *repository.TrashRepository, string, uint) {
	t.Helper()
	root := t.TempDir()

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&model.Source{}, &model.TrashItem{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}

	sourceRepo := repository.NewSourceRepository(db)
	sourceSvc := NewSourceService(&config.Config{}, sourceRepo)
	trashRepo := repository.NewTrashRepository(db)

	source := &model.Source{Name: "t", Type: model.SourceTypeLocal, MountPoint: root, Enabled: true}
	if err := sourceRepo.Create(source); err != nil {
		t.Fatalf("创建路径源失败: %v", err)
	}
	return NewTrashService(sourceSvc, trashRepo), trashRepo, root, source.ID
}

// makeExpiredTrashItem 制造一个已过期的回收站条目（物理文件 + 记录）
func makeExpiredTrashItem(t *testing.T, repo *repository.TrashRepository, root string, sourceID uint, name string, age time.Duration) *model.TrashItem {
	t.Helper()
	trashDir := filepath.Join(root, ".trash")
	if err := os.MkdirAll(trashDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trashDir, name), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	item := &model.TrashItem{
		SourceID:     sourceID,
		OriginalPath: "/" + name,
		TrashPath:    "/.trash/" + name,
		Size:         1,
		DeletedAt:    time.Now().Add(-age),
	}
	if err := repo.Create(item); err != nil {
		t.Fatal(err)
	}
	return item
}

func TestTrashService_CleanupExpired(t *testing.T) {
	svc, repo, root, sourceID := setupTrashTest(t)

	// 过期 40 天（应被清理）与未过期 10 天（应保留）
	expired := makeExpiredTrashItem(t, repo, root, sourceID, "old.txt", 40*24*time.Hour)
	fresh := makeExpiredTrashItem(t, repo, root, sourceID, "new.txt", 10*24*time.Hour)

	svc.CleanupExpired(context.Background(), 30)

	// 过期条目：物理文件与记录均应删除
	if _, err := os.Stat(filepath.Join(root, ".trash", "old.txt")); !os.IsNotExist(err) {
		t.Fatal("过期文件应被物理删除")
	}
	if _, err := repo.GetByID(expired.ID); err == nil {
		t.Fatal("过期记录应被删除")
	}

	// 未过期条目：应保留
	if _, err := os.Stat(filepath.Join(root, ".trash", "new.txt")); err != nil {
		t.Fatal("未过期文件应保留")
	}
	if _, err := repo.GetByID(fresh.ID); err != nil {
		t.Fatal("未过期记录应保留")
	}
}

func TestTrashService_CleanupExpired_MissingFile(t *testing.T) {
	svc, repo, root, sourceID := setupTrashTest(t)

	// 物理文件已被人工删除，仅残留记录 → 清理应只删记录不报错
	item := makeExpiredTrashItem(t, repo, root, sourceID, "gone.txt", 40*24*time.Hour)
	_ = os.Remove(filepath.Join(root, ".trash", "gone.txt"))

	svc.CleanupExpired(context.Background(), 30)

	if _, err := repo.GetByID(item.ID); err == nil {
		t.Fatal("物理文件缺失时记录也应被清理")
	}
}

func TestTrashService_RestorePurge(t *testing.T) {
	svc, repo, root, sourceID := setupTrashTest(t)
	ctx := context.Background()

	item := makeExpiredTrashItem(t, repo, root, sourceID, "a.txt", time.Hour)

	// 还原
	if err := svc.Restore(ctx, item.ID); err != nil {
		t.Fatalf("Restore 失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "a.txt")); err != nil {
		t.Fatal("还原后文件应回到原路径")
	}
	if _, err := repo.GetByID(item.ID); err == nil {
		t.Fatal("还原后记录应删除")
	}

	// 彻底删除
	item2 := makeExpiredTrashItem(t, repo, root, sourceID, "b.txt", time.Hour)
	if err := svc.Purge(ctx, item2.ID); err != nil {
		t.Fatalf("Purge 失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".trash", "b.txt")); !os.IsNotExist(err) {
		t.Fatal("Purge 后物理文件应删除")
	}

	// 不存在的条目
	if err := svc.Purge(ctx, 9999); err != ErrTrashItemNotFound {
		t.Fatalf("应返回 ErrTrashItemNotFound，得到: %v", err)
	}
}
