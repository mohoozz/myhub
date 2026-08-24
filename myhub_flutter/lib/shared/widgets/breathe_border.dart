import 'package:flutter/material.dart';

/// 呼吸灯高亮边框：用于浏览页"定位到源路径"的目标文件提示。
///
/// 包裹任意子组件，在其周围绘制主题色边框，颜色透明度随动画往复变化，
/// 形成"呼吸"的视觉效果，比静态高亮边框更能引导视线锁定目标文件。
/// 提示时长由上层控制（超时后本组件随高亮状态一起从树中移除）。
class BreathingBorder extends StatefulWidget {
  const BreathingBorder({
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.borderWidth = 1.6,
    this.period = const Duration(milliseconds: 900),
    super.key,
  });

  final Widget child;

  /// 边框圆角（与子组件圆角保持一致）。
  final BorderRadius borderRadius;

  /// 边框宽度（与静态高亮边框一致，避免布局跳动）。
  final double borderWidth;

  /// 单次"亮 → 暗 → 亮"呼吸周期时长。
  final Duration period;

  @override
  State<BreathingBorder> createState() => _BreathingBorderState();
}

class _BreathingBorderState extends State<BreathingBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.period,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        // 呼吸曲线：透明度在 0.15 ~ 1.0 之间缓动往返。
        final t = Curves.easeInOut.transform(_controller.value);
        return Container(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: primary.withValues(alpha: 0.15 + 0.85 * t),
              width: widget.borderWidth,
            ),
          ),
          child: child,
        );
      },
    );
  }
}
