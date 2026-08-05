import 'package:flutter/material.dart';

/// 新建文件夹弹窗。返回输入的名称，取消返回 null。
Future<String?> showMkdirDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _NameInputDialog(
      title: '新建文件夹',
      label: '文件夹名称',
    ),
  );
}

/// 重命名弹窗。返回新名称，取消返回 null。
Future<String?> showRenameDialog(BuildContext context, String currentName) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameInputDialog(
      title: '重命名',
      label: '新名称',
      initialValue: currentName,
    ),
  );
}

class _NameInputDialog extends StatefulWidget {
  const _NameInputDialog({
    required this.title,
    required this.label,
    this.initialValue,
  });

  final String title;
  final String label;
  final String? initialValue;

  @override
  State<_NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<_NameInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '名称不能为空');
      return;
    }
    if (name.contains('/') || name.contains('\\') || name == '.' || name == '..') {
      setState(() => _error = '名称不能包含路径分隔符');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: widget.label),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

/// 删除确认弹窗。返回 true 确认删除。
Future<bool?> showDeleteConfirmDialog(BuildContext context, int count) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除确认'),
      content: Text('选中的 $count 个项目将移入回收站，可在回收站中还原。'),
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
}
