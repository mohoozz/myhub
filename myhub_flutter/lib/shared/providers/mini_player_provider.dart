import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 迷你播放器状态。
///
/// 由全局 Overlay 承载（见 app.dart 的 Stack 宿主），
/// 不随 Tab 切换 / 路由跳转销毁；`null` 表示未激活。
class MiniPlayerState {
  const MiniPlayerState({
    required this.title,
    this.playing = false,
    this.progress = 0,
  });

  /// 当前播放的媒体标题。
  final String title;

  /// 播放/暂停状态。
  final bool playing;

  /// 播放进度 0.0 ~ 1.0。
  final double progress;

  MiniPlayerState copyWith({String? title, bool? playing, double? progress}) {
    return MiniPlayerState(
      title: title ?? this.title,
      playing: playing ?? this.playing,
      progress: progress ?? this.progress,
    );
  }
}

/// 迷你播放器全局状态。
///
/// 播放器模块（第 5 章）在进入全屏播放页时调用 `show`，
/// 退出全屏时保留迷你条；关闭按钮调用 `hide` 停止播放并移除。
final miniPlayerProvider =
    NotifierProvider<MiniPlayerNotifier, MiniPlayerState?>(
  MiniPlayerNotifier.new,
);

class MiniPlayerNotifier extends Notifier<MiniPlayerState?> {
  @override
  MiniPlayerState? build() => null;

  /// 显示迷你播放器。
  void show(String title) {
    state = MiniPlayerState(title: title, playing: true);
  }

  /// 隐藏（停止播放并移除 Overlay）。
  void hide() {
    state = null;
  }

  /// 播放/暂停切换。
  void togglePlaying() {
    final s = state;
    if (s != null) {
      state = s.copyWith(playing: !s.playing);
    }
  }

  /// 更新播放进度（0.0 ~ 1.0）。
  void updateProgress(double progress) {
    final s = state;
    if (s != null) {
      state = s.copyWith(progress: progress.clamp(0.0, 1.0));
    }
  }
}
