import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';

/// 移动/复制目标目录选择器（BottomSheet 文件树）。
/// 返回选中的目标目录路径，取消返回 null。
class MoveTargetPicker extends ConsumerStatefulWidget {
  const MoveTargetPicker({required this.title, super.key});

  final String title;

  static Future<String?> show(BuildContext context, {required String title}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => MoveTargetPicker(title: title),
    );
  }

  @override
  ConsumerState<MoveTargetPicker> createState() => _MoveTargetPickerState();
}

class _MoveTargetPickerState extends ConsumerState<MoveTargetPicker> {
  String _currentDir = '/';
  List<String> _dirs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('/');
  }

  Future<void> _load(String dir) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = ref.read(effectiveSourceProvider);
      if (source == null) {
        setState(() {
          _dirs = [];
          _loading = false;
        });
        return;
      }
      final raw = await ref.read(fileApiProvider).listFiles(source.id, dir);
      final dirs = raw
          .map((e) => e as Map<String, dynamic>)
          .where((e) => e['is_dir'] == true)
          .map((e) => e['path'] as String)
          .toList();
      setState(() {
        _currentDir = dir;
        _dirs = dirs;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String get _parentDir {
    if (_currentDir == '/') return '/';
    final trimmed = _currentDir.substring(0, _currentDir.lastIndexOf('/'));
    return trimmed.isEmpty ? '/' : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // 当前位置 + 返回上级
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(LucideIcons.arrowUp, size: 16),
                    onPressed:
                        _currentDir == '/' ? null : () => _load(_parentDir),
                    tooltip: '返回上级',
                  ),
                  Expanded(
                    child: Text(
                      _currentDir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 8),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _error != null
                      ? Center(
                          child: Text(
                            '加载失败：$_error',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        )
                      : _dirs.isEmpty
                          ? Center(
                              child: Text(
                                '此目录下没有子文件夹',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _dirs.length,
                              itemBuilder: (context, index) {
                                final dir = _dirs[index];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    LucideIcons.folder,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                  title: Text(
                                    dir.split('/').last,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  onTap: () => _load(dir),
                                );
                              },
                            ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(_currentDir),
                icon: const Icon(LucideIcons.check, size: 15),
                label: Text('选择此目录 $_currentDir'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
