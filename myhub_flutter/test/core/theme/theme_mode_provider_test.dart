import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeModeNotifier', () {
    test('默认为跟随系统', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), ThemeMode.system);
    });

    test('setMode 更新状态并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(themeModeProvider.notifier)
          .setMode(ThemeMode.dark);
      expect(container.read(themeModeProvider), ThemeMode.dark);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'dark');
    });

    test('启动时从 SharedPreferences 恢复', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // build() 返回默认值后异步恢复
      expect(container.read(themeModeProvider), ThemeMode.system);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(themeModeProvider), ThemeMode.dark);
    });

    test('toggle 亮暗互切', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(themeModeProvider.notifier)
          .toggle(Brightness.light);
      expect(container.read(themeModeProvider), ThemeMode.dark);

      await container
          .read(themeModeProvider.notifier)
          .toggle(Brightness.dark);
      expect(container.read(themeModeProvider), ThemeMode.light);
    });
  });

  group('effectiveThemeModeProvider', () {
    test('沉浸式场景强制暗色，退出后恢复', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'light'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 触发 build 并等待异步恢复完成
      container.read(themeModeProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(effectiveThemeModeProvider), ThemeMode.light);

      container.read(immersiveThemeProvider.notifier).state = true;
      expect(container.read(effectiveThemeModeProvider), ThemeMode.dark);

      container.read(immersiveThemeProvider.notifier).state = false;
      expect(container.read(effectiveThemeModeProvider), ThemeMode.light);
    });
  });
}
