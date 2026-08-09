import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/features/browse/providers/file_actions.dart';

/// 上传进度 BottomSheet：多文件队列进度展示。
class UploadSheet extends ConsumerWidget {
  const UploadSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => const UploadSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tasks = ref.watch(uploadQueueProvider);
    final uploading =
        tasks.where((t) => t.status == UploadStatus.uploading).length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    uploading > 0 ? '正在上传（$uploading）' : '上传完成',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (uploading == 0 && tasks.isNotEmpty)
                  TextButton(
                    onPressed: () => ref
                        .read(uploadQueueProvider.notifier)
                        .clearFinished(),
                    child: const Text('清除记录'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                task.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _statusLabel(theme, task),
                          ],
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: task.status == UploadStatus.uploading
                              ? task.progress
                              : 1,
                          minHeight: 4,
                          backgroundColor:
                              theme.colorScheme.outlineVariant,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            task.status == UploadStatus.failed
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLabel(ThemeData theme, UploadTask task) {
    return switch (task.status) {
      UploadStatus.uploading => Text(
          '${(task.progress * 100).toStringAsFixed(0)}%',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      UploadStatus.done => Icon(
          LucideIcons.check,
          size: 14,
          color: theme.colorScheme.primary,
        ),
      UploadStatus.failed => Icon(
          LucideIcons.circleAlert,
          size: 14,
          color: theme.colorScheme.error,
        ),
    };
  }
}
