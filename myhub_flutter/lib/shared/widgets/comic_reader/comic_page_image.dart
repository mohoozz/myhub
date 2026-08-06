import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 漫画单页图片：CachedNetworkImage 封装（三种阅读模式共用）。
///
/// 纯黑沉浸背景下的占位/失败样式统一；磁盘缓存按 URL（含页码）分键。
class ComicPageImage extends StatelessWidget {
  const ComicPageImage({
    super.key,
    required this.url,
    required this.headers,
    this.pageNumber,
    this.fit = BoxFit.contain,
    this.placeholderHeight,
  });

  final String url;
  final Map<String, String> headers;

  /// 占位中显示的页码（1 起）；null 时不显示。
  final int? pageNumber;

  /// 图片适配方式：单页/双页 contain，条漫 fitWidth。
  final BoxFit fit;

  /// 占位高度（条漫模式图片加载前的高度占位，避免列表跳动）。
  final double? placeholderHeight;

  static const Color _subtle = Color(0xFF888888);

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: headers,
      fit: fit,
      width: fit == BoxFit.fitWidth ? double.infinity : null,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (context, _) => SizedBox(
        height: placeholderHeight,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: _subtle,
                ),
              ),
              if (pageNumber != null) ...[
                const SizedBox(height: 12),
                Text(
                  '第 $pageNumber 页',
                  style: const TextStyle(color: _subtle, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      errorWidget: (context, _, _) => SizedBox(
        height: placeholderHeight,
        child: const Center(
          child: Icon(LucideIcons.imageOff, color: _subtle, size: 40),
        ),
      ),
    );
  }
}
