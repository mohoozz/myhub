import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/shared/providers/native_player_controller.dart';

/// 原生 AVPlayer 视频渲染 widget（FlutterTexture / GPU 纹理）。
///
/// 通过 [nativePlayerProvider] 获取原生注册的 textureId，用 Flutter 的
/// [Texture] 显示 AVPlayer 的视频帧。布局稳定、性能好（GPU 渲染）。
class NativePlayerView extends ConsumerWidget {
  const NativePlayerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(nativePlayerProvider);
    return ValueListenableBuilder<int>(
      valueListenable: controller.textureId,
      builder: (context, textureId, _) {
        if (textureId <= 0) {
          // texture 尚未就绪：黑屏占位
          return const SizedBox.expand(
              child: ColoredBox(color: Color(0xFF000000)));
        }
        return Texture(
          textureId: textureId,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }
}
