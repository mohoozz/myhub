import 'dart:async' show unawaited;
import 'dart:collection' show UnmodifiableListView;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/features/browser/browser_environment.dart';
import 'package:myhub_flutter/features/browser/widgets/start_page.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// WebView 事件回调（由 [BrowserView] 透传给上层 [BrowserScreen]）。
abstract class BrowserViewCallbacks {
  /// URL 变化（onLoadStop / onUpdateVisitedHistory）。
  void onUrlChanged(String url);

  /// 页面标题变化。
  void onTitleChanged(String title);

  /// favicon 变化。
  void onFaviconChanged(String faviconUrl);

  /// 加载进度（0~100）。
  void onProgressChanged(int progress);

  /// 后退/前进可用状态变化。
  void onNavStateChanged({required bool canGoBack, required bool canGoForward});

  /// 请求打开新窗口（`target=_blank` / `window.open`）→ 上层开新标签。
  void onCreateWindowRequest(String url);

  /// 加载失败（含 SSL 错误）→ 上层可展示错误页。
  void onError(String url, String message);

  /// 页面加载完成（onLoadStop）→ 上层用于历史节流上报。
  void onPageFinished(String url);

  /// 新页面开始加载（onLoadStart）→ 上层重置滚动基准等状态。
  void onPageStarted();

  /// 起始页请求导航（搜索提交 / 快捷入口点击）→ 上层更新标签 URL。
  void onNavigateRequest(String url);

  /// 页面滚动（iOS：用于滚动收起/展开底部操作栏，y 为纵向滚动偏移）。
  void onScrollChanged(int y);

  /// 网页内点击（iOS：操作栏收起后，点击页面重新展开）。
  void onPageTap();
}

/// InAppWebView 封装（F-601）：平台初始化、错误页、新窗口、下载拦截。
///
/// * Windows：WebView2 userDataFolder 指向应用数据目录（多实例隔离会话）；
///   Runtime 缺失时 InAppWebView 构造抛错，由上层 [BrowserScreen] 捕获并引导。
/// * iOS：WKWebView 配置 `allowsBackForwardNavigationGestures` 支持侧滑返回。
/// * `supportMultipleWindows` + `onCreateWindow` 让 `target=_blank` 开新标签。
/// * `shouldOverrideUrlLoading` 拦截下载链接（一期引导系统浏览器打开）。
class BrowserView extends StatefulWidget {
  const BrowserView({
    super.key,
    required this.url,
    required this.navSeq,
    required this.callbacks,
    required this.keepAlive,
    this.onWebViewCreated,
    this.userAgent,
  });

  /// 目标 URL；空串表示加载内置起始页。
  final String url;

  /// 外部导航命令序号：变化时驱动 WebView 主动加载 [url]。
  /// 页面内跳转只改 [url] 不改序号，避免重复 loadUrl 打断历史栈。
  final int navSeq;

  final BrowserViewCallbacks callbacks;

  /// 后台标签保持会话不销毁（隐藏而非 dispose）。
  final bool keepAlive;

  /// 控制器创建回调（上层用于发起 goBack/stop 等命令）。
  final void Function(InAppWebViewController controller)? onWebViewCreated;

  /// 自定义 UA；null 表示跟随平台默认（F-605）。
  final String? userAgent;

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<BrowserView> {
  InAppWebViewController? _controller;
  String _currentUrl = '';
  bool _error = false;
  String _errorMessage = '';

  /// WebView 环境初始化 Future（缓存，避免每次 build 重复触发）。
  late Future<WebViewEnvironment?> _envFuture;

  @override
  void initState() {
    super.initState();
    _envFuture = BrowserEnvironment.instance.environment;
  }

  @override
  void didUpdateWidget(covariant BrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅外部导航命令（navSeq 递增）驱动加载；页面内跳转（点击链接）
    // 由 WebView 自身完成导航，重复 loadUrl 会打断导航历史栈导致
    // 后退/前进失效。URL 变化但不递增 navSeq 时不干预。
    if (widget.navSeq != oldWidget.navSeq && widget.url.isNotEmpty) {
      _error = false;
      _load(widget.url);
    }
  }

  Future<void> _load(String url) async {
    final controller = _controller;
    if (controller == null || url.isEmpty) return;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  InAppWebViewSettings _buildSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      // 显式开启 HTTP 磁盘缓存（WebView2 由 userDataFolder 持久化，
      // WKWebView / Android 默认持久化），重启后资源可复用
      cacheEnabled: true,
      // 支持 window.open / target=_blank 触发 onCreateWindow
      supportMultipleWindows: true,
      // 拦截导航以处理下载链接
      useShouldOverrideUrlLoading: true,
      // iOS：允许侧滑返回上一页（历史栈空则退出页签由上层协调）
      allowsBackForwardNavigationGestures: true,
      // 允许混合内容（内网 HTTP 资源在 HTTPS 页内加载）
      useOnDownloadStart: true,
      // 自定义 UA（F-605：跟随平台/桌面/移动）
      userAgent: widget.userAgent ?? '',
    );
  }

