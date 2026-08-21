import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/utils/browser_support.dart';
import 'package:myhub_flutter/features/browser/bookmarks_page.dart';
import 'package:myhub_flutter/features/browser/browser_provider.dart';
import 'package:myhub_flutter/features/browser/browser_settings.dart';
import 'package:myhub_flutter/features/browser/history_page.dart';
import 'package:myhub_flutter/features/browser/widgets/address_bar.dart';
import 'package:myhub_flutter/features/browser/widgets/browser_view.dart';
import 'package:myhub_flutter/features/browser/widgets/tab_manager_sheet.dart';
import 'package:myhub_flutter/features/browser/widgets/tab_strip.dart';

/// 浏览器页主界面（F-601）：地址栏 + 导航控制 + WebView 区。
///
/// 13.3 完成：地址栏智能输入、导航控制（后退/前进/刷新/停止）、
/// 加载进度条、页面标题 + favicon、错误页、`target=_blank` 新标签、
/// iOS 侧滑返回、PC 键盘快捷键、下载链接拦截（转系统浏览器）、
/// 历史节流上报（无痕标签跳过）。
///
/// 13.4 完成：PC Chrome 风格标签条、iOS 标签管理页（卡片网格）、
/// 标签会话切页签不销毁（IndexedStack keepAlive）、右键/长按关闭其他/全部。
class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  /// 每个标签独立的 WebView 控制器（key: tab.id）。
  final Map<int, InAppWebViewController> _controllers = {};

  final FocusNode _addressFocus = FocusNode();

  // 激活标签的运行时视图状态
  String _url = '';
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _loading = false;
  int _progress = 0;

  /// iOS 标签管理页是否展开。
  bool _showTabManager = false;

  @override
  void dispose() {
    _addressFocus.dispose();
    _controllers.clear();
    super.dispose();
  }

  // ---------- 导航命令 ----------

  void _goBack() => _controller?.goBack();

  void _goForward() => _controller?.goForward();

  void _stop() => _controller?.stopLoading();

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    // 起始页为 Flutter 原生 widget，无 WebView 可刷新
    if (_url.isEmpty) return;
    await controller.reload();
  }

  InAppWebViewController? get _controller {
    final tab = ref.read(activeBrowserTabProvider);
    if (tab == null) return null;
    return _controllers[tab.id];
  }

  // ---------- 地址栏提交 ----------

  void _onAddressSubmit(String input) {
    final settings = ref.read(browserSettingsProvider);
    final url = resolveNavigationUrl(
      input,
      searchUrlTemplate: settings.searchUrlTemplate,
    );
    if (url.isEmpty) return;
    final tab = ref.read(activeBrowserTabProvider);
    if (tab == null) return;
    ref
        .read(browserTabsProvider.notifier)
        .update(tab.id, (t) => t.copyWith(url: url));
    _addressFocus.unfocus();
  }

  // ---------- 新标签 ----------

  void _newTab({bool incognito = false}) {
    ref.read(browserTabsProvider.notifier).newTab(incognito: incognito);
    setState(() {
      _url = '';
      _canGoBack = false;
      _canGoForward = false;
      _loading = false;
      _progress = 0;
    });
    // 新标签聚焦地址栏
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addressFocus.requestFocus();
    });
  }

  void _closeTab(int id) {
    ref.read(browserTabsProvider.notifier).closeTab(id);
    _controllers.remove(id);
    // 关闭后同步视图状态到新的激活标签
    _syncStateFromActiveTab();
  }

  /// 切换当前激活标签的无痕模式（PC 菜单入口）。
  void _toggleIncognito() {
    final tab = ref.read(activeBrowserTabProvider);
    if (tab == null) return;
    ref
        .read(browserTabsProvider.notifier)
        .update(tab.id, (t) => t.copyWith(incognito: !t.incognito));
  }

  /// 从当前激活标签的持久状态同步 UI 字段（标签切换/关闭后调用）。
  void _syncStateFromActiveTab() {
    final tab = ref.read(activeBrowserTabProvider);
    if (!mounted) return;
    setState(() {
      _url = tab?.url ?? '';
      _canGoBack = false;
      _canGoForward = false;
      _loading = tab?.loading ?? false;
      _progress = 0;
    });
    // 异步查询该标签的导航栈状态（WebView 已存活，controller 应已就绪）
    final controller = tab == null ? null : _controllers[tab.id];
    if (controller != null) {
      _queryNavState(controller);
    }
  }

  Future<void> _queryNavState(InAppWebViewController controller) async {
    final canBack = await controller.canGoBack();
    final canForward = await controller.canGoForward();
    if (!mounted) return;
    // 仅当查询结果属于当前激活标签时才更新
    final active = ref.read(activeBrowserTabProvider);
    if (active != null && _controllers[active.id] == controller) {
      setState(() {
        _canGoBack = canBack;
        _canGoForward = canForward;
      });
    }
  }

  // ---------- 历史上报 ----------

  void _reportHistory(BrowserTabState tab, String url, String title) {
    if (tab.incognito) return; // 无痕跳过
    if (url.isEmpty || url == 'about:blank') return;
    ref
        .read(historyReporterProvider)
        .report(
          url: url,
          title: title.isEmpty ? (Uri.tryParse(url)?.host ?? '') : title,
          favicon: tab.faviconUrl,
        );
  }

  // ---------- 键盘快捷键（PC） ----------

  Map<ShortcutActivator, VoidCallback> _shortcuts() {
    if (!Platform.isWindows) return const {};
    return {
      const SingleActivator(LogicalKeyboardKey.keyT, control: true): _newTab,
      const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
        final tab = ref.read(activeBrowserTabProvider);
        if (tab != null) _closeTab(tab.id);
      },
      const SingleActivator(LogicalKeyboardKey.keyL, control: true):
          _addressFocus.requestFocus,
      const SingleActivator(LogicalKeyboardKey.keyR, control: true): _reload,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _goBack,
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
          _goForward,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!browserSupported) {
      return const _BrowserUnavailable();
    }
    // iOS 标签管理页（全屏覆盖）
    if (_showTabManager && Platform.isIOS) {
      return TabManagerSheet(
        onClose: () {
          setState(() => _showTabManager = false);
          // 管理页内可能已切换激活标签，关闭后同步顶栏状态
          _syncStateFromActiveTab();
        },
      );
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tabs = ref.watch(browserTabsProvider);
    final activeIndex = ref.watch(activeBrowserTabIndexProvider);
    final activeTab = (activeIndex >= 0 && activeIndex < tabs.length)
        ? tabs[activeIndex]
        : null;

    // 激活标签切换时，同步顶栏地址栏 / 导航状态
    ref.listen(activeBrowserTabIndexProvider, (prev, next) {
      if (prev != next) _syncStateFromActiveTab();
    });

    final body = Scaffold(
      body: Column(
        children: [
          // PC：Chrome 风格标签条
          if (Platform.isWindows) _buildTabStrip(tabs, activeTab),
          _buildTopBar(theme, colorScheme),
          // 地址栏下方 2px 蓝色加载进度条
          SizedBox(
            height: 2,
            child: _progress > 0 && _progress < 100
                ? LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      colorScheme.primary,
                    ),
                  )
                : null,
          ),
          // WebView 区（IndexedStack 保持所有标签存活）
          Expanded(
            child: tabs.isEmpty
                ? const SizedBox.shrink()
                : _buildWebViewStack(tabs, activeIndex),
          ),
        ],
      ),
    );

    // PC 键盘快捷键
    if (Platform.isWindows) {
      return CallbackShortcuts(
        bindings: _shortcuts(),
        child: Focus(autofocus: true, child: body),
      );
    }
    return body;
  }

  /// PC 标签条。
  Widget _buildTabStrip(List<BrowserTabState> tabs, BrowserTabState? active) {
    return TabStrip(
      tabs: tabs,
      activeId: active?.id ?? -1,
      onSelect: (id) {
        ref.read(browserTabsProvider.notifier).activate(id);
        _syncStateFromActiveTab();
      },
      onClose: _closeTab,
      onNew: _newTab,
      onCloseOthers: (id) {
        ref.read(browserTabsProvider.notifier).closeOthers(id);
        _syncStateFromActiveTab();
      },
      onCloseAll: () {
        ref.read(browserTabsProvider.notifier).closeAll();
        _syncStateFromActiveTab();
      },
    );
  }

  /// WebView 区：IndexedStack 承载所有标签，切页签不销毁。
  Widget _buildWebViewStack(List<BrowserTabState> tabs, int activeIndex) {
    return IndexedStack(
      index: activeIndex,
      children: [for (final tab in tabs) _buildWebView(tab)],
    );
  }

  Widget _buildWebView(BrowserTabState tab) {
    return BrowserView(
      key: ValueKey(tab.id),
      url: tab.url,
      keepAlive: true,
      userAgent: ref.read(browserSettingsProvider).userAgentString,
      onWebViewCreated: (controller) => _controllers[tab.id] = controller,
      callbacks: _BrowserCallbacksAdapter(
        onUrlChangedCb: (url) {
          // 仅激活标签同步顶栏地址栏
          if (_isActive(tab.id)) setState(() => _url = url);
          ref
              .read(browserTabsProvider.notifier)
              .update(tab.id, (t) => t.copyWith(url: url));
        },
        onTitleChangedCb: (title) {
          ref
              .read(browserTabsProvider.notifier)
              .update(tab.id, (t) => t.copyWith(title: title));
        },
        onFaviconChangedCb: (favicon) {
          ref
              .read(browserTabsProvider.notifier)
              .update(tab.id, (t) => t.copyWith(faviconUrl: favicon));
        },
        onProgressChangedCb: (progress) {
          if (_isActive(tab.id)) {
            setState(() {
              _progress = progress;
              _loading = progress > 0 && progress < 100;
            });
          }
          ref
              .read(browserTabsProvider.notifier)
              .update(
                tab.id,
                (t) => t.copyWith(loading: progress > 0 && progress < 100),
              );
        },
        onNavStateChangedCb: ({required canGoBack, required canGoForward}) {
          if (_isActive(tab.id)) {
            setState(() {
              _canGoBack = canGoBack;
              _canGoForward = canGoForward;
            });
          }
        },
        onCreateWindowRequestCb: (url) {
          // target=_blank / window.open → 新标签打开
          if (url.isNotEmpty) {
            final newTab = ref.read(browserTabsProvider.notifier).newTab();
            ref
                .read(browserTabsProvider.notifier)
                .update(newTab.id, (t) => t.copyWith(url: url));
            _syncStateFromActiveTab();
          } else {
            _newTab();
          }
        },
        onErrorCb: (url, message) {
          // 错误页已由 BrowserView 内部展示；此处仅记录。
        },
        onPageFinishedCb: (url) {
          // 页面加载完成节流上报历史（无痕标签由 _reportHistory 内部跳过）
          _reportHistory(tab, url, tab.title);
        },
        onNavigateRequestCb: (url) {
          // 起始页请求导航（搜索 / 快捷入口）→ 更新标签 URL 触发加载
          ref
              .read(browserTabsProvider.notifier)
              .update(tab.id, (t) => t.copyWith(url: url));
          if (_isActive(tab.id)) setState(() => _url = url);
        },
      ),
    );
  }

  /// 判断指定 id 是否为当前激活标签。
  bool _isActive(int id) => ref.read(activeBrowserTabProvider)?.id == id;

  /// 顶栏：导航按钮（后退/前进/刷新/停止）+ 地址栏 + 新标签按钮。
  Widget _buildTopBar(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        border: Border(bottom: BorderSide(color: colorScheme.outline)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            onPressed: _canGoBack ? _goBack : null,
            icon: const Icon(LucideIcons.arrowLeft),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: '后退',
          ),
          IconButton(
            onPressed: _canGoForward ? _goForward : null,
            icon: const Icon(LucideIcons.arrowRight),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: '前进',
          ),
          IconButton(
            onPressed: _loading ? _stop : _reload,
            icon: Icon(
              _loading ? LucideIcons.x : LucideIcons.rotateCw,
              size: 18,
            ),
            visualDensity: VisualDensity.compact,
            tooltip: _loading ? '停止' : '刷新',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AddressBar(
              url: _url,
              focusNode: _addressFocus,
              onSubmit: _onAddressSubmit,
            ),
          ),
          const SizedBox(width: 4),
          // 星标：一键收藏 / 取消（已收藏高亮）
          _BookmarkToggleButton(url: _url),
          const SizedBox(width: 4),
          // iOS：标签管理入口（Safari 风格）
          if (Platform.isIOS)
            _TabCountButton(
              count: ref.watch(browserTabsProvider).length,
              onPressed: () => setState(() => _showTabManager = true),
            ),
          // 菜单：书签 / 历史 / 无痕（PC + iOS 通用入口）
          _BrowserMenuButton(
            incognito: ref.watch(activeBrowserTabProvider)?.incognito ?? false,
            onIncognitoToggle: _toggleIncognito,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// 将 BrowserView 的事件转发为 BrowserScreen 所需回调（含标签上下文）。
///
/// 字段以 `_cb` 后缀命名，避免与 [BrowserViewCallbacks] 接口方法同名冲突。
class _BrowserCallbacksAdapter implements BrowserViewCallbacks {
  _BrowserCallbacksAdapter({
    required this.onUrlChangedCb,
    required this.onTitleChangedCb,
    required this.onFaviconChangedCb,
    required this.onProgressChangedCb,
    required this.onNavStateChangedCb,
    required this.onCreateWindowRequestCb,
    required this.onErrorCb,
    required this.onPageFinishedCb,
    required this.onNavigateRequestCb,
  });

  final void Function(String) onUrlChangedCb;
  final void Function(String) onTitleChangedCb;
  final void Function(String) onFaviconChangedCb;
  final void Function(int) onProgressChangedCb;
  final void Function({required bool canGoBack, required bool canGoForward})
  onNavStateChangedCb;
  final void Function(String) onCreateWindowRequestCb;
  final void Function(String, String) onErrorCb;
  final void Function(String) onPageFinishedCb;
  final void Function(String) onNavigateRequestCb;

  @override
  void onUrlChanged(String url) => onUrlChangedCb(url);

  @override
  void onTitleChanged(String title) => onTitleChangedCb(title);

  @override
  void onFaviconChanged(String faviconUrl) => onFaviconChangedCb(faviconUrl);

  @override
  void onProgressChanged(int progress) => onProgressChangedCb(progress);

  @override
  void onNavStateChanged({
    required bool canGoBack,
    required bool canGoForward,
  }) {
    onNavStateChangedCb(canGoBack: canGoBack, canGoForward: canGoForward);
  }

  @override
  void onCreateWindowRequest(String url) => onCreateWindowRequestCb(url);

  @override
  void onError(String url, String message) => onErrorCb(url, message);

  @override
  void onPageFinished(String url) => onPageFinishedCb(url);

  @override
  void onNavigateRequest(String url) => onNavigateRequestCb(url);
}

/// iOS 标签数按钮：点击打开标签管理页（Safari 风格）。
class _TabCountButton extends StatelessWidget {
  const _TabCountButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(LucideIcons.layers, size: 18),
          Positioned(
            top: 1,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              constraints: const BoxConstraints(minWidth: 13),
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ],
      ),
      visualDensity: VisualDensity.compact,
      tooltip: '标签页',
    );
  }
}

