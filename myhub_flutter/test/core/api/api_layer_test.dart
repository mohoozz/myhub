import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';
import 'package:myhub_flutter/core/api/stream_api.dart';

class _TestApi extends ApiClient {
  _TestApi() : super(Dio());
}

void main() {
  group('StreamApi URL 构造', () {
    test('streamUrl', () {
      // 中文与空格均应百分号编码，播放器可直接使用
      expect(
        StreamApi.streamUrl(1, '/视频/a b.mp4'),
        endsWith('/api/stream/1/%E8%A7%86%E9%A2%91/a%20b.mp4'),
      );
    });

    test('hlsSessionId 与后端 base64url 编码一致（无 padding）', () {
      final id = StreamApi.hlsSessionId(7, '/movie.mp4');
      expect(id.contains('='), isFalse);
      expect(id.contains('+'), isFalse);
      expect(id.contains('/'), isFalse);
      // 解码验证
      final padded = id.padRight((id.length + 3) ~/ 4 * 4, '=');
      expect(utf8.decode(base64Url.decode(padded)), '7|/movie.mp4');
    });

    test('hlsPlaylistUrl / hlsSegmentUrl / subtitleUrl', () {
      final id = StreamApi.hlsSessionId(3, '/v/m.mp4');
      expect(
        StreamApi.hlsPlaylistUrl(3, '/v/m.mp4'),
        endsWith('/api/stream/hls/$id/playlist.m3u8'),
      );
      expect(
        StreamApi.hlsSegmentUrl(3, '/v/m.mp4', 'seg_00001.ts'),
        endsWith('/api/stream/hls/$id/segment/seg_00001.ts'),
      );
      expect(
        StreamApi.subtitleUrl(3, '/v/m.srt'),
        endsWith('/api/stream/subtitle?source=3&path=%2Fv%2Fm.srt'),
      );
    });
  });

  group('ApiClient.unwrap', () {
    final api = _TestApi();

    Response<dynamic> envelope(Object? data, {int code = 0, String msg = ''}) {
      return Response<dynamic>(
        requestOptions: RequestOptions(),
        statusCode: code == 0 ? 200 : 400,
        data: {'code': code, 'data': data, 'message': msg},
      );
    }

    test('code=0 返回 data', () {
      expect(api.unwrap(envelope({'a': 1})), {'a': 1});
      expect(api.unwrap(envelope(null)), isNull);
      expect(api.unwrap(envelope([1, 2])), [1, 2]);
    });

    test('code!=0 抛 ApiException', () {
      expect(
        () => api.unwrap(envelope(null, code: 40001, msg: '参数错误')),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 40001)
              .having((e) => e.message, 'message', '参数错误'),
        ),
      );
    });
  });

  group('ApiException.fromDio', () {
    test('取后端信封 message', () {
      final err = DioException(
        requestOptions: RequestOptions(),
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 401,
          data: {'code': 401, 'data': null, 'message': '用户名或密码错误'},
        ),
      );
      final e = ApiException.fromDio(err);
      expect(e.message, '用户名或密码错误');
      expect(e.statusCode, 401);
    });

    test('连接失败兜底文案', () {
      final err = DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionError,
      );
      expect(ApiException.fromDio(err).message, '无法连接服务器');
    });

    test('超时兜底文案', () {
      final err = DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.receiveTimeout,
      );
      expect(ApiException.fromDio(err).message, '请求超时，请稍后重试');
    });
  });
}
