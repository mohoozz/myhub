import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/app.dart';
import 'package:myhub_flutter/shared/utils/window_bounds.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
