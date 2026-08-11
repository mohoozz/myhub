import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/core/settings/settings_provider.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/features/auth/providers/auth_provider.dart';
import 'package:myhub_flutter/features/auth/widgets/change_password_dialog.dart';
import 'package:myhub_flutter/features/settings/providers/app_config_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/utils/app_cache.dart';
import 'package:myhub_flutter/shared/utils/format.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';
import 'package:myhub_flutter/shared/widgets/avatar_button.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_settings.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/reader_settings.dart';
import 'package:myhub_flutter/shared/widgets/source_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 设置页：分组卡片列表。
///
/// 持久化策略：
/// * 阅读/漫画/播放/主题偏好 → SharedPreferences（各 provider 自行落盘）；
/// * 回收站保留天数、动态聚合 → `PUT /api/config`（见 [appConfigProvider]）。
///
/// 布局：窄屏单列堆叠；宽屏（>=1080，平板/桌面）左侧导航 + 右侧内容双栏。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// 宽屏断点（左侧导航 + 右侧内容）。
  static const double _twoPaneWidth = 1080;

  int _selected = 0;

  static const List<({String title, IconData icon, Widget child})> _sections =
      [
    (title: '服务器', icon: LucideIcons.server, child: _ServerSection()),
    (title: '账号安全', icon: LucideIcons.shieldCheck, child: _AccountSection()),
    (title: '外观', icon: LucideIcons.sunMoon, child: _AppearanceSection()),
    (title: '路径源管理', icon: LucideIcons.folderCog, child: _SourcesSection()),
    (title: '阅读偏好', icon: LucideIcons.bookOpen, child: _ReaderSection()),
    (title: '播放设置', icon: LucideIcons.play, child: _PlayerSection()),
    (title: '回收站', icon: LucideIcons.trash2, child: _TrashSection()),
    (title: '动态聚合', icon: LucideIcons.zap, child: _FeedSection()),
    (title: '存储', icon: LucideIcons.database, child: _StorageSection()),
    (title: '关于', icon: LucideIcons.info, child: _AboutSection()),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _twoPaneWidth;
    return Scaffold(
      body: SafeArea(
        child: wide ? _buildTwoPane(context) : _buildSinglePane(context),
      ),
    );
  }

  /// 窄屏：全部分组单列堆叠。
  Widget _buildSinglePane(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(7, 8, 7, 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部用户卡片：替代原 AppBar 上的头像入口，
              // 点击跳转个人主页（设置/查看头像）。
              const _ProfileHeader(),
              const SizedBox(height: 24),
              for (final section in _sections) ...[
                section.child,
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 宽屏（平板/桌面）：左侧分组导航 + 右侧内容。
  Widget _buildTwoPane(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 200,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < _sections.length; i++)
                      _NavItem(
                        icon: _sections[i].icon,
                        title: _sections[i].title,
                        selected: i == _selected,
                        onTap: () => setState(() => _selected = i),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: SingleChildScrollView(
                  child: _sections[_selected].child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 窄屏设置页顶部"我的"卡片：
/// 替代原 AppBar 右上角头像框，点击跳转到个人主页设置头像。
class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authStateProvider);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/profile'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const UserAvatar(radius: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      auth.username ?? '未登录',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '点击编辑头像与资料',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                color: theme.colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 双栏布局左侧的分组导航项。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        dense: true,
        leading: Icon(
          icon,
          size: 16,
          color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
        title: Text(
          title,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color:
                selected ? colorScheme.primary : colorScheme.onSurface,
          ),
        ),
        selected: selected,
        selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: onTap,
      ),
    );
  }
}

/// 保存服务端配置（失败弹提示，状态自动回滚）。
Future<void> _saveConfig(
  BuildContext context,
  WidgetRef ref,
  String key,
  String value,
) async {
  try {
    await ref.read(appConfigProvider.notifier).setValue(key, value);
  } catch (e) {
    if (!context.mounted) return;
    showTopSnackBar(context, '保存失败：$e');
  }
}

// ---------------------------------------------------------------------------
// 服务器
// ---------------------------------------------------------------------------

/// 服务器地址配置：外网/内网双地址，客户端自动判断使用哪一路；保存后切换生效。
class _ServerSection extends ConsumerWidget {
  const _ServerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(serverConfigProvider);