/// 地址栏星标：一键收藏 / 取消（已收藏高亮实心星）。
class _BookmarkToggleButton extends ConsumerWidget {
  const _BookmarkToggleButton({required this.url});

  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final bookmarksAsync = ref.watch(bookmarksProvider);

    // 起始页无 URL 时禁用
    if (url.isEmpty) {
      return const IconButton(
        onPressed: null,
        icon: Icon(LucideIcons.star),
        iconSize: 18,
        visualDensity: VisualDensity.compact,
      );
    }

    final isBookmarked = bookmarksAsync.maybeWhen(
      data: (items) => items.any((b) => b.url == url),
      orElse: () => false,
    );

    return IconButton(
      onPressed: () => _toggle(ref),
      icon: Icon(
        isBookmarked ? LucideIcons.star : LucideIcons.star,
        size: 18,
        color: isBookmarked
            ? colorScheme.primary
            : colorScheme.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
      tooltip: isBookmarked ? '取消收藏' : '收藏此页',
    );
  }

  Future<void> _toggle(WidgetRef ref) async {
    final bookmarksAsync = ref.read(bookmarksProvider);
    final items = bookmarksAsync.valueOrNull ?? const <BookmarkItem>[];
    final existing = items.where((b) => b.url == url).firstOrNull;
    final notifier = ref.read(bookmarksNotifierProvider.notifier);
    if (existing != null) {
      await notifier.remove(existing.id);
    } else {
      final tab = ref.read(activeBrowserTabProvider);
      final title = tab?.title ?? '';
      await notifier.add(title, url, favicon: tab?.faviconUrl ?? '');
    }
  }
}

/// PC 菜单入口：书签 / 历史 / 无痕开关。
class _BrowserMenuButton extends ConsumerWidget {
  const _BrowserMenuButton({
    required this.incognito,
    required this.onIncognitoToggle,
  });

  final bool incognito;
  final VoidCallback onIncognitoToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(LucideIcons.menu, size: 18),
      tooltip: '菜单',
      onSelected: (value) {
        switch (value) {
          case 'bookmarks':
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BookmarksPage()),
            );
          case 'history':
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HistoryPage()),
            );
          case 'incognito':
            onIncognitoToggle();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'bookmarks', child: Text('书签')),
        const PopupMenuItem(value: 'history', child: Text('历史记录')),
        PopupMenuItem(
          value: 'incognito',
          child: Row(
            children: [
              const Text('无痕模式'),
              const Spacer(),
              if (incognito)
                Icon(
                  LucideIcons.check,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// WebView 不可用平台占位（正常情况下路由已降级，不会到达）。
class _BrowserUnavailable extends StatelessWidget {
  const _BrowserUnavailable();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.globe,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '当前平台不支持内置浏览器',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
