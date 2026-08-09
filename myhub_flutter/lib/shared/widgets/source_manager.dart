import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/source.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';

/// 路径源管理组件（设置页嵌入）。
///
/// 列表展示：类型图标、名称、挂载点、启用开关；
/// 行操作：连接测试、编辑、删除（确认弹窗）；
/// 底部"添加路径源"按钮打开编辑弹窗。
class SourceManager extends ConsumerWidget {
  const SourceManager({super.key, this.showAddButton = true});

  /// 是否显示底部"添加路径源"按钮（设置页卡片已有右上角按钮时传 false）。
  final bool showAddButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sourcesAsync = ref.watch(sourceListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sourcesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: (err, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '加载失败：$err',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => ref
                          .read(sourceListProvider.notifier)
                          .refresh(),
                      icon: const Icon(LucideIcons.rotateCw, size: 14),
                      label: const Text('重试'),
                    ),
                    if (showAddButton)
                      TextButton.icon(
                        onPressed: () => SourceEditDialog.show(context),
                        icon: const Icon(LucideIcons.plus, size: 14),
                        label: const Text('添加路径源'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          data: (sources) {
            if (sources.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '尚未配置路径源',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < sources.length; i++) ...[
                  if (i > 0) const Divider(height: 20),
                  _SourceRow(source: sources[i]),
                ],
              ],
            );
          },
        ),
        if (showAddButton) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => SourceEditDialog.show(context),
              icon: const Icon(LucideIcons.plus, size: 14),
              label: const Text('添加路径源'),
            ),
          ),
        ],
      ],
    );
  }
}

class _SourceRow extends ConsumerWidget {
  const _SourceRow({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final testOk = ref.watch(sourceTestStatusProvider)[source.id];
    final subtitle = source.type == SourceType.webdav
        ? _webdavHost(source.configJson)
        : source.mountPoint;

    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            source.type == SourceType.webdav
                ? LucideIcons.cloud
                : LucideIcons.hardDrive,
            size: 15,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      source.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (testOk != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: testOk ? Colors.green : colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          iconSize: 15,
          tooltip: '连接测试',
          visualDensity: VisualDensity.compact,
          icon: Icon(LucideIcons.plug, color: colorScheme.onSurfaceVariant),
          onPressed: () => _test(context, ref),
        ),
        IconButton(
          iconSize: 15,
          tooltip: '编辑',
          visualDensity: VisualDensity.compact,
          icon: Icon(LucideIcons.pencil, color: colorScheme.onSurfaceVariant),
          onPressed: () => SourceEditDialog.show(context, existing: source),
        ),
        IconButton(
          iconSize: 15,
          tooltip: '删除',
          visualDensity: VisualDensity.compact,
          icon: Icon(LucideIcons.trash2, color: colorScheme.error),
          onPressed: () => _confirmDelete(context, ref),
        ),
        Switch.adaptive(
          value: source.enabled,
          onChanged: (v) =>
              ref.read(sourceListProvider.notifier).toggle(source, v),
        ),
      ],
    );
  }

  String _webdavHost(String configJson) {
    try {
      final cfg = jsonDecode(configJson) as Map<String, dynamic>;
      final url = cfg['url'] as String? ?? '';
      return source.mountPoint.isEmpty ? url : '$url${source.mountPoint}';
    } catch (_) {
      return source.mountPoint;
    }
  }

  Future<void> _test(BuildContext context, WidgetRef ref) async {
    final result =
        await ref.read(sourceListProvider.notifier).testConnection(source.id);
    if (!context.mounted) return;
    final String message;
    if (!result.ok) {
      message = '连接失败：${result.error}';
    } else if (result.network == 'lan') {
      message = '连接成功（内网）';
    } else if (result.network == 'wan') {
      message = '连接成功（外网）';
    } else {
      message = '连接正常';
    }
    showTopSnackBar(context, message);
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除路径源'),
        content: Text('确定删除「${source.name}」吗？该操作不会影响源中的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(sourceListProvider.notifier).remove(source.id);
    }
  }
}

/// 添加/编辑路径源弹窗。
class SourceEditDialog extends ConsumerStatefulWidget {
  const SourceEditDialog({this.existing, super.key});

  final Source? existing;

  static Future<void> show(BuildContext context, {Source? existing}) {
    return showDialog<void>(
      context: context,
      builder: (_) => SourceEditDialog(existing: existing),
    );
  }

  @override
  ConsumerState<SourceEditDialog> createState() => _SourceEditDialogState();
}

class _SourceEditDialogState extends ConsumerState<SourceEditDialog> {
  final _nameController = TextEditingController();
  final _mountController = TextEditingController();
  final _urlController = TextEditingController();
  final _lanUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  SourceType _type = SourceType.local;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s != null) {
      _nameController.text = s.name;
      _type = s.type == SourceType.openlist ? SourceType.local : s.type;
      _mountController.text = s.mountPoint;
      if (s.type == SourceType.webdav) {
        try {
          final cfg = jsonDecode(s.configJson) as Map<String, dynamic>;
          _urlController.text = cfg['url'] as String? ?? '';
          _lanUrlController.text = cfg['lan_url'] as String? ?? '';
          _usernameController.text = cfg['username'] as String? ?? '';
          _passwordController.text = cfg['password'] as String? ?? '';
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mountController.dispose();
    _urlController.dispose();
    _lanUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final form = SourceFormData(
      name: _nameController.text.trim(),
      type: _type,
      mountPoint: _mountController.text.trim(),
      webdavUrl: _urlController.text.trim(),
      webdavLanUrl: _lanUrlController.text.trim(),
      webdavUsername: _usernameController.text.trim(),
      webdavPassword: _passwordController.text,
      enabled: widget.existing?.enabled ?? true,
    );
    if (form.name.isEmpty) {
      setState(() => _error = '请输入名称');
      return;
    }
    if (_type == SourceType.local && form.mountPoint.isEmpty) {
      setState(() => _error = '请输入本地目录路径');
      return;
    }
    if (_type == SourceType.webdav && form.webdavUrl.isEmpty) {
      setState(() => _error = '请输入 WebDAV 地址');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final notifier = ref.read(sourceListProvider.notifier);
      if (_isEdit) {
        await notifier.edit(widget.existing!.id, form);
      } else {
        await notifier.add(form);
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑路径源' : '添加路径源'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SourceType>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: '类型'),
              items: const [
                DropdownMenuItem(
                  value: SourceType.local,
                  child: Text('本地目录'),
                ),
                DropdownMenuItem(
                  value: SourceType.webdav,
                  child: Text('WebDAV'),
                ),
              ],
              onChanged: (v) => setState(() => _type = v ?? SourceType.local),
            ),
            const SizedBox(height: 12),
            if (_type == SourceType.webdav) ...[
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'https://nas.example.com:5006',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lanUrlController,
                decoration: const InputDecoration(
                  labelText: '内网地址（可选）',
                  hintText: 'http://192.168.1.10:5006',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _mountController,
                decoration: const InputDecoration(
                  labelText: '挂载路径（可选）',
                  hintText: '/media',
                ),
              ),
            ] else
              TextField(
                controller: _mountController,
                decoration: const InputDecoration(
                  labelText: '本地目录',
                  hintText: r'D:\Media 或 /mnt/media',
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
