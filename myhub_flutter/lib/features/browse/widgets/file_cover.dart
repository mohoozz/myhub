import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/features/browse/widgets/file_icon.dart';
import 'package:myhub_flutter/shared/providers/auth_headers_provider.dart';

/// 文件封面缩略图。
///
/// 视频/音频走后端 FFmpeg 缩略图接口（音频提取内嵌专辑封面），
/// 漫画取第一页；不支持的类型、无 sourceId 或加载失败时回退到类型图标。
class FileCover extends ConsumerWidget {
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

  String? _coverUrl(WidgetRef ref) {
    final sid = sourceId;
    if (sid == null || item.isDir) return null;
    return switch (item.mediaType) {
      'video' || 'audio' =>
        ref.read(fileApiProvider).thumbnailUrl(sid, item.path),
      'comic' => ref.read(comicApiProvider).pageUrl(sid, item.path, 0),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = Center(
      child: Icon(
        fileIconOf(item),
        size: iconSize,
        color: fileIconColorOf(context, item),
      ),
    );
    final url = _coverUrl(ref);
    if (url == null) return fallback;
    final headers = ref.watch(authHeadersProvider).valueOrNull;
    if (headers == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        fit: fit,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