    Future<void> edit() async {
      final wanController = TextEditingController(text: config.wanUrl);
      final lanController = TextEditingController(text: config.lanUrl);
      final saved = await showDialog<({String wan, String lan})>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('服务器配置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '请输入服务器主机地址（含协议与端口），外网必填，内网可选：',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: wanController,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '外网地址',
                  hintText: 'http://example.com:8080',
                  prefixIcon: Icon(LucideIcons.server),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: lanController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '内网地址（可选）',
                  hintText: 'http://192.168.1.100:8080',
                  prefixIcon: Icon(LucideIcons.home),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                (wan: wanController.text, lan: lanController.text),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      wanController.dispose();
      lanController.dispose();
      if (saved == null || saved.wan.trim().isEmpty) return;
      await ref.read(serverConfigProvider.notifier).setUrls(
        wanUrl: saved.wan,
        lanUrl: saved.lan,
      );
      // 保存后立即自动判断内网/外网
      await ref.read(serverConfigProvider.notifier).autoDetect();
      if (context.mounted) showTopSnackBar(context, '服务器配置已更新');
    }

    Future<void> test() async {
      final result =
          await ref.read(serverConfigProvider.notifier).testConnection();
      if (context.mounted) showTopSnackBar(context, result.message);
    }

    return _SectionCard(
      title: '服务器',
      children: [
        _ActionRow(
          icon: LucideIcons.server,
          label: '外网地址',
          trailing: Text(
            config.wanUrl,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: edit,
        ),
        const Divider(height: 24),
        _ActionRow(
          icon: LucideIcons.home,
          label: '内网地址',
          trailing: Text(
            config.hasLanUrl ? config.lanUrl : '未配置',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: edit,
        ),
        const Divider(height: 24),
        _ActionRow(
          icon: LucideIcons.plug,
          label: '测试连接',
          trailing: Text(
            config.activeNetwork == 'lan' ? '当前：内网' : '当前：外网',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: test,
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '配置了内网地址时，客户端将优先连接内网，内网不可用再退回外网。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 账号安全
// ---------------------------------------------------------------------------

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _SectionCard(
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
            final changed = await ChangePasswordDialog.show(context);
            if ((changed ?? false) && context.mounted) {
              showTopSnackBar(context, '密码修改成功');
            }
          },
        ),
        const Divider(height: 24),
        _ActionRow(
          icon: LucideIcons.logOut,
          label: '退出登录',
          onTap: () => _confirmLogout(context, ref),
        ),
      ],
    );
  }

  /// 确认后退出登录（清除本地 Token，路由守卫自动跳回登录页）。
  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authProvider).logout();
    }
  }
}

// ---------------------------------------------------------------------------
// 外观（Flutter 专属）
// ---------------------------------------------------------------------------

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(themeModeProvider);
    final notifier = ref.read(themeModeProvider.notifier);
    final nameLines = ref.watch(fileNameLinesProvider);
    return _SectionCard(
      title: '外观',
      children: [
        // 三态分段选择：跟随系统 / 亮色 / 暗色。
        // 三个选项始终可见，避免"开关关掉才能看到固定方向"的二段式交互。
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              label: Text('跟随系统'),
              icon: Icon(LucideIcons.sunMoon, size: 15),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text('亮色'),
              icon: Icon(LucideIcons.sun, size: 15),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text('暗色'),
              icon: Icon(LucideIcons.moon, size: 15),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (s) => notifier.setMode(s.first),
        ),
        const Divider(height: 24),
        // 文件名/标题显示行数：影响浏览页与阅读页的卡片、列表。
        // 1~3 行，多行时卡片高度自适应，避免长文件名显示不全。
        _StepperRow(
          label: '文件名行数',
          value: nameLines,
          min: FileNameLinesNotifier.minLines,
          max: FileNameLinesNotifier.maxLines,
          suffix: '行',
          onChanged: (v) => ref.read(fileNameLinesProvider.notifier).set(v),
        ),
        const SizedBox(height: 8),
        Text(
          '文件/标题过长时按设定行数换行显示（浏览页与阅读页的卡片、列表均生效）。',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 路径源管理
// ---------------------------------------------------------------------------

class _SourcesSection extends StatelessWidget {
  const _SourcesSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
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
    );
  }
}

// ---------------------------------------------------------------------------
// 阅读偏好（小说 + 漫画）
// ---------------------------------------------------------------------------

