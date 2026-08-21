import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/api_client.dart';
import 'package:myhub_flutter/core/api/dio_client.dart';

final browserApiProvider = Provider<BrowserApi>(
  (ref) => BrowserApi(ref.watch(dioProvider)),
);

/// 浏览器模块接口封装（书签 / 历史 / 快捷入口，F-601~F-603）。
class BrowserApi extends ApiClient {
  BrowserApi(super.dio);

  // ---------- 历史 ----------

  /// 批量上报访问历史（前端节流后提交，1~200 条）。
  Future<int> reportHistory(List<Map<String, dynamic>> items) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/browser/history',
        data: {'items': items},
      );
      final data = unwrap(res) as Map<String, dynamic>;
      return data['inserted'] as int? ?? 0;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 历史列表（visited_at 降序游标分页）。返回 {list, next_cursor}。
  Future<Map<String, dynamic>> listHistory({
    String? cursor,
    int limit = 50,
  }) async {
    try {
      final res = await dio.get<Map<String, dynamic>>(
        '/browser/history',
        queryParameters: {'cursor': cursor, 'limit': limit},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 清空全部历史。
  Future<void> clearHistory() async {
    try {
      final res = await dio.delete<Map<String, dynamic>>('/browser/history');
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 单条删除历史。
  Future<void> deleteHistory(int id) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/browser/history',
        queryParameters: {'id': id},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  // ---------- 书签 ----------

  /// 书签列表。
  Future<List<dynamic>> listBookmarks() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/browser/bookmarks');
      final data = unwrap(res) as Map<String, dynamic>;
      return data['list'] as List<dynamic>? ?? const [];
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 添加书签（URL 唯一，重复幂等）。返回 {bookmark, created}。
  Future<Map<String, dynamic>> addBookmark(
    String title,
    String url, {
    String favicon = '',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/browser/bookmarks',
        data: {'title': title, 'url': url, 'favicon': favicon},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 更新书签（title / url / favicon，按需提供）。
  Future<Map<String, dynamic>> updateBookmark({
    required int id,
    String? title,
    String? url,
    String? favicon,
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '/browser/bookmarks',
        data: {
          'id': id,
          if (title != null) 'title': title,
          if (url != null) 'url': url,
          if (favicon != null) 'favicon': favicon,
        },
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 删除书签（按 id 或 url）。
  Future<void> removeBookmark({int? id, String? url}) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/browser/bookmarks',
        queryParameters: {
          if (id != null && id > 0) 'id': id,
          if (url != null && url.isNotEmpty) 'url': url,
        },
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  // ---------- 快捷入口 ----------

  /// 快捷入口列表（sort_order 升序）。
  Future<List<Map<String, dynamic>>> listShortcuts() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/browser/shortcuts');
      final data = unwrap(res) as Map<String, dynamic>;
      final list = data['list'] as List<dynamic>? ?? const [];
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 添加快捷入口（URL 唯一，重复返回 409）。
  Future<Map<String, dynamic>> addShortcut(String title, String url) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/browser/shortcuts',
        data: {'title': title, 'url': url},
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 更新快捷入口（title / url / sort_order，按需提供）。
  Future<Map<String, dynamic>> updateShortcut({
    required int id,
    String? title,
    String? url,
    int? sortOrder,
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '/browser/shortcuts',
        data: {
          'id': id,
          if (title != null) 'title': title,
          if (url != null) 'url': url,
          if (sortOrder != null) 'sort_order': sortOrder,
        },
      );
      return unwrap(res) as Map<String, dynamic>;
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 批量重排快捷入口（ids 顺序即新 sort_order）。
  Future<void> reorderShortcuts(List<int> ids) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '/browser/shortcuts/order',
        data: {'ids': ids},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }

  /// 删除快捷入口。
  Future<void> removeShortcut(int id) async {
    try {
      final res = await dio.delete<Map<String, dynamic>>(
        '/browser/shortcuts',
        queryParameters: {'id': id},
      );
      unwrap(res);
    } catch (e) {
      rethrowAsApi(e);
    }
  }
}
