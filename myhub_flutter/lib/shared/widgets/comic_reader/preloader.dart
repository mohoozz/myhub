import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// 漫画页预加载器（TODO 7.3）。
///
/// * 围绕当前页 ±3 预加载（`precacheImage` + `CachedNetworkImageProvider`，
///   与 ComicPageImage 共享内存/磁盘缓存——headers 须为同一实例）；
/// * 方向感知：正向翻页前向优先（+1/+2/+3 先于 -1/-2/-3），反向后向优先；
/// * 队列管理：最多同时预加载 3 张，完成一张补一张；新一次调用会
///   重排等待队列（进行中的任务不取消，最多 3 张，随缓存完成即可）。
class ComicPreloader {
  ComicPreloader({
    required this.pageCount,
    required this.urlOf,
    required this.headers,
  });

  /// 总页数。
  final int pageCount;

  /// 按页码（0 起）构建图片 URL。
  final String Function(int page) urlOf;

  /// 图片请求头（与 ComicPageImage 同一 map 实例，保证 ImageCache 命中）。
  final Map<String, String> headers;

  /// 预加载半径（±3 页）。
  static const int _range = 3;

  /// 最大并发预加载数。
  static const int _maxConcurrent = 3;

  int _lastPage = 0;
  final Set<int> _inFlight = {};
  final List<int> _queue = [];
  BuildContext? _context;

  /// 围绕 [page] 预加载 ±3 页。
  void preloadAround(int page, BuildContext context) {
    _context = context;
    final forward = page >= _lastPage;
    _lastPage = page;

    final targets = <int>[
      for (var d = 1; d <= _range; d++) forward ? page + d : page - d,
      for (var d = 1; d <= _range; d++) forward ? page - d : page + d,
    ];
    _queue
      ..clear()
      ..addAll(
        targets.where((p) => p >= 0 && p < pageCount && !_inFlight.contains(p)),
      );
    _pump();
  }

  void _pump() {
    final context = _context;
    if (context == null || !context.mounted) return;
    while (_inFlight.length < _maxConcurrent && _queue.isNotEmpty) {
      final page = _queue.removeAt(0);
      if (_inFlight.add(page)) {
        unawaited(_precache(page, context));
      }
    }
  }

  Future<void> _precache(int page, BuildContext context) async {
    try {
      await precacheImage(
        CachedNetworkImageProvider(urlOf(page), headers: headers),
        context,
      );
    } catch (_) {
      // 预加载失败静默：滑到该页时 ComicPageImage 会重新加载
    } finally {
      _inFlight.remove(page);
      _pump();
    }
  }

  /// 释放：停止派发新任务（进行中的预加载随缓存完成，无副作用）。
  void dispose() {
    _context = null;
    _queue.clear();
  }
}
