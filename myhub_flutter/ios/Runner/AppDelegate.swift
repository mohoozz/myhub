import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // iOS 媒体播放必须配置并激活 AVAudioSession，否则 mpv（audiounit 后端）
    // 无法输出声音（视频和音频都会静音）。.playback 分类允许静音开关关闭时
    // 也播放声音，并支持后台/锁屏播放。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      // 明确设置采样率与输出缓冲区时长：让 mpv 的 audiounit 后端避免频繁
      // 重采样，稳定音频时钟，减少有声播放高码率视频时的缓冲卡顿。
      try session.setPreferredSampleRate(48000)
      try session.setPreferredIOBufferDuration(0.02)
      try session.setActive(true)
    } catch {
      NSLog("Myhub: failed to configure AVAudioSession: \(error)")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    print("Myhub NativePlayer: didInitializeImplicitFlutterEngine 被调用")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 注册自定义原生播放器插件（通过 registry 获取 registrar）
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativePlayerPlugin") {
      print("Myhub NativePlayer: 获取 registrar 成功")
      NativePlayerPlugin.register(with: registrar)
    } else {
      print("Myhub NativePlayer: 获取 registrar 返回 nil")
    }
  }
}
