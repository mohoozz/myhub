import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';
import 'package:myhub_flutter/core/models/feed.dart';

final feedApiProvider = Provider<FeedApi>(
  (ref) => FeedApi(ref.watch(dioProvider)),
);

/// 动态模块接口封装（M5）。
///
/// 前端统一经 Go 后端 `/feed` 接口访问，Go 后端代理 myhub-feed 抓取服务，
/// 并在本地维护已读游标与稍后观看。
class FeedApi extends ApiClient {
  FeedApi(super.dio);

  /// 动态列表（id 游标分页，按发布时间降序）。
  /// [before] 为上一页最早条目的 id，首页不传。
  Future<FeedPage> listFeed({int before = 0, int limit = 20}) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/feed',
        queryParameters: {
          if (before > 0) 'before': before,
          'limit': limit,
        },
      );
      final data = unwrap(res) as Map<String, dynamic>;
      return FeedPage.fromJson(data);
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

  /// 全部标为已读（游标推进到最新条目）。
  Future<void> markAllRead() async {
    try {
      final res = await dio.post<Map<String, dynamic>>('/feed/read-all');
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 已读游标 id（"已看到此处"锚点）。
  Future<int> getCursor() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/feed/cursor');
      final data = unwrap(res);
      if (data is Map<String, dynamic>) {
        return (data['feed_item_id'] as num?)?.toInt() ?? 0;
      }
      return 0;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 订阅源列表。
  Future<List<FeedSubscription>> listSubscriptions() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/feed/subscriptions');
      final data = unwrap(res);
      final list = (data as Map<String, dynamic>?)?['items'] as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => FeedSubscription.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 新增订阅源。payload：platform/target/name。
  Future<void> addSubscription(
    String platform,
    String target, {
    String name = '',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/feed/subscriptions',
        data: {
          'platform': platform,
          'target': target,
          if (name.isNotEmpty) 'name': name,
        },
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 删除订阅源。
  Future<void> removeSubscription(int id, {bool purge = false}) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/feed/subscriptions/$id',
        queryParameters: {if (purge) 'purge': 'true'},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 手动触发抓取（可选指定平台/订阅源）。
  Future<void> fetch({String? platform, int? subscriptionId}) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/feed/fetch',
        queryParameters: {
          if (platform != null && platform.isNotEmpty) 'platform': platform,
          if (subscriptionId != null) 'subscription_id': subscriptionId,
        },
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 稍后观看列表（每项含关联的 [FeedItem] 详情）。
  Future<List<WatchLater>> listWatchLater() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/feed/watch-later');
      final list = unwrap(res) as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => WatchLater.fromJson(e as Map<String, dynamic>))
          .toList();
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

/// 动态列表分页结果。
class FeedPage {
  const FeedPage({
    required this.items,
    required this.cursorId,
    required this.hasMore,
  });

  final List<FeedItem> items;
  final int cursorId;
  final bool hasMore;

  factory FeedPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return FeedPage(
      items: rawItems
          .map((e) => FeedItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      cursorId: (json['cursor_id'] as num?)?.toInt() ?? 0,
      hasMore: json['has_more'] == true,
    );
  }
}
