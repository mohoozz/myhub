import 'package:flutter/services.dart';
import 'package:myhub_flutter/core/api/api_exception.dart';

/// iOS 相册保存工具：把图片字节写入系统「照片」App。
///
/// 走自定义 MethodChannel `myhub/photo_saver`，原生侧用 PHPhotoLibrary
/// 写入（见 ios/Runner/PhotoSaverPlugin.swift）。仅 iOS 可用；其他平台
/// 请使用 [downloader.dart] 把文件下载到本地。
abstract final class PhotoSaver {
  static const MethodChannel _channel = MethodChannel('myhub/photo_saver');

  /// 保存图片字节到系统相册。
  ///
  /// 权限被拒 / 图片无法解析 / 写入失败时抛 [ApiException]。
  static Future<void> saveImage(Uint8List bytes) async {
    try {
      await _channel.invokeMethod<void>('saveImageToPhotos', {'bytes': bytes});
    } on PlatformException catch (e) {
      throw ApiException(code: -1, message: _friendlyMessage(e.code));
    }
  }

  static String _friendlyMessage(String? code) {
    switch (code) {
      case 'denied':
        return '没有相册写入权限，请在「设置」中允许访问照片';
      case 'bad_args':
      case 'bad_image':
        return '图片数据无法解析';
      default:
        return '保存到相册失败';
    }
  }
}
