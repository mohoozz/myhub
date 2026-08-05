import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:myhub_flutter/app.dart';
import 'package:myhub_flutter/shared/widgets/window_title_bar.dart';
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
  }
  runApp(const ProviderScope(child: MyhubApp()));
}
