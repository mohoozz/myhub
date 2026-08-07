import 'package:flutter/material.dart';

/// 面包屑导航条：根（路径源名）+ 逐级目录，点击跳转到对应层级。
class BreadcrumbBar extends StatelessWidget {
  const BreadcrumbBar({
    required this.rootLabel,
    required this.path,
    required this.onNavigate,
    super.key,
  });

  /// 根标签（路径源名）。
  final String rootLabel;

  /// 当前路径（'/' 开头，如 /videos/movies）。
  final String path;

  /// 点击某级目录：参数为规范化后的目标路径（'/' 表示根）。
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments =
        path.split('/').where((s) => s.isNotEmpty).toList();

    final chips = <Widget>[
      _chip(
        context,
        segments.isEmpty ? '$rootLabel/' : rootLabel,
        '/',
        isLast: segments.isEmpty,
      ),
    ];
    for (var i = 0; i < segments.length; i++) {
      chips.add(_separator(theme));
      final target = '/${segments.sublist(0, i + 1).join('/')}';
      chips.add(
        _chip(context, segments[i], target, isLast: i == segments.length - 1),
      );
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }

  Widget _separator(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          '/',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );

  Widget _chip(
    BuildContext context,
    String label,
    String target, {
    required bool isLast,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isLast ? null : () => onNavigate(target),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
            color: isLast
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
