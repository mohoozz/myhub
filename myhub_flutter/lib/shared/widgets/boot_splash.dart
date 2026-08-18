import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// 启动引导页：服务器内网/外网探测期间显示的全屏 loading。
///
/// 原实现在 `runApp` 之前 `await` 探测（最长可达数秒），iOS 首次打开会一直
/// 停留在原生白屏；现改为先渲染本页（带 loading 动画），探测完成后由
/// `MyhubApp` 切换到主界面。
class BootSplash extends StatelessWidget {
  const BootSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // iOS/macOS 使用系统风格的菊花指示器，其余平台用 Material 圆形进度
    final useCupertino = !kIsWeb && (Platform.isIOS || Platform.isMacOS);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'myhub',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 28),
            useCupertino
                ? const CupertinoActivityIndicator(radius: 14)
                : const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.8),
                  ),
            const SizedBox(height: 16),
            Text(
              '正在连接服务器…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
