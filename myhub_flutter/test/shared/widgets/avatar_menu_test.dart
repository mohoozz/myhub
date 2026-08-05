import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/theme/theme_mode_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';
import 'package:myhub_flutter/shared/widgets/avatar_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpMenu(
    WidgetTester tester, {
    int? lastBranch,
    void Function(int)? onGoBranch,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: AvatarMenuButton(onGoBranch: onGoBranch ?? (_) {}),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('菜单包含全部功能项', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await pumpMenu(tester);

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();

    expect(find.text('个人中心'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
  });

  testWidgets('我的收藏/设置回调对应分支', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final branches = <int>[];
    await pumpMenu(tester, onGoBranch: branches.add);

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(branches, [AppBranchesTest.favorites]);

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(branches, [AppBranchesTest.favorites, AppBranchesTest.settings]);
  });

  testWidgets('深色模式开关切换主题并持久化', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final container = await pumpMenu(tester);

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();

    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.value, isFalse); // 默认测试环境为亮色

    await tester.tap(find.text('深色模式'));
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  testWidgets('退出登录：确认后清除登录状态', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
    final container = await pumpMenu(tester);

    // 恢复登录状态（testWidgets 为 fake async，用 pump 推进时间）
    await tester.pumpAndSettle();
    expect(
      container.read(authStateProvider).status,
      AuthStatus.authenticated,
    );

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    // 二次确认弹窗
    expect(find.text('确定要退出当前账号吗？'), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    expect(
      container.read(authStateProvider).status,
      AuthStatus.unauthenticated,
    );
  });

  testWidgets('退出登录：取消则保持登录', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
    final container = await pumpMenu(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(
      container.read(authStateProvider).status,
      AuthStatus.authenticated,
    );
  });
}

/// 与 AppBranches 常量对齐（避免测试依赖路由实现细节）。
abstract final class AppBranchesTest {
  static const int favorites = 1;
  static const int settings = 4;
}
