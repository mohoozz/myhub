import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:myhub_flutter/features/profile/profile_screen.dart';
import 'package:myhub_flutter/shared/widgets/avatar_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<GoRouter> pumpButton(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Center(child: AvatarButton())),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => const ProfileScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('头像按钮渲染默认图标', (tester) async {
    await pumpButton(tester);
    expect(find.byType(CircleAvatar), findsOneWidget);
  });

  testWidgets('点击头像直接跳转个人主页', (tester) async {
    final router = await pumpButton(tester);

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();

    expect(router.state.matchedLocation, '/profile');
    expect(find.text('个人中心'), findsOneWidget);
    expect(find.text('未登录'), findsOneWidget);
  });
}
