import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/providers/media_player_provider.dart';

/// 浏览页文件条目右侧状态指示：
///
/// * 迷你播放器正在播放该文件 → 三竖条"播放中"动画；
/// * 阅读/播放历史存在 → 饼状进度圆环（[0,100]% 按比例填充，
///   100% 时占满整个圆圈）；
/// * 二者皆无 → 不显示（空占位保持行布局稳定）。
class FileStatusIndicator extends ConsumerWidget {
  const FileStatusIndicator({
    required this.item,
    required this.sourceId,
    required this.progressPercent,
    this.size = 16,
    super.key,
  });

  final FileItem item;
  final int? sourceId;

  /// 该文件的阅读进度（0~100），null 表示无历史记录。
  final double? progressPercent;

  /// 指示器整体尺寸（圆环直径 / 动画区域边长）。
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(mediaPlayerProvider);
    return SizedBox(
      width: size,
      height: size,
      // 会话切换与播放/暂停都会改变"正在播放"归属，需一并监听。
      child: ListenableBuilder(
        listenable: Listenable.merge(
          [controller.sessionVersion, controller.playing],
        ),
        builder: (context, _) {
          final file = controller.file;
          final isPlayingFile = file != null &&
              (sourceId == null || controller.sourceId == sourceId) &&
              file.path == item.path &&
              controller.playing.value;
          if (isPlayingFile) {
            return _PlayingBarsIndicator(size: size);
          }
          final percent = progressPercent;
          if (percent == null) {
            // 无阅读历史：不显示指示器
            return const SizedBox.shrink();
          }
          return _ProgressRingIndicator(percent: percent, size: size);
        },
      ),
    );
  }
}

/// "播放中"三竖条动画（类似 QQ 音乐正在播放指示）。
class _PlayingBarsIndicator extends StatefulWidget {
  const _PlayingBarsIndicator({required this.size});

  final double size;

  @override
  State<_PlayingBarsIndicator> createState() => _PlayingBarsIndicatorState();
}

