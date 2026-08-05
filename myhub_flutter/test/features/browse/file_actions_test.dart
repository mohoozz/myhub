import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/providers/file_actions.dart';

void main() {
  group('SelectionNotifier', () {
    test('长按进入 → 切换 → 全选 → 清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(selectionProvider.notifier);

      expect(container.read(selectionProvider), isEmpty);

      notifier.enter('/a.txt');
      expect(container.read(selectionProvider), {'/a.txt'});

      notifier.toggle('/b.txt');
      expect(container.read(selectionProvider), {'/a.txt', '/b.txt'});

      notifier.toggle('/a.txt'); // 取消选中
      expect(container.read(selectionProvider), {'/b.txt'});

      notifier.selectAll(const [
        FileItem(name: 'a', path: '/a'),
        FileItem(name: 'b', path: '/b'),
        FileItem(name: 'c', path: '/c'),
      ]);
      expect(container.read(selectionProvider), hasLength(3));

      notifier.clear();
      expect(container.read(selectionProvider), isEmpty);
    });
  });

  group('UploadTask', () {
    test('进度计算', () {
      const t = UploadTask(id: 1, name: 'a.zip', sent: 512, total: 1024);
      expect(t.progress, 0.5);
      const empty = UploadTask(id: 2, name: 'b.zip');
      expect(empty.progress, 0);
    });
  });

  group('UploadQueueNotifier', () {
    test('入队执行 → 完成状态', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(uploadQueueProvider.notifier);

      await notifier.enqueue('C:/a.txt', (task, onProgress) async {
        onProgress(50, 100);
        onProgress(100, 100);
      });

      final tasks = container.read(uploadQueueProvider);
      expect(tasks, hasLength(1));
      expect(tasks.single.name, 'a.txt');
      expect(tasks.single.status, UploadStatus.done);
      expect(tasks.single.progress, 1.0);
    });

    test('失败标记', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(uploadQueueProvider.notifier);

      await notifier.enqueue('/x/b.txt', (task, onProgress) async {
        throw Exception('network');
      });

      expect(
        container.read(uploadQueueProvider).single.status,
        UploadStatus.failed,
      );
    });

    test('clearFinished 保留上传中任务', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(uploadQueueProvider.notifier);

      await notifier.enqueue('/a.txt', (task, onProgress) async {});
      // 手动塞一个"上传中"任务
      // ignore: invalid_use_of_protected_member
      notifier.state = [
        ...notifier.state,
        const UploadTask(id: 999, name: 'slow.zip'),
      ];
      notifier.clearFinished();
      final rest = container.read(uploadQueueProvider);
      expect(rest, hasLength(1));
      expect(rest.single.status, UploadStatus.uploading);
    });
  });
}
