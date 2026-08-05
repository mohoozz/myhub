import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/features/auth/widgets/change_password_dialog.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/widgets/source_manager.dart';

/// Settings page — card-based sections matching the design spec.
///
/// TODO(api): persist values through the settings endpoint; the controls
/// below are local state only.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // 路径源

  // 阅读偏好
  double _fontSize = 16;
  double _lineHeight = 1.8;
  String _readerTheme = '日间';
  String _readMode = '条漫';
  String _fitMode = '适应宽度';

  // 播放设置
  String _speed = '1x';
  String _transcode = '原画（--copy 零损耗）';

  // 回收站
  int _retentionDays = 30;

  // 动态聚合
  int _feedKeep = 200;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionCard(
                    title: '账号安全',
                    children: [
                      _ActionRow(
                        icon: LucideIcons.userRound,
                        label: '当前账号',
                        trailing: Text(
                          ref.watch(authStateProvider).username ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const Divider(height: 24),
                      _ActionRow(
                        icon: LucideIcons.lock,
                        label: '修改密码',
                        onTap: () async {
                          final changed =
                              await ChangePasswordDialog.show(context);
                          if ((changed ?? false) && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('密码修改成功')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SectionCard(
                    title: '路径源管理',
                    trailing: FilledButton.icon(
                      onPressed: () => SourceEditDialog.show(context),
                      icon: const Icon(LucideIcons.plus, size: 15),
                      label: const Text('添加路径源'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        textStyle: theme.textTheme.bodySmall,
                      ),
                    ),
                    children: const [SourceManager(showAddButton: false)],
                  ),
                  const SizedBox(height: 16),
                  _SectionCard(
                    title: '阅读偏好',
                    children: [
                      _SliderRow(
                        label: '默认字号',
                        value: _fontSize,
                        min: 12,
                        max: 24,
                        display: '${_fontSize.round()}px',
                        onChanged: (v) => setState(() => _fontSize = v),
                      ),
                      _SliderRow(
                        label: '默认行距',
                        value: _lineHeight,
                        min: 1.2,
                        max: 2.4,
                        display: _lineHeight.toStringAsFixed(1),
                        onChanged: (v) => setState(() => _lineHeight = v),
                      ),
                      _DropdownRow(
                        label: '默认主题',
                        value: _readerTheme,
                        options: const ['日间', '夜间', '护眼'],
                        onChanged: (v) => setState(() => _readerTheme = v!),
                      ),
                      _DropdownRow(
                        label: '阅读模式',
                        value: _readMode,
                        options: const ['条漫', '翻页', '滚动'],
                        onChanged: (v) => setState(() => _readMode = v!),
                      ),
                      _DropdownRow(
                        label: '图像适配',
                        value: _fitMode,
                        options: const ['适应宽度', '适应高度', '原始尺寸'],
                        onChanged: (v) => setState(() => _fitMode = v!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SectionCard(
                    title: '播放设置',
                    children: [
                      _DropdownRow(
                        label: '默认倍速',
                        value: _speed,
                        options: const ['0.5x', '1x', '1.5x', '2x'],
                        onChanged: (v) => setState(() => _speed = v!),
                      ),
                      _DropdownRow(
                        label: '转码偏好',
                        value: _transcode,
                        options: const ['原画（--copy 零损耗）', 'HLS 均衡', '省流量'],
                        onChanged: (v) => setState(() => _transcode = v!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SectionCard(
                    title: '回收站',
                    children: [
                      _StepperRow(
                        label: '保留天数',
                        value: _retentionDays,
                        min: 1,
                        max: 90,
                        suffix: '天后自动清理',
                        onChanged: (v) => setState(() => _retentionDays = v),
                      ),
                      const Divider(height: 24),
                      InkWell(
                        onTap: () => context.push('/trash'),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.trash2,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '查看回收站',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Icon(
                                LucideIcons.chevronDown,
                                size: 15,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SectionCard(
                    title: '动态聚合',
                    children: [
                      _StepperRow(
                        label: '保留条数',
                        value: _feedKeep,
                        min: 50,
                        max: 1000,
                        step: 50,
                        onChanged: (v) => setState(() => _feedKeep = v),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '平台账号在添加订阅时通过浏览器 profile 扫码登录获取，无需在此配置。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// White rounded card with a section title and an optional trailing
/// action in the header row.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 简单操作行（图标 + 标签 + 可选尾部），与"查看回收站"行样式一致。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ?trailing,
            if (onTap != null && trailing == null)
              Icon(
                LucideIcons.chevronDown,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: SizedBox(
              height: 36,
              child: DropdownButtonFormField<String>(
                initialValue: value,
                items: [
                  for (final option in options)
                    DropdownMenuItem(
                      value: option,
                      child: Text(option, style: theme.textTheme.bodySmall),
                    ),
                ],
                onChanged: onChanged,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 12),
                ),
                style: theme.textTheme.bodySmall,
                icon: Icon(
                  LucideIcons.chevronDown,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.suffix,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final String? suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          _StepButton(
            icon: LucideIcons.minus,
            onTap: value > min ? () => onChanged(value - step) : null,
          ),
          SizedBox(
            width: 48,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _StepButton(
            icon: LucideIcons.plus,
            onTap: value < max ? () => onChanged(value + step) : null,
          ),
          if (suffix != null) ...[
            const SizedBox(width: 10),
            Text(
              suffix!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outline),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(
          icon,
          size: 13,
          color: onTap == null
              ? colorScheme.outline
              : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