  @override
  Widget build(BuildContext context) {
    // 起始页（新建标签）：渲染 Flutter 原生起始页（搜索框 + 快捷入口）
    if (widget.url.isEmpty) {
      return StartPage(
        onOpenUrl: (url) => widget.callbacks.onNavigateRequest(url),
      );
    }

    // 错误页：加载失败 / SSL 错误提示 + 重试按钮
    if (_error) {
      return _ErrorPage(
        message: _errorMessage,
        url: _currentUrl,
        onRetry: () {
          setState(() => _error = false);
          _load(_currentUrl.isEmpty ? '' : _currentUrl);
        },
      );
    }

    // 平台初始化：Windows WebView2 环境（userDataFolder 隔离会话）+ Runtime
    // 缺失检测；iOS 无环境需返回 null（用默认 WKWebView）。
    return FutureBuilder<WebViewEnvironment?>(
      future: _envFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // WebView2 Runtime 缺失：环境创建抛错 → 引导安装页（重试重新初始化）
          return _RuntimeMissingPage(
            onRetry: () => setState(() {
              _envFuture = BrowserEnvironment.instance.environment;
            }),
          );
        }
        // 注意：这里不能使用随 URL 变化的 key——否则每次导航都会
        // 销毁重建 WebView，导航历史栈/页面状态全部丢失（后退失效、
        // 每次跳转都从头加载）。同一标签的 WebView 实例必须保持稳定，
        // 后续导航由 didUpdateWidget（navSeq 驱动）或页面内跳转完成。
        return InAppWebView(
          initialSettings: _buildSettings(),
          // iOS：注入点击监听（捕获阶段、不拦截默认行为），操作栏收起后
          // 点击页面任意位置 → callHandler('pageTap') → 重新展开操作栏
          initialUserScripts: Platform.isIOS
              ? UnmodifiableListView<UserScript>([
                  UserScript(
                    source: "document.addEventListener('click', function() {"
                        'if (window.flutter_inappwebview) {'
                        "window.flutter_inappwebview.callHandler('pageTap');"
                        '}'
                        '}, true);',
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                  ),
                ])
              : null,
          webViewEnvironment: snapshot.data,
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          onWebViewCreated: (controller) {
            _controller = controller;
            if (Platform.isIOS) {
              // 注册网页点击 handler（与 initialUserScripts 注入的
              // callHandler('pageTap') 配对），点击页面展开底部操作栏
              controller.addJavaScriptHandler(
                handlerName: 'pageTap',
                callback: (args) {
                  widget.callbacks.onPageTap();
                  return null;
                },
              );
            }
            widget.onWebViewCreated?.call(controller);
          },
          onScrollChanged: (controller, x, y) {
            widget.callbacks.onScrollChanged(y);
          },
          onLoadStart: (controller, url) {
            setState(() {
              _currentUrl = url?.toString() ?? '';
              _error = false;
            });
            widget.callbacks.onPageStarted();
            widget.callbacks.onUrlChanged(_currentUrl);
          },
          onLoadStop: (controller, url) async {
            _currentUrl = url?.toString() ?? '';
            await _syncNavState();
            widget.callbacks.onUrlChanged(_currentUrl);
            // 页面加载完成：触发历史节流上报
            widget.callbacks.onPageFinished(_currentUrl);
            // 标题在 onLoadStop 时可能尚未就绪，尽力读取
            final title = await controller.getTitle();
            if (title != null && title.isNotEmpty) {
              widget.callbacks.onTitleChanged(title);
            }
          },
          onUpdateVisitedHistory: (controller, url, androidIsReload) {
            _currentUrl = url?.toString() ?? '';
            _syncNavState();
            widget.callbacks.onUrlChanged(_currentUrl);
          },
          onTitleChanged: (controller, title) {
            widget.callbacks.onTitleChanged(title ?? '');
          },
          onFaviconChanged: (controller, request) {
            widget.callbacks.onFaviconChanged(request.url?.toString() ?? '');
          },
          onProgressChanged: (controller, progress) {
            widget.callbacks.onProgressChanged(progress);
          },
          // 新窗口（target=_blank / window.open）→ 交给上层开新标签
          onCreateWindow: (controller, createWindowAction) async {
            widget.callbacks.onCreateWindowRequest(
              createWindowAction.request.url?.toString() ?? '',
            );
            return true;
          },
          // 加载失败 / SSL 错误 → 展示错误页
          onReceivedError: (controller, request, error) {
            // 主框架失败才切错误页；子资源（图片等）失败忽略
            if (request.isForMainFrame == true) {
              setState(() {
                _error = true;
                _errorMessage = error.description;
              });
              widget.callbacks.onError(
                request.url.toString(),
                error.description,
              );
            }
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            final statusCode = errorResponse.statusCode;
            if (request.isForMainFrame == true &&
                statusCode != null &&
                statusCode >= 400) {
              setState(() {
                _error = true;
                _errorMessage = 'HTTP $statusCode';
              });
            }
          },
          // 下载链接拦截：一期引导系统浏览器打开（不做下载管理）
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final url = navigationAction.request.url;
            if (url == null) return NavigationActionPolicy.ALLOW;
            // 命中下载意图（常见后缀）→ 引导系统浏览器打开
            if (_looksLikeDownload(url.toString())) {
              unawaited(_openInSystemBrowser(url.toString()));
              return NavigationActionPolicy.CANCEL;
            }
            return NavigationActionPolicy.ALLOW;
          },
          onDownloadStarting: (controller, request) async {
            // 一期：下载链接引导系统浏览器打开，取消默认下载对话框
            unawaited(_openInSystemBrowser(request.url.toString()));
            return DownloadStartResponse(
              handled: true,
              action: DownloadStartResponseAction.CANCEL,
            );
          },
        );
      },
    );
  }

  /// 简单后缀启发式：判断是否为下载资源（下载拦截一期实现）。
  static bool _looksLikeDownload(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    const exts = {
      '.zip',
      '.rar',
      '.7z',
      '.tar',
      '.gz',
      '.exe',
      '.msi',
      '.dmg',
      '.apk',
      '.ipa',
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.ppt',
      '.pptx',
      '.torrent',
      '.mp4',
      '.mkv',
      '.avi',
      '.mov',
    };
    return exts.any(path.endsWith);
  }

  /// 引导系统浏览器打开下载链接（一期不做下载管理）。
  Future<void> _openInSystemBrowser(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      await launcher.launchUrl(
        uri,
        mode: launcher.LaunchMode.externalApplication,
      );
    } catch (_) {
      // 系统浏览器打开失败静默（不打断浏览）
    }
  }

  Future<void> _syncNavState() async {
    final controller = _controller;
    if (controller == null) return;
    final canBack = await controller.canGoBack();
    final canForward = await controller.canGoForward();
    widget.callbacks.onNavStateChanged(
      canGoBack: canBack,
      canGoForward: canForward,
    );
  }
}

/// 加载失败 / SSL 错误提示页 + 重试按钮。
class _ErrorPage extends StatelessWidget {
  const _ErrorPage({
    required this.message,
    required this.url,
    required this.onRetry,
  });

  final String message;
  final String url;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.triangleAlert, size: 48, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              '无法加载页面',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              url.isEmpty ? message : '$url\n$message',
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.rotateCw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Windows WebView2 Runtime 缺失提示页：引导下载安装 + 重试。
class _RuntimeMissingPage extends StatelessWidget {
  const _RuntimeMissingPage({required this.onRetry});

  final VoidCallback onRetry;

  static const String _downloadUrl =
      'https://developer.microsoft.com/microsoft-edge/webview2/';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.triangleAlert, size: 48, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              '缺少 WebView2 运行库',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '内置浏览器依赖 Microsoft Edge WebView2 Runtime，请安装后重试。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: () => unawaited(
                    launcher.launchUrl(
                      Uri.parse(_downloadUrl),
                      mode: launcher.LaunchMode.externalApplication,
                    ),
                  ),
                  icon: const Icon(LucideIcons.download, size: 16),
                  label: const Text('下载安装'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(LucideIcons.rotateCw, size: 16),
                  label: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
