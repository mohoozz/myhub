import 'dart:io' show Platform;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// 全局 WebView2 环境单例（Windows）。
///
/// WebView2 约束：每个 userDataFolder 只能创建一个 WebViewEnvironment，
/// 多个 InAppWebView（多标签）必须共享同一环境实例，否则创建失败。
/// 因此这里以进程级单例缓存，首次访问时异步初始化。
class BrowserEnvironment {
  BrowserEnvironment._();

  static final BrowserEnvironment instance = BrowserEnvironment._();

  WebViewEnvironment? _env;
  Future<WebViewEnvironment?>? _creating;

  /// 获取（必要时创建）全局 WebView 环境。
  ///
  /// * Windows → WebView2 环境（userDataFolder 指向应用数据目录，隔离会话）；
  /// * 其余平台返回 null（使用默认环境）。
  Future<WebViewEnvironment?> get environment async {
    if (!Platform.isWindows) return null;
    if (_env != null) return _env;
    return _creating ??= _create()
        .then((e) {
          _env = e;
          _creating = null;
          return e;
        })
        .catchError((Object e) {
          _creating = null;
          throw e;
        });
  }

  Future<WebViewEnvironment?> _create() async {
    String? userDataFolder;
    try {
      final dir = await getApplicationSupportDirectory();
      userDataFolder = '${dir.path}${Platform.pathSeparator}webview2';
    } catch (_) {
      // 目录获取失败则回退默认路径（null）
    }
    return WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: userDataFolder),
    );
  }

  /// 检测 WebView2 Runtime 是否可用；null 表示 Runtime 缺失（需引导安装）。
  Future<String?> get runtimeVersion =>
      WebViewEnvironment.getAvailableVersion();
}
