import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/utils/jwt_utils.dart';
import 'package:myhub_flutter/features/auth/login_screen.dart';
import 'package:myhub_flutter/features/auth/widgets/change_password_dialog.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 构造伪造 JWT（仅用于本地解析测试）。
String fakeJwt({required int expSeconds}) {
  String b64(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({'user_id': 1, 'username': 'admin', 'exp': expSeconds});
  return '$header.$payload.fakesig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JwtUtils', () {
    test('过期判定', () {
      final future = DateTime.now().add(const Duration(hours: 1));
      final past = DateTime.now().subtract(const Duration(hours: 1));
      expect(
        JwtUtils.isExpired(fakeJwt(expSeconds: future.millisecondsSinceEpoch ~/ 1000)),
        isFalse,
      );
      expect(
        JwtUtils.isExpired(fakeJwt(expSeconds: past.millisecondsSinceEpoch ~/ 1000)),
        isTrue,
      );
    });

    test('畸形 Token 不视为过期（交给后端裁决）', () {
      expect(JwtUtils.isExpired('not-a-jwt'), isFalse);
      expect(JwtUtils.isExpired(''), isFalse);
    });
  });

  group('AuthStateNotifier Token 有效性检查', () {
    test('过期 Token 恢复时被清除并置为未登录', () async {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      FlutterSecureStorage.setMockInitialValues({
        'access_token': fakeJwt(expSeconds: past.millisecondsSinceEpoch ~/ 1000),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(authStateProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        container.read(authStateProvider).status,
        AuthStatus.unauthenticated,
      );
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: kAccessTokenKey), isNull);
    });

    test('有效 Token 恢复为已登录', () async {
      final future = DateTime.now().add(const Duration(hours: 1));
      FlutterSecureStorage.setMockInitialValues({
        'access_token':
            fakeJwt(expSeconds: future.millisecondsSinceEpoch ~/ 1000),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(authStateProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        container.read(authStateProvider).status,
        AuthStatus.authenticated,
      );
    });
  });

  group('LoginScreen', () {
    testWidgets('密码明文/密文切换', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: LoginScreen())),
      );

      TextField passwordField() => tester.widget<TextField>(
            find.widgetWithText(TextField, '密码'),
          );
      expect(passwordField().obscureText, isTrue);

      await tester.tap(find.byIcon(LucideIcons.eye));
      await tester.pump();
      expect(passwordField().obscureText, isFalse);

      await tester.tap(find.byIcon(LucideIcons.eyeOff));
      await tester.pump();
      expect(passwordField().obscureText, isTrue);
    });

    testWidgets('空用户名密码提示错误', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: LoginScreen())),
      );

      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      expect(find.text('请输入用户名和密码'), findsOneWidget);
    });
  });

  group('ChangePasswordDialog', () {
    Future<void> pumpDialog(WidgetTester tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => ChangePasswordDialog.show(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('新密码过短提示', (tester) async {
      await pumpDialog(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '原密码'),
        'oldpass',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '新密码（至少 6 位）'),
        '123',
      );
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.text('新密码至少 6 位'), findsOneWidget);
    });

    testWidgets('两次输入不一致提示', (tester) async {
      await pumpDialog(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '原密码'),
        'oldpass',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '新密码（至少 6 位）'),
        'newpass1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '确认新密码'),
        'newpass2',
      );
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.text('两次输入的新密码不一致'), findsOneWidget);
    });
  });
}
