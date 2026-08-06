import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/data/database/app_database.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/reader_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderSettingsNotifier（小说阅读器）', () {
    test('默认值', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final s = container.read(readerSettingsProvider);
      expect(s.fontSize, 16);
      expect(s.lineHeight, 1.6);
      expect(s.theme, ReaderTheme.day);
      expect(s.mode, ReaderMode.page);
    });

    test('更新并持久化 + 恢复', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(readerSettingsProvider.notifier);
      notifier.setFontSize(20);
      notifier.setTheme(ReaderTheme.night);
      notifier.setMode(ReaderMode.scroll);
      // setFontSize/setTheme/setMode 内部异步落盘，等待完成
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('reader_font_size'), 20);
      expect(prefs.getString('reader_theme'), 'night');
      expect(prefs.getString('reader_mode'), 'scroll');

      // 新容器恢复
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      container2.read(readerSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final restored = container2.read(readerSettingsProvider);
      expect(restored.fontSize, 20);
      expect(restored.theme, ReaderTheme.night);
      expect(restored.mode, ReaderMode.scroll);
    });
  });

  group('ComicReaderSettingsNotifier', () {
    test('默认方向 RTL，修改后持久化 + 恢复', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(comicReaderSettingsProvider).effectiveDirection,
        ComicReadingDirection.rtl,
      );

      await container
          .read(comicReaderSettingsProvider.notifier)
          .setDirection(ComicReadingDirection.ltr);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('comic.direction'), 'ltr');

      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      container2.read(comicReaderSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        container2.read(comicReaderSettingsProvider).effectiveDirection,
        ComicReadingDirection.ltr,
      );
    });
  });

  group('PlayerSettingsNotifier', () {
    test('倍速更新并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(playerSettingsProvider.notifier).update(
            const PlayerSettings(defaultSpeed: 1.5, preferTranscode: true),
          );
      expect(container.read(playerSettingsProvider).defaultSpeed, 1.5);
      expect(container.read(playerSettingsProvider).preferTranscode, isTrue);
    });
  });

  group('AppDatabase（内存）', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    LocalProgressCompanion entry({
      int sourceId = 1,
      String path = '/a.txt',
      double percent = 30,
    }) {
      return LocalProgressCompanion(
        sourceId: Value(sourceId),
        filePath: Value(path),
        mediaType: const Value('novel'),
        percent: Value(percent),
        updatedAt: Value(DateTime.now()),
      );
    }

    test('upsert 进度（同键覆盖）', () async {
      await db.upsertProgress(entry());
      await db.upsertProgress(entry(percent: 60));

      final all = await db.allProgress();
      expect(all, hasLength(1));
      expect(all.single.percent, 60);
    });

    test('未同步标记流转', () async {
      await db.upsertProgress(entry());
      final unsynced = await db.unsyncedProgress();
      expect(unsynced, hasLength(1));

      await db.markProgressSynced(unsynced.single.id);
      expect(await db.unsyncedProgress(), isEmpty);
    });

    test('单条查询', () async {
      await db.upsertProgress(entry(path: '/book.txt'));
      final p = await db.getProgress(1, '/book.txt');
      expect(p, isNotNull);
      expect(p!.mediaType, 'novel');
      expect(await db.getProgress(1, '/ghost.txt'), isNull);
    });

    test('下载任务生命周期', () async {
      final id = await db.enqueueDownload(
        DownloadTaskCompanion(
          sourceId: const Value(1),
          filePath: const Value('/v/movie.mp4'),
          totalBytes: const Value(1000),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );

      final pending = await db.downloadsByStatus('pending');
      expect(pending, hasLength(1));
      expect(pending.single.status, 'pending');

      await db.updateDownloadStatus(id, 'downloading');
      await db.updateDownloadProgress(id, 500);
      final task = (await db.allDownloads()).single;
      expect(task.status, 'downloading');
      expect(task.downloadedBytes, 500);

      await db.updateDownloadStatus(id, 'completed');
      expect(await db.downloadsByStatus('completed'), hasLength(1));

      await db.deleteDownload(id);
      expect(await db.allDownloads(), isEmpty);
    });
  });
}
