import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/app.dart';
import 'package:myhub_flutter/core/api/connectivity_probe.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/shared/utils/window_bounds.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 启动时自动判断内网/外网：读取已保存的内网地址，优先探测内网，内网不可用则退回外网。
  await _detectServerNetwork();
  if (isDesktopPlatform) {
    // Hide the native title bar; WindowTitleBar draws the custom one.
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    // 桌面窗口最小尺寸限制
    await windowManager.setMinimumSize(const Size(480, 320));
    // 恢复上次关闭时的窗口位置和尺寸，并持续记忆后续变化
    final prefs = await SharedPreferences.getInstance();
    await windowManager.waitUntilReadyToShow(null, () async {
      await WindowBoundsMemory.instance.init(prefs);
      await windowManager.show();
      await windowManager.focus();
    });
  } else if (!kIsWeb && Platform.isAndroid) {
    // Android 边缘到边缘：内容延伸至状态栏/导航栏下方（Android 15 默认行为）
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(const ProviderScope(child: MyhubApp()));
}

/// 启动时自动判断内网/外网：
/// 读取已保存的外网/内网地址，内网可用则优先用内网（'lan'），否则用外网（'wan'）。
/// 结果写入 SharedPreferences，`serverConfigProvider` 恢复时据此设置当前生效网络。
Future<void> _detectServerNetwork() async {
  final prefs = await SharedPreferences.getInstance();
  final lan = prefs.getString(ServerConfigNotifier.kLanUrlKey)?.trim() ?? '';
  if (lan.isEmpty) {
    await prefs.setString(ServerConfigNotifier.kActiveNetworkKey, 'wan');
    return;
  }
  // 优先内网：内网可连用内网，否则退回外网
  final lanOk = await probeServer(lan) == null;
  await prefs.setString(
    ServerConfigNotifier.kActiveNetworkKey,
    lanOk ? 'lan' : 'wan',
  );
}
