import 'dart:convert';

/// JWT 工具：本地解析过期时间（不验签，仅做有效性预检）。
abstract final class JwtUtils {
  /// 判断 Token 是否已过期；无法解析视为有效（交给后端裁决）。
  static bool isExpired(String token, {Duration clockSkew = Duration.zero}) {
    final exp = expiresAt(token);
    if (exp == null) return false;
    return DateTime.now().add(clockSkew).isAfter(exp);
  }

  /// 解析 exp 声明为本地时间；解析失败返回 null。
  static DateTime? expiresAt(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = parts[1];
      final padded = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
      final json = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (json is! Map<String, dynamic>) return null;
      final exp = json['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    } catch (_) {
      return null;
    }
  }
}
