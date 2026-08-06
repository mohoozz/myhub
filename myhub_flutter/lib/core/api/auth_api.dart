import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(dioProvider)),
);

/// 鉴权接口封装。
class AuthApi extends ApiClient {
  AuthApi(super.dio);

  /// 登录：成功返回 JWT 字符串。
  Future<String> login(String username, String password) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {'username': username, 'password': password},
      );
      final data = unwrap(res) as Map<String, dynamic>;
      return data['token'] as String;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 修改密码（需旧密码验证）。
  Future<void> changePassword(String oldPassword, String newPassword) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '/auth/password',
        data: {'old_password': oldPassword, 'new_password': newPassword},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 当前登录用户信息。
  Future<Map<String, dynamic>> me() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/auth/me');
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 上传头像（multipart，字段名 avatar，5MB 以内）。
  ///
  /// 成功返回头像相对 URL（含 ?v= 版本号，如 `/api/auth/avatar?v=123`）。
  Future<String> uploadAvatar(String filePath) async {
    try {
      final form = FormData();
      form.files.add(
        MapEntry('avatar', await MultipartFile.fromFile(filePath)),
      );
      final res = await dio.put<Map<String, dynamic>>(
        '/auth/avatar',
        data: form,
      );
      final data = unwrap(res) as Map<String, dynamic>;
      return data['avatar_url'] as String;
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
