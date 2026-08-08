import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/providers/native_player_controller.dart';
import 'package:myhub_flutter/shared/widgets/media_player/native_player_view.dart';

/// 阶段1 验证页：用原生 AVPlayer 播放视频，验证流畅渲染。
class NativePlayerTestScreen extends ConsumerStatefulWidget {
  const NativePlayerTestScreen({
    super.key,
    required this.sourceId,
    required this.file,
  });

  final int sourceId;
  final FileItem file;

  @override
  ConsumerState<NativePlayerTestScreen> createState() =>
      _NativePlayerTestScreenState();
}

class _NativePlayerTestScreenState
    extends ConsumerState<NativePlayerTestScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = ref.read(nativePlayerProvider);
      controller.play(widget.sourceId, widget.file);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(nativePlayerProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: NativePlayerView()),
                  // 加载指示
                  ValueListenableBuilder<bool>(
                    valueListenable: controller.loading,
                    builder: (context, loading, _) => loading
                        ? const Center(
                            child: CircularProgressIndicator(
                                color: Colors.white70))
                        : const SizedBox.shrink(),
                  ),
                  // 错误
                  ValueListenableBuilder<String?>(
                    valueListenable: controller.error,
                    builder: (context, err, _) => err != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('播放失败',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16)),
                                  const SizedBox(height: 8),
                                  Text(err,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white70)),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            _buildControls(controller),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(NativePlayerController controller) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ValueListenableBuilder<NativePlayerState?>(
            valueListenable: controller.state,
            builder: (context, s, _) {
              final playing = s?.isPlaying ?? false;
              return IconButton(
                iconSize: 40,
                icon: Icon(
                  playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () => controller.togglePlay(),
              );
            },
          ),
          const SizedBox(width: 12),
          const Text('原声 AVPlayer 播放器',
              style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}
