import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/utils/jwt_utils.dart';

/// 构造不验签的测试 JWT。
String fakeJwt(Map<String, dynamic> payload) {
  String b64(Object obj) =>
      base64Url.encode(utf8.encode(jsonEncode(obj))).replaceAll('=', '');
  return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64(payload)}.sig';
}

void main() {
  group('JwtUtils.username', () {
    test('解析 username 声明', () {
      final token = fakeJwt({'username': 'admin', 'exp': 1893456000});
      expect(JwtUtils.username(token), 'admin');
    });

    test('缺少 username 声明返回 null', () {
      expect(JwtUtils.username(fakeJwt({'exp': 1893456000})), isNull);
    });

    test('非法 token 返回 null', () {
      expect(JwtUtils.username('fake-jwt'), isNull);
      expect(JwtUtils.username('a.b.c'), isNull);
    });
  });

  group('JwtUtils.expiresAt / isExpired', () {
    test('解析 exp 声明', () {
      final token = fakeJwt({'exp': 1893456000});
      expect(
        JwtUtils.expiresAt(token),
        DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000),
      );
    });

    test('过期 token 判定为已过期', () {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
      expect(JwtUtils.isExpired(fakeJwt({'exp': past})), isTrue);
    });

    test('无法解析视为有效', () {
      expect(JwtUtils.isExpired('fake-jwt'), isFalse);
    });
  });
}