class _PlayingBarsIndicatorState extends State<_PlayingBarsIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _PlayingBarsPainter(
          phase: _controller.value * 2 * math.pi,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _PlayingBarsPainter extends CustomPainter {
  _PlayingBarsPainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  static const int _barCount = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const gap = 1.5;
    final barWidth = (size.width - gap * (_barCount - 1)) / _barCount;
    final maxHeight = size.height;
    final centerY = size.height / 2;
    for (var i = 0; i < _barCount; i++) {
      // 三根竖条错相位正弦起伏，形成均衡器波动效果。
      final t = math.sin(phase + i * 1.1).abs();
      final barHeight = (0.35 + 0.65 * t) * maxHeight;
      final left = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, centerY - barHeight / 2, barWidth, barHeight),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PlayingBarsPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}

/// 饼状进度圆环：从顶部顺时针按比例填充，100% 时占满整个圆圈。
class _ProgressRingIndicator extends StatelessWidget {
  const _ProgressRingIndicator({required this.percent, required this.size});

  /// 进度百分比（0~100）。
  final double percent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _ProgressRingPainter(
        percent: percent.clamp(0.0, 100.0),
        fillColor: colorScheme.primary,
        trackColor: colorScheme.primary.withValues(alpha: 0.25),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter({
    required this.percent,
    required this.fillColor,
    required this.trackColor,
  });

  final double percent;
  final Color fillColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;

    // 底环：浅色细圈，未读部分可见。
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.22
      ..color = trackColor;
    canvas.drawCircle(center, radius - track.strokeWidth / 2, track);

    if (percent >= 100) {
      // 完成：整圈占满（略粗，视觉上更实）。
      final done = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.5
        ..strokeCap = StrokeCap.round
        ..color = fillColor;
      canvas.drawCircle(center, radius - done.strokeWidth / 2, done);
      return;
    }
    if (percent <= 0) return;

    // 已读部分：从顶部（-90°）顺时针扫过的弧。
    final sweep = 2 * math.pi * (percent / 100.0);
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.34
      ..strokeCap = StrokeCap.round
      ..color = fillColor;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      fill,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) =>
      oldDelegate.percent != percent ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.trackColor != trackColor;
}

/// 播放中文件的标题：颜色平滑过渡到主色调，并叠加柔和的脉冲光晕，
/// 与右侧的"播放中"竖条动画呼应，提供一致的播放视觉提示。
///
/// * 颜色：从基础色 → 主色调，过渡时长 350ms（`Curves.easeOut`）；
/// * 字重：播放时升级到 w700（半程切换，避免动画过程中频繁重排）；
/// * 光晕：以 1.5s 周期 `reverse` 呼吸的阴影（alpha 0.2→0.6，
///   模糊半径 4→10），与音频节奏感同步；
/// * 性能：仅在 `isPlaying` 变化时通过 `addPostFrameCallback`
///   启停脉冲控制器，非播放时控制器静止，零开销。
class PlayingFileTitle extends ConsumerStatefulWidget {
  const PlayingFileTitle({
    required this.text,
    required this.itemPath,
    required this.sourceId,
    required this.baseStyle,
    this.maxLines = 1,
    super.key,
  });

  final String text;

  /// 当前文件的路径（用于匹配控制器正在播放的文件）。
  final String itemPath;

  /// 浏览页当前源 ID；与 `MediaPlayerController.sourceId` 一致时
  /// 才认为"正在播放当前浏览列表里的某个文件"。
  final int? sourceId;

  /// 未播放时使用的标题样式（含主题、字重、可能的高亮色等）。
  final TextStyle? baseStyle;

  final int maxLines;

  @override
  ConsumerState<PlayingFileTitle> createState() => _PlayingFileTitleState();
}

class _PlayingFileTitleState extends ConsumerState<PlayingFileTitle>
    with SingleTickerProviderStateMixin {
  /// 1.5s 一次呼吸（正向+反向），与音频节奏感同步。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _wasPlaying = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse(bool isPlaying) {
    if (isPlaying) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      if (_pulse.isAnimating) {
        _pulse.stop();
        _pulse.value = 0;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(mediaPlayerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge(
        [controller.sessionVersion, controller.playing],
      ),
      builder: (context, _) {
        final playingFile = controller.file;
        final isPlaying = playingFile != null &&
            (widget.sourceId == null ||
                controller.sourceId == widget.sourceId) &&
            playingFile.path == widget.itemPath &&
            controller.playing.value;

        if (isPlaying != _wasPlaying) {
          _wasPlaying = isPlaying;
          // 在 build 阶段不能直接修改控制器，用 post-frame 推下一帧再处理。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncPulse(isPlaying);
          });
        }

        return AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            // t: 0→1 渐入播放色，1→0 渐出回到基础色。
            // TweenAnimationBuilder 在 Tween 变更时自动从当前值平滑过渡到新终点。
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: isPlaying ? 1.0 : 0.0),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              builder: (context, t, _) {
                final base = widget.baseStyle ?? const TextStyle();
                final baseColor = base.color ?? colorScheme.onSurface;
                final targetColor =
                    isPlaying ? colorScheme.primary : baseColor;
                final animatedColor =
                    Color.lerp(baseColor, targetColor, t)!;

                return Text(
                  widget.text,
                  maxLines: widget.maxLines,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    color: animatedColor,
                    // 字重在动画过半时切换，避免快速往返时的字形抖动。
                    fontWeight: t > 0.5
                        ? FontWeight.w700
                        : (base.fontWeight ?? FontWeight.normal),
                    // 仅在动画 t>0 时显示阴影；alpha 与模糊半径随脉冲呼吸。
                    shadows: t > 0
                        ? [
                            Shadow(
                              color: colorScheme.primary.withValues(
                                alpha: (0.2 + 0.4 * _pulse.value) * t,
                              ),
                              blurRadius: (4 + 6 * _pulse.value) * t,
                            ),
                          ]
                        : null,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}
