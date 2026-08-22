import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/feed_api.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:myhub_flutter/features/feed/providers/feed_provider.dart';
import 'package:myhub_flutter/features/feed/widgets/feed_card.dart' show PlatformBadge;
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';

/// 订阅源管理（底部抽屉）：添加 / 删除订阅源。
class SubscriptionsSheet extends ConsumerStatefulWidget {
  const SubscriptionsSheet({super.key});

  @override
  ConsumerState<SubscriptionsSheet> createState() => _SubscriptionsSheetState();
}

class _SubscriptionsSheetState extends ConsumerState<SubscriptionsSheet> {
  final _platformCtrl = TextEditingController();
  final _targetCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  static const _platforms = [
    ('bilibili', '哔哩哔哩'),
    ('youtube', 'YouTube'),
    ('douyin', '抖音'),
  ];

  @override
  void dispose() {
    _platformCtrl.dispose();
    _targetCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(feedSubscriptionsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '订阅源管理',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(LucideIcons.x, size: 16),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            Flexible(
              child: async.when(
                loading: () => const SizedBox(
                  height: 120,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                error: (err, _) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '加载失败：$err',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '暂无订阅源，请在下方添加',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final s = list[index];
                      return _SubscriptionTile(
                        sub: s,
                        onDelete: () => _delete(s),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 24),
            Text(
              '添加订阅源',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _buildAddForm(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildAddForm(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _platformCtrl.text.isEmpty ? 'bilibili' : _platformCtrl.text,
          decoration: const InputDecoration(
            labelText: '平台',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: _platforms
              .map(
                (p) => DropdownMenuItem(
                  value: p.$1,
                  child: Text(p.$2),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) _platformCtrl.text = v;
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _targetCtrl,
          decoration: const InputDecoration(
            labelText: '目标（UP主 UID / 频道 ID / 用户名）',
            hintText: '如 UP主 UID、YouTube 频道 ID',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: '名称（可选）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _add,
          child: const Text('添加'),
        ),
      ],
    );
  }

  Future<void> _add() async {
    final platform = _platformCtrl.text.trim();
    final target = _targetCtrl.text.trim();
    if (platform.isEmpty || target.isEmpty) {
      showTopSnackBar(context, '请填写平台与目标');
      return;
    }
    final api = ref.read(feedApiProvider);
    try {
      await api.addSubscription(platform, target, name: _nameCtrl.text.trim());
      _targetCtrl.clear();
      _nameCtrl.clear();
      ref.invalidate(feedSubscriptionsProvider);
      if (mounted) showTopSnackBar(context, '已添加订阅源');
    } catch (e) {
      if (mounted) showTopSnackBar(context, '添加失败：$e');
    }
  }

  Future<void> _delete(FeedSubscription s) async {
    final api = ref.read(feedApiProvider);
    try {
      await api.removeSubscription(s.id);
      ref.invalidate(feedSubscriptionsProvider);
      if (mounted) showTopSnackBar(context, '已删除订阅源');
    } catch (e) {
      if (mounted) showTopSnackBar(context, '删除失败：$e');
    }
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({required this.sub, required this.onDelete});

  final FeedSubscription sub;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: PlatformBadge(platform: sub.platform),
      title: Text(
        sub.name.isNotEmpty ? sub.name : sub.target,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: sub.name.isNotEmpty
          ? Text(
              sub.target,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            )
          : null,
      trailing: IconButton(
        icon: const Icon(LucideIcons.trash2, size: 16),
        onPressed: onDelete,
        tooltip: '删除订阅源',
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
