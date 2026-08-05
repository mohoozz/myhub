import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final feedApiProvider = Provider<FeedApi>(
  (ref) => FeedApi(ref.watch(dioProvider)),
);

/// 动态模块接口封装（二期 M5，后端接口按 1.12 契约预置）。
class FeedApi extends ApiClient {
  FeedApi(super.dio);

  /// 动态列表（游标分页）。
  /// [before] 为上一页最早条目的发布时间（ISO8601），首页不传。
  Future<Map<String, dynamic>> listFeed({String? before, int limit = 20}) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/feed',
        queryParameters: {
          if (before != null) 'before': before,
          'limit': limit,
        },
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 标记已读（游标推进到该条目）。
  Future<void> markRead(int feedItemId) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/feed/read',
        data: {'feed_item_id': feedItemId},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 订阅源列表。
  Future<List<dynamic>> listSubscriptions() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/feed/subscriptions');
      return (unwrap(res) as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 新增订阅源。payload：platform/name/target/cron_expr。
  Future<Map<String, dynamic>> addSubscription(
    Map<String, dynamic> payload,
  ) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/feed/subscriptions',
        data: payload,
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 删除订阅源。
  Future<void> removeSubscription(int id) async {
    try {
      final res =
          await dio.delete<Map<String, dynamic>>('/feed/subscriptions/$id');
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 手动触发抓取（可选指定订阅源）。
  Future<void> fetch({int? subscriptionId}) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/feed/fetch',
        data: {if (subscriptionId != null) 'subscription_id': subscriptionId},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 稍后观看列表。
  Future<List<dynamic>> listWatchLater() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/feed/watch-later');
      return (unwrap(res) as List<dynamic>?) ?? [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 加入稍后观看。
  Future<void> addWatchLater(String platform, String contentId) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/feed/watch-later',
        data: {'platform': platform, 'content_id': contentId},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 移出稍后观看。
  Future<void> removeWatchLater(String platform, String contentId) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/feed/watch-later',
        data: {'platform': platform, 'content_id': contentId},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
