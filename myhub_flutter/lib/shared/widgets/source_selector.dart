import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/models/source.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';

/// 路径源选择器（浏览页顶部）：横向排列的标签组，
/// 选中项蓝色高亮，超出宽度时横向滑动。
class SourceSelector extends ConsumerWidget {
  const SourceSelector({super.key, this.onChanged});

  /// 切换路径源后的回调（如重置面包屑）。
  final ValueChanged<Source>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sourcesAsync = ref.watch(sourceListProvider);
    final current = ref.watch(effectiveSourceProvider);

    return sourcesAsync.when(
      loading: () => _pill(theme, '加载中…', selected: true),
      error: (_, __) => _pill(theme, '路径源加载失败', selected: true),
      data: (sources) {
        if (sources.isEmpty) {
          return _pill(theme, '未配置路径源', selected: true);
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in sources) ...[
                GestureDetector(
                  onTap: () {
                    ref.read(currentSourceProvider.notifier).state = s;
                    onChanged?.call(s);
                  },
                  child: _pill(theme, s.name, selected: s.id == current?.id),
                ),
                if (s != sources.last) const SizedBox(width: 8),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _pill(ThemeData theme, String label, {required bool selected}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? theme.colorScheme.primary : theme.cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: selected
            ? null
            : Border.all(color: theme.colorScheme.outline, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : theme.colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}
