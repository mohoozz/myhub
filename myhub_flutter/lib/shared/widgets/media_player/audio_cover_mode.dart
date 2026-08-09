import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/api/stream_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/settings/server_config_provider.dart';
import 'package:myhub_flutter/shared/providers/auth_state_provider.dart';

/// 音频唱片封面模式（TODO 5.3）。
///
/// * 黑胶唱片样式封面，`RotationTransition` 旋转动效：播放时旋转，暂停时停在当前角度；
/// * 封面来源：同目录同名图片，或 cover/folder/front（jpg/jpeg/png/webp），
///   其次回退到后端缩略图接口提取的内嵌专辑封面，均无封面时显示音乐图标占位；
/// * 唱片居中显示，不重复标题/作者（与顶部标题栏一致，避免重复文字）；
/// * 控制栏与视频完全一致（外层 Stack 挂载的 PlayerControls，与模式无关）。
class AudioCoverMode extends ConsumerStatefulWidget {
  const AudioCoverMode({
    super.key,
    required this.player,
    required this.sourceId,
    required this.file,
  });

  /// 已打开媒体的播放器（media_kit Player 或 AvPlayerAdapter，驱动旋转动效）。
  final dynamic player;

  /// 文件所属路径源 ID（封面探测用）。
  final int sourceId;

  /// 播放的音频文件。
  final FileItem file;

  @override
  ConsumerState<AudioCoverMode> createState() => _AudioCoverModeState();
}

class _AudioCoverModeState extends ConsumerState<AudioCoverMode>
    with SingleTickerProviderStateMixin {
  /// 封面图片扩展名候选。
  static const _coverExts = ['jpg', 'jpeg', 'png', 'webp'];

  /// 通用封面文件名候选（小写、无扩展名）。
  static const _coverStems = ['cover', 'folder', 'front'];

  late final AnimationController _rotation;
  StreamSubscription<dynamic>? _playingSub;
  bool _playing = false;

  String? _coverUrl;
  Map<String, String>? _coverHeaders;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    _playing = widget.player.state.playing as bool;
    if (_playing) {
      _rotation.repeat();
    }
    // 播放时旋转，暂停时停止（保持当前角度）
    final playingStream = widget.player.stream.playing as Stream<bool>;
    _playingSub = playingStream.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      if (playing) {
        _rotation.repeat();
      } else {
        _rotation.stop();
      }
    });
    _resolveCover();
  }

  @override
  void dispose() {
    unawaited(_playingSub?.cancel());
    _rotation.dispose();
    super.dispose();
  }

  /// '/a/b/c.mp3' → '/a/b'
  static String _parentDirOf(String path) {
    final idx = path.lastIndexOf('/');
    return idx <= 0 ? '/' : path.substring(0, idx);
  }

  /// 同目录封面探测：同名图片优先，其次 cover/folder/front，
  /// 再回退到后端缩略图接口提取的内嵌专辑封面（无专辑封面时加载失败自动回退占位图标）。
  Future<void> _resolveCover() async {
    String? found;
    final dir = _parentDirOf(widget.file.path);
    try {
      final items = await ref
          .read(fileApiProvider)
          .listFiles(widget.sourceId, dir);
      final names = [
        for (final e in items)
          if (e is Map<String, dynamic> && e['is_dir'] != true)
            e['name'] as String? ?? '',
      ]..removeWhere((n) => n.isEmpty);

      var base = widget.file.name;
      final dot = base.lastIndexOf('.');
      if (dot > 0) {
        base = base.substring(0, dot);
      }

      found =
          _matchCover(names, [base.toLowerCase()]) ??
          _matchCover(names, _coverStems);
    } catch (_) {
      // 目录不可读等场景：仍可尝试内嵌专辑封面
    }
    if (!mounted) return;

    final token = await const FlutterSecureStorage().read(key: kAccessTokenKey);
    if (!mounted) return;
    setState(() {
      _coverUrl = found != null
          ? StreamApi.streamUrl(
              widget.sourceId,
              dir == '/' ? '/$found' : '$dir/$found',
              baseUrl: ref.read(apiBaseUrlProvider),
            )
          : ref
                .read(fileApiProvider)
                .thumbnailUrl(widget.sourceId, widget.file.path);
      _coverHeaders = {
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };
    });
  }

  /// 按候选名（小写、无扩展名）+ 图片扩展名匹配实际文件名（大小写不敏感）。
  static String? _matchCover(List<String> names, List<String> stems) {
    for (final stem in stems) {
      for (final ext in _coverExts) {
        final target = '$stem.$ext';
        for (final name in names) {
          if (name.toLowerCase() == target) return name;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final discSize = (shortest * 0.52).clamp(160.0, 320.0);

    // 只居中显示唱片，不再在唱片下方重复显示标题/作者（与顶部标题栏一致，
    // 避免重复）。
    return Center(
      child: SizedBox(
        width: discSize,
        height: discSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            RotationTransition(
              turns: _rotation,
              child: _VinylDisc(
                size: discSize,
                coverUrl: _coverUrl,
                coverHeaders: _coverHeaders,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 黑胶唱片：黑色外圈 + 圆形封面 + 中心孔。
class _VinylDisc extends StatelessWidget {
  const _VinylDisc({
    required this.size,
    required this.coverUrl,
    required this.coverHeaders,
  });

  final double size;
  final String? coverUrl;
  final Map<String, String>? coverHeaders;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF0D0D0D),
        border: Border.all(color: Colors.white10),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 2),
        ],
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverUrl != null)
              CachedNetworkImage(
                imageUrl: coverUrl!,
                httpHeaders: coverHeaders,
                fit: BoxFit.cover,
                // 加载中 / 加载失败均回退到图标占位
                placeholder: (_, __) => const _CoverPlaceholder(),
                errorWidget: (_, __, ___) => const _CoverPlaceholder(),
              )
            else
              const _CoverPlaceholder(),
          ],
        ),
      ),
    );
  }
}

/// 无封面占位：深灰底 + 音乐图标。
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF1A1A1A),
      child: Center(
        child: Icon(LucideIcons.music, size: 64, color: Colors.white24),
      ),
    );
  }
}
