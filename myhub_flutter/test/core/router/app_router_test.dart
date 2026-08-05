import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:myhub_flutter/core/router/app_router.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例默认无 Token（未登录）
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<GoRouter> createRouter(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final router = container.read(appRouterProvider);
    addTearDown(container.dispose);
    return router;
  }

  Future<void> pumpRouter(WidgetTester tester, ProviderContainer container) {
    return tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(appRouterProvider),
        ),
      ),
    );
  }

  testWidgets('未登录访问 /browse 重定向到 /login 并携带 from', (tester) async {
    final container = ProviderContainer();
    final router = await createRouter(tester, container);
    await pumpRouter(tester, container);
    await tester.pumpAndSettle();

    router.go('/browse');
    await tester.pumpAndSettle();

    expect(router.state.matchedLocation, '/login');
    expect(router.state.uri.queryParameters['from'], '/browse');
  });

  testWidgets('本地存在 Token 时恢复为已登录并自动离开 /login', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
    final container = ProviderContainer();
    final router = await createRouter(tester, container);
    await pumpRouter(tester, container);
    await tester.pumpAndSettle();

    // unknown → authenticated 恢复后，守卫把 /login 重定向到 /reading
    expect(
      container.read(authStateProvider).status,
      AuthStatus.authenticated,
    );
    expect(router.state.matchedLocation, '/reading');
  });

  testWidgets('已登录访问 /login 时按 from 回跳', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
    final container = ProviderContainer();
    final router = await createRouter(tester, container);
    await pumpRouter(tester, container);
    await tester.pumpAndSettle();

    router.go('/login?from=${Uri.encodeComponent('/favorites')}');
    await tester.pumpAndSettle();

    expect(router.state.matchedLocation, '/favorites');
  });

  testWidgets('登出后被守卫送回 /login', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
    final container = ProviderContainer();
    final router = await createRouter(tester, container);
    await pumpRouter(tester, container);
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/reading');

    await container.read(authStateProvider.notifier).markLoggedOut();
    await tester.pumpAndSettle();

    expect(router.state.matchedLocation, '/login');
  });

  testWidgets('/profile 路由可达', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'fake-jwt'});
    final container = ProviderContainer();
    final router = await createRouter(tester, container);
    await pumpRouter(tester, container);
    await tester.pumpAndSettle();

    router.go('/profile');
    await tester.pumpAndSettle();

    expect(router.state.matchedLocation, '/profile');
    expect(find.text('个人中心'), findsOneWidget);
  });
}
