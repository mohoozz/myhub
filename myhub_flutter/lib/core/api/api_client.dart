import 'package:dio/dio.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';

/// API 封装基类：统一拆解后端信封 `{code, data, message}`。
///
/// 子类通过 [unwrap] 取 `data` 字段；业务码非 0 时抛 [ApiException]。
abstract class ApiClient {
  ApiClient(this.dio);

  final Dio dio;

  /// 拆解统一响应信封，返回 data 字段。
  dynamic unwrap(Response<dynamic> response) {
    final body = response.data;
    if (body is Map<String, dynamic>) {
      final code = body['code'];
      if (code == 0) {
        return body['data'];
      }
      throw ApiException(
        code: code is int ? code : -1,
        message: body['message'] as String? ?? '请求失败',
        statusCode: response.statusCode,
      );
    }
    return body;
  }

  /// 将 DioException 归一化为 ApiException 抛出。
  Never rethrowAsApi(Object err) {
    if (err is DioException && err.error is ApiException) {
      throw err.error! as ApiException;
    }
    if (err is DioException) {
      throw ApiException.fromDio(err);
    }
    throw err;
  }
}
