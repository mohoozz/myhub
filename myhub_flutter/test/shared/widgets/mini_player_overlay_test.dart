import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/shared/providers/mini_player_provider.dart';
import 'package:myhub_flutter/shared/widgets/mini_player_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiniPlayerNotifier', () {
    test('show/hide/toggle/updateProgress', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(miniPlayerProvider.notifier);

      expect(container.read(miniPlayerProvider), isNull);

      notifier.show('测试歌曲');
      final s = container.read(miniPlayerProvider)!;
      expect(s.title, '测试歌曲');
      expect(s.playing, isTrue);

      notifier.togglePlaying();
      expect(container.read(miniPlayerProvider)!.playing, isFalse);

      notifier.updateProgress(0.5);
      expect(container.read(miniPlayerProvider)!.progress, 0.5);

      notifier.updateProgress(1.5); // clamp 到 1.0
      expect(container.read(miniPlayerProvider)!.progress, 1.0);

      notifier.hide();
      expect(container.read(miniPlayerProvider), isNull);
    });
  });

  group('MiniPlayerOverlay', () {
    Future<ProviderContainer> pumpApp(WidgetTester tester) async {
      FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => Stack(
              children: [
                child ?? const SizedBox.shrink(),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MiniPlayerOverlay(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('未激活时不渲染', (tester) async {
      await pumpApp(tester);
      expect(find.byIcon(LucideIcons.x), findsNothing);
    });

    testWidgets('激活后跨路由跳转仍保持', (tester) async {
      final container = await pumpApp(tester);
      final router = container.read(appRouterProvider);

      container.read(miniPlayerProvider.notifier).show('测试音频.mp3');
      await tester.pumpAndSettle();
      expect(find.text('测试音频.mp3'), findsOneWidget);

      // 跳转其他路由（模拟全屏播放页 push 后返回的场景）
      router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('测试音频.mp3'), findsOneWidget);

      router.go('/reading');
      await tester.pumpAndSettle();
      expect(find.text('测试音频.mp3'), findsOneWidget);

      // 关闭后消失
      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pumpAndSettle();
      expect(find.text('测试音频.mp3'), findsNothing);
    });

    testWidgets('播放/暂停按钮切换状态', (tester) async {
      final container = await pumpApp(tester);
      container.read(miniPlayerProvider.notifier).show('A');
      await tester.pumpAndSettle();

      // 左侧状态图标与按钮图标相同，需限定在 IconButton 内查找
      await tester.tap(find.widgetWithIcon(IconButton, LucideIcons.pause));
      await tester.pumpAndSettle();
      expect(container.read(miniPlayerProvider)!.playing, isFalse);

      await tester.tap(find.widgetWithIcon(IconButton, LucideIcons.play));
      await tester.pumpAndSettle();
      expect(container.read(miniPlayerProvider)!.playing, isTrue);
    });
  });
}
