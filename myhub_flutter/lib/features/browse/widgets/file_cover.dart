import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_icon.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';

/// 封面网络请求的全局并发限额。
///
/// 大目录首次进入时封面全部未缓存，若不限流会一次性向后端发起几十个
/// 缩略图请求，触发后端 FFmpeg 进程风暴，拖慢视频流导致播放卡顿。
/// 超出限额的条目先显示类型图标，拿到许可后再发起加载。
final CoverSemaphore _coverSemaphore = CoverSemaphore(4);

/// 简单的 FIFO 信号量：acquire 排队，release 放行下一个等待者。
class CoverSemaphore {
  CoverSemaphore(this._max);

  final int _max;
  int _inFlight = 0;
  final List<void Function()> _waiters = [];

  Future<void> acquire() {
    if (_inFlight < _max) {
      _inFlight++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer.complete);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0)();
    } else {
      _inFlight--;
    }
  }
}

/// 文件封面缩略图。
///
/// 视频/音频走后端 FFmpeg 缩略图接口（音频提取内嵌专辑封面），
/// 漫画取第一页；不支持的类型、无 sourceId 或加载失败时回退到类型图标。
class FileCover extends ConsumerStatefulWidget {
  const FileCover({
    super.key,
    required this.item,
    required this.sourceId,
    this.iconSize = 36,
    this.fit = BoxFit.cover,
    this.borderRadius = 8,
  });

  final FileItem item;

  /// 当前路径源 ID；为空时不尝试加载封面，直接显示类型图标。
  final int? sourceId;

  /// 回退图标尺寸。
  final double iconSize;

  /// 图片填充方式。
  final BoxFit fit;

  /// 图片圆角。
  final double borderRadius;

  @override
  ConsumerState<FileCover> createState() => _FileCoverState();
}

class _FileCoverState extends ConsumerState<FileCover> {
  /// 是否已拿到并发许可（拿到后才挂载 CachedNetworkImage 发起请求）。
  bool _ready = false;

  /// 是否已在排队申请许可（防止重复申请）。
  bool _acquiring = false;

  @override
  void dispose() {
    // 仅在确实持有许可时释放（未拿到许可的排队者不占额度）
    if (_ready) _coverSemaphore.release();
    super.dispose();
  }

  void _acquire() {
    if (_acquiring) return;
    _acquiring = true;
    _coverSemaphore.acquire().then((_) {
      if (!mounted) {
        // 等待期间被销毁（滚动出屏/切目录）：归还许可
        _coverSemaphore.release();
        return;
      }
      setState(() => _ready = true);
    });
  }

  String? _coverUrl(WidgetRef ref) {
    final sid = widget.sourceId;
    if (sid == null || widget.item.isDir) return null;
    return switch (widget.item.mediaType) {
      'video' || 'audio' =>
        ref.read(fileApiProvider).thumbnailUrl(sid, widget.item.path),
      'comic' => ref.read(comicApiProvider).pageUrl(sid, widget.item.path, 0),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final fallback = Center(
      child: Icon(
        fileIconOf(item),
        size: widget.iconSize,
        color: fileIconColorOf(context, item),
      ),
    );
    final url = _coverUrl(ref);
    if (url == null) return fallback;
    final headers = ref.watch(authHeadersProvider).valueOrNull;
    if (headers == null) return fallback;
    // 并发限额：未获许可前显示类型图标，许可到手后挂载网络图片
    if (!_ready) {
      _acquire();
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        fit: widget.fit,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
