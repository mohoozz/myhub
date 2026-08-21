import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:myhub_flutter/features/browser/widgets/address_bar.dart'
    show resolveNavigationUrl;

/// 显示"添加 / 编辑快捷入口"对话框。
///
/// 用户输入标题 + URL，确认后回调 [onSave]（由调用方执行增删并刷新列表）。
/// [initialTitle] / [initialUrl] 非空时进入编辑模式。
Future<void> showShortcutDialog(
  BuildContext context, {
  required String title,
  String initialTitle = '',
  String initialUrl = '',
  required Future<void> Function(String title, String url) onSave,
}) {
  return _showUrlDialog(
    context,
    title: title,
    initialTitle: initialTitle,
    initialUrl: initialUrl,
    onSave: onSave,
    duplicateMessage: '该网址已存在快捷入口',
  );
}

/// 显示"添加 / 编辑书签"对话框（与快捷入口共用表单，重复提示不同）。
Future<void> showBookmarkDialog(
  BuildContext context, {
  required String title,
  String initialTitle = '',
  String initialUrl = '',
  required Future<void> Function(String title, String url) onSave,
}) {
  return _showUrlDialog(
    context,
    title: title,
    initialTitle: initialTitle,
    initialUrl: initialUrl,
    onSave: onSave,
    duplicateMessage: '该网址已存在书签',
  );
}

Future<void> _showUrlDialog(
  BuildContext context, {
  required String title,
  required String initialTitle,
  required String initialUrl,
  required Future<void> Function(String title, String url) onSave,
  required String duplicateMessage,
}) async {
  final titleCtrl = TextEditingController(text: initialTitle);
  final urlCtrl = TextEditingController(text: initialUrl);
  String? error;

  await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: initialTitle.isEmpty,
              decoration: const InputDecoration(
                labelText: '标题',
                hintText: '例如：GitHub',
                isDense: true,
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              autofocus: initialTitle.isNotEmpty,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: '网址',
                hintText: '例如：https://github.com',
                isDense: true,
                errorText: error,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(
                dialogContext,
                setState,
                titleCtrl,
                urlCtrl,
                onSave,
                duplicateMessage,
                (e) => error = e,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => _submit(
              dialogContext,
              setState,
              titleCtrl,
              urlCtrl,
              onSave,
              duplicateMessage,
              (e) => error = e,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );

  titleCtrl.dispose();
  urlCtrl.dispose();
}

Future<void> _submit(
  BuildContext dialogContext,
  StateSetter setState,
  TextEditingController titleCtrl,
  TextEditingController urlCtrl,
  Future<void> Function(String title, String url) onSave,
  String duplicateMessage,
  void Function(String?) setError,
) async {
  final rawUrl = urlCtrl.text.trim();
  final normalized = resolveNavigationUrl(rawUrl);

  // 校验：必须是有效 URL（非搜索词）
  final uri = Uri.tryParse(normalized);
  if (rawUrl.isEmpty || uri == null || uri.host.isEmpty) {
    setState(() => setError('请输入有效的网址'));
    return;
  }
  if (!_looksLikeUrl(rawUrl)) {
    // resolveNavigationUrl 将无点输入解析为搜索词，这里提示用户输入完整网址
    setState(() => setError('请输入完整网址（含域名）'));
    return;
  }

  final finalTitle = titleCtrl.text.trim().isEmpty
      ? uri.host
      : titleCtrl.text.trim();

  try {
    await onSave(finalTitle, normalized);
    if (dialogContext.mounted) {
      Navigator.pop(dialogContext, true);
    }
  } catch (e) {
    if (dialogContext.mounted) {
      setState(() => setError(_friendlyError(e, duplicateMessage)));
    }
  }
}

String _friendlyError(Object e, String duplicateMessage) {
  final msg = e.toString();
  if (msg.contains('409') || msg.contains('已存在')) {
    return duplicateMessage;
  }
  return '保存失败，请重试';
}

/// 判断输入是否"看起来像 URL"（含 scheme、含点无空格，或 localhost/IP）。
bool _looksLikeUrl(String raw) {
  if (raw.contains('://')) return true;
  final looksLikeHost = RegExp(
    r'^(localhost|(\d{1,3}\.){3}\d{1,3})(:\d+)?(/.*)?$',
    caseSensitive: false,
  ).hasMatch(raw);
  if (looksLikeHost) return true;
  return raw.contains('.') && !raw.contains(' ');
}

/// 显示"删除快捷入口"确认（供外部复用；当前由长按菜单直接删除）。
Future<bool> confirmDeleteShortcut(
  BuildContext context, {
  required String name,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(LucideIcons.trash2),
      title: const Text('删除快捷入口'),
      content: Text('确定删除「$name」吗？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return result == true;
}
