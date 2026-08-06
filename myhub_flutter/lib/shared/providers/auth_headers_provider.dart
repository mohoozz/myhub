import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 非 dio 图片请求（CachedNetworkImage 等）所需的 JWT 请求头。
final authHeadersProvider = FutureProvider<Map<String, String>>((ref) async {
  final token = await const FlutterSecureStorage().read(key: kAccessTokenKey);
  return {
    if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
});
