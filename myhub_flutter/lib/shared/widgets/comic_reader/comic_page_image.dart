import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 漫画单页图片：CachedNetworkImage 封装（三种阅读模式共用）。
///
/// 纯黑沉浸背景下的占位/失败样式统一；磁盘缓存按 URL（含页码）分键。
/// [onImageSize] 在图片解码完成后上报固有像素尺寸（条漫模式据此
/// 计算每页宽高比，用于精确的页码定位与阅读进度恢复）。
class ComicPageImage extends StatefulWidget {
  const ComicPageImage({
    super.key,
    required this.url,
    required this.headers,
    this.pageNumber,
    this.fit = BoxFit.contain,
    this.placeholderHeight,
    this.onImageSize,
  });

  final String url;
  final Map<String, String> headers;

  /// 占位中显示的页码（1 起）；null 时不显示。
  final int? pageNumber;

  /// 图片适配方式：单页/双页 contain，条漫 fitWidth。
  final BoxFit fit;

  /// 占位高度（条漫模式图片加载前的高度占位，避免列表跳动）。
  final double? placeholderHeight;

  /// 图片解码完成后的固有尺寸回调（像素）。
  final ValueChanged<Size>? onImageSize;

  @override
  State<ComicPageImage> createState() => _ComicPageImageState();
}

class _ComicPageImageState extends State<ComicPageImage> {
  static const Color _subtle = Color(0xFF888888);

  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _reported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ComicPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _removeListener();
      _reported = null;
      _resolve();
    }
  }

  /// 解析图片流以上报固有尺寸（与 CachedNetworkImage 同一 provider，
  /// 命中内存/磁盘缓存，开销可忽略）。
  void _resolve() {
    if (widget.onImageSize == null || _stream != null) return;
    final provider = CachedNetworkImageProvider(
      widget.url,
      headers: widget.headers,
    );
    _listener = ImageStreamListener(
      (info, _) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        if (_reported == size) return;
        _reported = size;
        // 图片已在缓存中时回调同步触发，可能正处于 build 阶段
        // （didChangeDependencies 内 resolve），延迟到帧后避免
        // 父级 setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onImageSize?.call(size);
        });
      },
      onError: (_, _) {},
    );
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _stream!.addListener(_listener!);
  }

  void _removeListener() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _removeListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: widget.url,
      httpHeaders: widget.headers,
      fit: widget.fit,
      width: widget.fit == BoxFit.fitWidth ? double.infinity : null,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (context, _) => SizedBox(
        height: widget.placeholderHeight,
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
              if (widget.pageNumber != null) ...[
                const SizedBox(height: 12),
                Text(
                  '第 ${widget.pageNumber} 页',
                  style: const TextStyle(color: _subtle, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      errorWidget: (context, _, _) => SizedBox(
        height: widget.placeholderHeight,
        child: const Center(
          child: Icon(LucideIcons.imageOff, color: _subtle, size: 40),
        ),
      ),
    );
  }
}