class _ReaderSection extends ConsumerWidget {
  const _ReaderSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reader = ref.watch(readerSettingsProvider);
    final readerNotifier = ref.read(readerSettingsProvider.notifier);
    final comic = ref.watch(comicReaderSettingsProvider);
    final comicNotifier = ref.read(comicReaderSettingsProvider.notifier);

    return _SectionCard(
      title: '阅读偏好',
      children: [
        _SliderRow(
          label: '默认字号',
          value: reader.fontSize,
          min: ReaderSettings.minFontSize,
          max: ReaderSettings.maxFontSize,
          divisions: 24, // 0.5 步进
          display: '${reader.fontSize.toStringAsFixed(1)}px',
          onChanged: (v) => readerNotifier.setFontSize(v, persist: false),
          onChangeEnd: readerNotifier.setFontSize,
        ),
        _SliderRow(
          label: '默认行距',
          value: reader.lineHeight,
          min: ReaderSettings.minLineHeight,
          max: ReaderSettings.maxLineHeight,
          divisions: 13, // 0.1 步进
          display: reader.lineHeight.toStringAsFixed(1),
          onChanged: (v) => readerNotifier.setLineHeight(v, persist: false),
          onChangeEnd: readerNotifier.setLineHeight,
        ),
        _DropdownRow<ReaderTheme>(
          label: '阅读主题',
          value: reader.theme,
          options: [
            for (final t in ReaderTheme.values) (t, t.label),
          ],
          onChanged: readerNotifier.setTheme,
        ),
        _DropdownRow<ReaderMode>(
          label: '翻页模式',
          value: reader.mode,
          options: const [
            (ReaderMode.page, '翻页'),
            (ReaderMode.scroll, '滚动'),
          ],
          onChanged: readerNotifier.setMode,
        ),
        _DropdownRow<String>(
          label: '漫画模式',
          value: comic.viewMode?.name ?? 'auto',
          options: const [
            ('auto', '自动（横屏双页）'),
            ('single', '单页'),
            ('double', '双页'),
            ('webtoon', '条漫'),
          ],
          onChanged: (v) => comicNotifier.setViewMode(
            v == 'auto' ? null : ComicViewMode.values.asNameMap()[v],
          ),
        ),
        _DropdownRow<ComicReadingDirection>(
          label: '漫画方向',
          value: comic.effectiveDirection,
          options: const [
            (ComicReadingDirection.rtl, '从右向左（日漫）'),
            (ComicReadingDirection.ltr, '从左向右'),
          ],
          onChanged: comicNotifier.setDirection,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 播放设置
// ---------------------------------------------------------------------------

class _PlayerSection extends ConsumerWidget {
  const _PlayerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(playerSettingsProvider);
    final notifier = ref.read(playerSettingsProvider.notifier);
    return _SectionCard(
      title: '播放设置',
      children: [
        _DropdownRow<double>(
          label: '默认倍速',
          value: settings.defaultSpeed,
          options: [
            for (final s in kPlaybackSpeeds) (s, playbackSpeedLabel(s)),
          ],
          onChanged: (v) =>
              notifier.update(settings.copyWith(defaultSpeed: v)),
        ),
        _DropdownRow<bool>(
          label: '转码偏好',
          value: settings.preferTranscode,
          options: const [
            (false, '直通优先（原画零损耗）'),
            (true, '转码优先（HLS 兼容性好）'),
          ],
          onChanged: (v) =>
              notifier.update(settings.copyWith(preferTranscode: v)),
        ),
        _ActionRow(
          icon: LucideIcons.compass,
          label: '自动水平仪（视频随设备旋转）',
          trailing: Switch.adaptive(
            value: settings.orientation == PlayerOrientation.sensor,
            onChanged: (v) => notifier.update(
              settings.copyWith(
                orientation: v
                    ? PlayerOrientation.sensor
                    : PlayerOrientation.portrait,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 回收站
// ---------------------------------------------------------------------------

class _TrashSection extends ConsumerWidget {
  const _TrashSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = int.tryParse(
          ref
              .watch(appConfigProvider)
              .valueOrNull?[AppConfigKeys.trashRetentionDays] ??
              '',
        ) ??
        30;
    return _SectionCard(
      title: '回收站',
      children: [
        _StepperRow(
          label: '保留天数',
          value: days.clamp(1, 90),
          min: 1,
          max: 90,
          suffix: '天后自动清理',
          onChanged: (v) => _saveConfig(
            context,
            ref,
            AppConfigKeys.trashRetentionDays,
            '$v',
          ),
        ),
        const Divider(height: 24),
        _ActionRow(
          icon: LucideIcons.trash2,
          label: '查看回收站',
          onTap: () => context.push('/trash'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 动态聚合（M5 消费，配置先行持久化）
// ---------------------------------------------------------------------------

class _FeedSection extends ConsumerWidget {
  const _FeedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(appConfigProvider).valueOrNull ?? const {};
    final keep = int.tryParse(config[AppConfigKeys.feedKeepCount] ?? '') ?? 200;
    final interval = config[AppConfigKeys.feedFetchIntervalMin] ?? '60';

    return _SectionCard(
      title: '动态聚合',
      children: [
        _DropdownRow<String>(
          label: '抓取频率',
          value: interval,
          options: const [
            ('15', '每 15 分钟'),
            ('30', '每 30 分钟'),
            ('60', '每 1 小时'),
            ('360', '每 6 小时'),
            ('720', '每 12 小时'),
          ],
          onChanged: (v) =>
              _saveConfig(context, ref, AppConfigKeys.feedFetchIntervalMin, v),
        ),
        _StepperRow(
          label: '保留条数',
          value: keep.clamp(50, 1000),
          min: 50,
          max: 1000,
          step: 50,
          onChanged: (v) => _saveConfig(
            context,
            ref,
            AppConfigKeys.feedKeepCount,
            '$v',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '平台账号在添加订阅时通过浏览器 profile 扫码登录获取，无需在此配置。',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 存储（Flutter 专属：离线缓存管理）
// ---------------------------------------------------------------------------

class _StorageSection extends StatelessWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context) {
    return const _SectionCard(
      title: '存储',
      children: [_CacheRow()],
    );
  }
}

class _CacheRow extends StatefulWidget {
  const _CacheRow();

  @override
  State<_CacheRow> createState() => _CacheRowState();
}

class _CacheRowState extends State<_CacheRow> {
  int? _size;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final size = await AppCache.size();
    if (mounted) setState(() => _size = size);
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    try {
      await AppCache.clear();
      await _load();
      if (mounted) {
        showTopSnackBar(context, '缓存已清理');
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Icon(LucideIcons.database, size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '图片缓存',
              style: (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    )
                  : theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
            ),
          ),
          Text(
            _size == null ? '统计中…' : formatBytes(_size!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _clearing ? null : _clear,
            child: Text(_clearing ? '清理中…' : '清理'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 关于（Flutter 专属）
// ---------------------------------------------------------------------------

final _packageInfoFuture = PackageInfo.fromPlatform();

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      title: '关于',
      children: [
        _ActionRow(
          icon: LucideIcons.info,
          label: '版本',
          trailing: FutureBuilder<PackageInfo>(
            future: _packageInfoFuture,
            builder: (context, snapshot) => Text(
              snapshot.hasData ? 'v${snapshot.data!.version}' : '…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const Divider(height: 24),
        _ActionRow(
          icon: LucideIcons.fileText,
          label: '开源许可',
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'myhub',
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 通用行组件
// ---------------------------------------------------------------------------

/// 分组卡片：标题 + 可选头部操作 + 内容行。
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

/// 简单操作行（图标 + 标签 + 可选尾部）。
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
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // 移动端放大行标签：参考"正在阅读"列表（bodyMedium + w600），
    // 避免 iOS 设置项文字偏小。
    final labelStyle = isMobile
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
        : theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500);
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
              child: Text(label, style: labelStyle),
            ),
            ?trailing,
            if (onTap != null && trailing == null)
              Icon(
                LucideIcons.chevronRight,
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
    this.divisions,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final labelStyle = isMobile
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)
        : theme.textTheme.bodySmall;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: labelStyle),
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
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
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

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;

  /// (值, 显示文案) 列表。
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final labelStyle = isMobile
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)
        : theme.textTheme.bodySmall;
    final itemStyle = isMobile
        ? theme.textTheme.bodyMedium
        : theme.textTheme.bodySmall;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: labelStyle),
          ),
          Expanded(
            child: SizedBox(
              height: 36,
              child: DropdownButtonFormField<T>(
                initialValue: value,
                items: [
                  for (final (v, label) in options)
                    DropdownMenuItem(
                      value: v,
                      child: Text(label, style: itemStyle),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 12),
                ),
                style: itemStyle,
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
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final labelStyle = isMobile
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)
        : theme.textTheme.bodySmall;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: labelStyle),
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
