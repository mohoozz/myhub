import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// 应用缓存管理（设置页"离线缓存管理"）：
/// 统计/清理临时目录（含 cached_network_image 图片磁盘缓存）与内存图片缓存。
class AppCache {
  AppCache._();

  /// 临时缓存目录总大小（字节）。
  static Future<int> size() async {
    final dir = await getTemporaryDirectory();
    var total = 0;
    if (!await dir.exists()) return total;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // 文件可能在统计期间被删除，忽略
        }
      }
    }
    return total;
  }

  /// 清空临时缓存目录内容 + 内存图片缓存。
  static Future<void> clear() async {
    final dir = await getTemporaryDirectory();
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // 占用中的文件跳过
        }
      }
    }
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }
}
