import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// 播放器屏幕中央悬浮反馈（OSD）：图标 + 数值，自动消隐。
///
/// 手势调节（进度/音量/亮度）、键盘调节（快进/音量/静音）、
/// 底栏按钮调节共用同一通道，避免多处各自渲染反馈。
class PlayerOsd {
  final ValueNotifier<({IconData icon, String text})?> _state = ValueNotifier(
    null,
  );
  Timer? _timer;

  /// 供 [PlayerOsdView] 订阅。
  ValueListenable<({IconData icon, String text})?> get listenable => _state;

  /// 显示一条反馈，[hold] 后自动消隐（再次调用刷新计时）。
  void show(
    IconData icon,
    String text, {
    Duration hold = const Duration(milliseconds: 600),
  }) {
    _timer?.cancel();
    _state.value = (icon: icon, text: text);
    _timer = Timer(hold, hide);
  }

  /// 持续显示（如拖动进度/音量期间），结束后调用 [dismiss]。
  void showHold(IconData icon, String text) {
    _timer?.cancel();
    _state.value = (icon: icon, text: text);
  }

  /// 延迟消隐（手势/拖动结束时调用）。
  void dismiss([Duration delay = const Duration(milliseconds: 600)]) {
    _timer?.cancel();
    _timer = Timer(delay, hide);
  }

  /// 立即消隐。
  void hide() {
    _timer?.cancel();
    _timer = null;
    _state.value = null;
  }

  void dispose() {
    _timer?.cancel();
    _state.dispose();
  }
}

/// 悬浮胶囊视图：订阅 [PlayerOsd] 并渲染反馈内容。
///
/// 显示位置：屏幕**中下 1/3** 处水平居中。
/// * 避开了顶部文件名（动态岛机型上顶栏较高，`top: 72` 仍可能重叠）；
/// * 避开了中央播放按钮（与 OSD 同时出现时也只在调节瞬间，
///   此时中央播放按钮已被隐藏/淡化）；
/// * 避开底部控制栏（位于 1/3 处，距离底栏较远）。
class PlayerOsdView extends StatelessWidget {
  const PlayerOsdView({super.key, required this.osd});

  final PlayerOsd osd;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<({IconData icon, String text})?>(
      valueListenable: osd.listenable,
      builder: (context, feedback, _) {
        if (feedback == null) return const SizedBox.shrink();
        return IgnorePointer(
          child: Align(
            // 中下 1/3：屏幕垂直方向靠下，避免与顶栏/中央大按钮/底栏重叠。
            alignment: const Alignment(0, 0.35),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(feedback.icon, size: 18, color: Colors.white),
                  const SizedBox(width: 10),
                  Text(
                    feedback.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
