import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 内置浏览器可用平台：PC（Windows）+ iOS（F-601）。
///
/// 基于 flutter_inappwebview 的 WebView 能力约束：
/// * Windows → WebView2（需 WebView2 Runtime，一般随 Edge 自带）
/// * iOS → WKWebView
/// 其余平台（Android / macOS / Linux / Web）隐藏"浏览器"页签并降级
/// （路由层将 `/browser` 重定向回 `/browse`）。
bool get browserSupported => !kIsWeb && (Platform.isWindows || Platform.isIOS);
