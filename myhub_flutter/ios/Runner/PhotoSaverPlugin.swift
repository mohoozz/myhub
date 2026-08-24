import Flutter
import UIKit
import Photos

/// 把图片保存到系统相册的原生插件。
///
/// 供「纯图片预览页」在 iOS 上把图片保存到「照片」App。
/// 通过 MethodChannel 接收图片字节（FlutterStandardTypedData），
/// 解码为 UIImage 后经 PHPhotoLibrary 写入相册。
///
/// 权限策略：
/// * iOS 14+：请求 add-only 权限（仅写入，对应 NSPhotoLibraryAddUsageDescription）；
/// * iOS 13 及以下：请求完整相册权限（对应 NSPhotoLibraryUsageDescription）。
final class PhotoSaverPlugin: NSObject, FlutterPlugin {
  static let channelName = "myhub/photo_saver"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = PhotoSaverPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    print("Myhub PhotoSaver: register 完成")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "saveImageToPhotos" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = (call.arguments as? [String: Any]) ?? [:]
    guard let data = args["bytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "bad_args", message: "缺少图片数据", details: nil))
      return
    }
    saveToPhotos(imageData: data.data, result: result)
  }

  private func saveToPhotos(imageData: Data, result: @escaping FlutterResult) {
    guard let image = UIImage(data: imageData) else {
      result(FlutterError(code: "bad_image", message: "无法解析图片数据", details: nil))
      return
    }

    let performSave: (PHAuthorizationStatus) -> Void = { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(code: "denied", message: "没有相册写入权限", details: nil))
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }) { success, error in
        DispatchQueue.main.async {
          if success {
            result(nil)
          } else {
            result(FlutterError(
              code: "save_failed",
              message: error?.localizedDescription ?? "保存到相册失败",
              details: nil))
          }
        }
      }
    }

    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: performSave)
    } else {
      PHPhotoLibrary.requestAuthorization(performSave)
    }
  }
}
