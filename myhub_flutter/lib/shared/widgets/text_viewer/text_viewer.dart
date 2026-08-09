import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

/// 纯文本查看页（与小说阅读界面区分开）。
///
/// * 面向"不支持预览的文件"经底部菜单"纯文本"入口打开；
/// * 使用应用常规主题（非阅读器独立背景/翻页模式），正文等宽字体可选中复制；
/// * 内容经 `GET /api/files/text` 加载，超限截断时顶部提示"仅预览前 2MB"；
/// * 提供"复制全文"快捷操作。
class PlainTextViewerPage extends ConsumerStatefulWidget {
  const PlainTextViewerPage({
    super.key,
    required this.sourceId,
    required this.file,
  });

  /// 文件所属路径源 ID。
  final int sourceId;

  /// 查看的文件。
  final FileItem file;

  /// 以独立路由打开纯文本查看页。
  static Future<void> open(
    BuildContext context, {
    required int sourceId,
    required FileItem file,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => PlainTextViewerPage(sourceId: sourceId, file: file),
      ),
    );
  }

  @override
  ConsumerState<PlainTextViewerPage> createState() =>
      _PlainTextViewerPageState();
}

class _PlainTextViewerPageState extends ConsumerState<PlainTextViewerPage> {
  bool _loading = true;
  String? _error;
  String _content = '';
  bool _truncated = false;
  int _size = 0;

  @override
  void initState() {
    super.initState();
    // 文本查看页为沉浸阅读：进入时隐藏迷你播放器，避免遮挡正文
    ref.read(mediaPlayerProvider).pageOpened();
    _load();
  }

  @override
  void dispose() {
    // 退出查看页：媒体仍在播放时恢复迷你播放器
    ref.read(mediaPlayerProvider).pageClosed();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(fileApiProvider)
          .textPreview(widget.sourceId, widget.file.path);
      if (!mounted) return;
      setState(() {
        _content = res['content'] as String? ?? '';
        _truncated = res['truncated'] as bool? ?? false;
        _size = res['size'] as int? ?? widget.file.size;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制全文（${_content.length} 字符）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Flexible(
              child: Text(
                widget.file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '纯文本',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.copy, size: 18),
            tooltip: '复制全文',
            onPressed: _content.isEmpty ? null : _copyAll,
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_error != null) {
      return _TextViewerError(message: _error!, onRetry: _load);
    }
    if (_content.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.fileText,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              '文件内容为空',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (_truncated) _TruncatedBanner(size: _size),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: SelectableText(
              _content,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 截断提示条：文件超出预览上限时显示。
class _TruncatedBanner extends StatelessWidget {
  const _TruncatedBanner({required this.size});

  final int size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Icon(
              LucideIcons.info,
              size: 16,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '文件较大（${formatBytes(size)}），仅预览前 2MB 内容',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 加载失败视图：错误信息 + 重试。
class _TextViewerError extends StatelessWidget {
  const _TextViewerError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.fileWarning,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              '无法预览文本',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.rotateCw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
