import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/utils/browser_support.dart';

/// 浏览器页主界面：顶栏（后退/前进/刷新 + 地址显示）+ WebView 区（M6 F-601）。
///
/// 13.2 阶段：单标签 + 内置起始页占位 + 基本导航控制；
/// 13.3 将补充地址栏智能输入、多标签管理、错误页与平台特定初始化
/// （Windows WebView2 userDataFolder / Runtime 缺失引导）。
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _controller;

  bool _canGoBack = false;
  bool _canGoForward = false;
  int _progress = 0;
  String _url = '';

  /// 内置起始页占位（13.5 将替换为完整起始页：搜索框 + 快捷入口网格）。
  /// CSS `prefers-color-scheme` 自动适配应用亮/暗主题。
  static const String _startPageHtml = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0;
    height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    font-family: system-ui, -apple-system, "Segoe UI",
      "PingFang SC", "Microsoft YaHei", sans-serif;
    background: #eef4fb;
    color: #1a1a2e;
  }
  h1 { margin: 0; font-size: 22px; font-weight: 600; }
  p { margin: 0; font-size: 14px; color: #6b7280; }
  @media (prefers-color-scheme: dark) {
    body { background: #000000; color: #e0e0e0; }
    p { color: #888888; }
  }
</style>
</head>
<body>
  <h1>myhub 浏览器</h1>
  <p>完整起始页即将上线：搜索框与快捷入口</p>
</body>
</html>
''';

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  /// 从 WebView 同步后退/前进可用状态（历史栈变化时调用）。
  Future<void> _refreshNavState() async {
    final controller = _controller;
    if (controller == null) return;
    final canBack = await controller.canGoBack();
    final canForward = await controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canBack;
      _canGoForward = canForward;
    });
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    // 起始页经 initialData 加载（about:blank），部分平台 reload() 无法
    // 重新渲染 data 页，此时改为重新 loadData。
    if (_url.isEmpty || _url == 'about:blank') {
      await controller.loadData(
        data: _startPageHtml,
        mimeType: 'text/html',
        encoding: 'utf-8',
      );
    } else {
      await controller.reload();
    }
  }

  /// 地址栏显示文案：起始页显示"新建标签页"，其余显示当前页域名
  /// （13.3 升级为安全图标 + 可编辑地址输入）。
  String get _addressLabel {
    final uri = Uri.tryParse(_url);
    if (_url.isEmpty ||
        _url == 'about:blank' ||
        uri == null ||
        uri.host.isEmpty) {
      return '新建标签页';
    }
    return uri.host;
  }

  @override
  Widget build(BuildContext context) {
    // 防御降级：WebView 不可用平台正常情况下无法到达本页
    // （路由层已将 /browser 重定向至 /browse）；直接构造时展示占位。
    if (!browserSupported) {
      return const _BrowserUnavailable();
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      body: Column(
        children: [
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
          // WebView 区
          Expanded(
            child: InAppWebView(
              initialData: InAppWebViewInitialData(
                data: _startPageHtml,
                mimeType: 'text/html',
                encoding: 'utf-8',
              ),
              // 13.3 将按平台补充：Windows userDataFolder、UA 偏好等
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
              ),
              onWebViewCreated: (controller) =>
                  setState(() => _controller = controller),
              onLoadStop: (controller, url) {
                _refreshNavState();
                setState(() => _url = url?.toString() ?? '');
              },
              onUpdateVisitedHistory: (controller, url, androidIsReload) {
                _refreshNavState();
                setState(() => _url = url?.toString() ?? '');
              },
              onProgressChanged: (controller, progress) {
                setState(() => _progress = progress);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：导航按钮（按历史栈状态禁用）+ 地址显示区（输入框风格 8px 圆角）。
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
            onPressed: _canGoBack ? () => _controller?.goBack() : null,
            icon: const Icon(LucideIcons.arrowLeft),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: '后退',
          ),
          IconButton(
            onPressed: _canGoForward ? () => _controller?.goForward() : null,
            icon: const Icon(LucideIcons.arrowRight),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: '前进',
          ),
          IconButton(
            onPressed: _reload,
            icon: const Icon(LucideIcons.rotateCw),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: '刷新',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: colorScheme.brightness == Brightness.dark
                    ? const Color(0xFF1A1A1A) // AppColors.inputBackgroundDark
                    : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outline),
              ),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  _SecurityIcon(url: _url),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _addressLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

/// 安全图标：HTTPS 锁形 / HTTP 警示；起始页（about:blank）不显示。
class _SecurityIcon extends StatelessWidget {
  const _SecurityIcon({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (url.startsWith('https://')) {
      return Icon(LucideIcons.lock, size: 12, color: colorScheme.primary);
    }
    if (url.startsWith('http://')) {
      return Icon(
        LucideIcons.alertTriangle,
        size: 12,
        color: colorScheme.error,
      );
    }
    return const SizedBox.shrink();
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
