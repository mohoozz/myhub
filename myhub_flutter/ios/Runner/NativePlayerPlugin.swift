import Flutter
import UIKit
import AVFoundation

/// 自定义 iOS 原生播放器插件。
///
/// 用系统 AVPlayer（AVFoundation）内核，通过 FlutterTexture（GPU 纹理）
/// 渲染到 Flutter。解决 media_kit 的 mpv 在 iOS 上播放高帧率（120fps）视频
/// 时渲染掉帧卡顿的问题。同时保留内嵌音轨/字幕轨的枚举与切换能力
/// （AVMediaSelectionGroup）。
///
/// 职责：
///  - 通过 MethodChannel 接收控制命令（open/play/pause/seek/volume/speed/track）
///  - 通过事件流把播放器状态回传 Flutter
///  - 通过 FlutterTexture 把视频帧渲染进 Flutter
final class NativePlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let channelName = "myhub/native_player"
  static let eventChannelName = "myhub/native_player/events"

  /// 当前活跃的控制器实例（单会话模型）。
  static var shared: NativePlayerController?

  private var eventSink: FlutterEventSink?
  /// 保存 registrar 引用，texture 注册延迟到真正播放（open）时获取最新 registry。
  private var registrar: FlutterPluginRegistrar?

  static func register(with registrar: FlutterPluginRegistrar) {
    print("Myhub NativePlayer: register 开始")
    let plugin = NativePlayerPlugin()
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)

    plugin.registrar = registrar

    // 事件流（播放器状态 -> Flutter）
    let eventChannel = FlutterEventChannel(
      name: eventChannelName, binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(plugin)

    print("Myhub NativePlayer: register 完成")
  }

  // MARK: - MethodChannel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    print("Myhub NativePlayer: handle method=\(call.method)")
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "open":
      handleOpen(args, result: result)
    case "play":
      NativePlayerPlugin.shared?.play()
      result(nil)
    case "pause":
      NativePlayerPlugin.shared?.pause()
      result(nil)
    case "seek":
      if let ms = (args["positionMs"] as? NSNumber)?.int64Value {
        NativePlayerPlugin.shared?.seek(toMs: ms)
      }
      result(nil)
    case "setVolume":
      if let v = (args["volume"] as? NSNumber)?.doubleValue {
        NativePlayerPlugin.shared?.setVolume(v)
      }
      result(nil)
    case "setSpeed":
      if let s = (args["speed"] as? NSNumber)?.doubleValue {
        NativePlayerPlugin.shared?.setSpeed(s)
      }
      result(nil)
    case "setBrightness":
      if let b = (args["brightness"] as? NSNumber)?.doubleValue {
        NativePlayerPlugin.shared?.setBrightness(b)
      }
      result(nil)
    case "getBrightness":
      result(NativePlayerPlugin.shared?.currentBrightness() ?? Double(UIScreen.main.brightness))
    case "getSystemStatus":
      // 当前系统音量和亮度（进入播放器时同步，避免音量/亮度与系统不一致）
      result(NativePlayerPlugin.shared?.systemStatus() ?? [
        "volume": AVAudioSession.sharedInstance().outputVolume,
        "brightness": Double(UIScreen.main.brightness),
      ])
    case "getTracks":
      let tracks = NativePlayerPlugin.shared?.tracks() ?? [:]
      result(tracks)
    case "selectAudioTrack":
      if let i = (args["index"] as? NSNumber)?.intValue {
        NativePlayerPlugin.shared?.selectAudioTrack(i)
      }
      result(nil)
    case "selectSubtitleTrack":
      if let i = (args["index"] as? NSNumber)?.intValue {
        NativePlayerPlugin.shared?.selectSubtitleTrack(i)
      }
      result(nil)
    case "getTextureId":
      // Flutter 侧获取渲染用的 texture id
      if let shared = NativePlayerPlugin.shared {
        result(shared.textureId)
      } else {
        result(0)
      }
    case "dispose":
      // 仅销毁播放器资源（player/item/texture/observer），但保留 shared 单例
      // 与其 volumeView：系统音量/亮度控制是全局能力，与 AVPlayer 实例无关。
      // 软解兜底切换时会 dispose AVPlayer，若把 shared 置 nil，后续 setVolume
      // 因 shared==nil 静默跳过，导致"调节音量无反应、系统音量不同步"。
      NativePlayerPlugin.shared?.dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleOpen(_ args: [String: Any], result: @escaping FlutterResult) {
    print("Myhub NativePlayer: handleOpen url=\(args["url"] ?? "nil")")
    guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
      result(FlutterError(code: "bad_url", message: "无效的 URL", details: nil))
      return
    }
    let headers = args["headers"] as? [String: String] ?? [:]
    let title = args["title"] as? String ?? "Myhub"
    // Flutter 侧显式告知原生是否为音频文件：音频不创建视频输出/纹理，
    // 避免 Flutter 端 Texture 显示一个空圆圈占位。
    let isAudio = (args["isAudio"] as? Bool) ?? false
    // 已知真实总时长（毫秒）：直链阶段拿到，切 HLS 后用于修正时长显示。
    let knownDurationMs = (args["knownDurationMs"] as? NSNumber)?.int64Value ?? 0
    // 关键：texture 注册延迟到真正播放时（open），此时引擎渲染上下文已就绪，
    // registrar.textures() 返回的 relay 的 delegate 才有效，register 返回 >=1。
    let registry = registrar?.textures()
    print("Myhub NativePlayer: open 时获取 registry = \(registry == nil ? "nil" : "ok")")
    let controller: NativePlayerController
    if let existing = NativePlayerPlugin.shared {
      controller = existing
      // 若共享 controller 的 registry 之前无效，这里刷新为最新有效 registry
      if registry != nil {
        controller.refreshTextureRegistry(registry!)
      }
      // dispose() 会清空 controller 的 eventSink（见 NativePlayerController.dispose
      // 中 eventSink = nil）。单例复用场景（如软解切换 dispose 后再 open 音频）
      // 必须重新绑定事件流，否则原生 emitStatus 的 ready/playing 发不到 Flutter，
      // Dart 侧 loading 永不消除，UI 一直显示加载中。
      controller.attach(eventSink: eventSink)
    } else {
      controller = NativePlayerController(
        eventSink: eventSink, textureRegistry: registry)
      NativePlayerPlugin.shared = controller
    }
    controller.open(
      url: url, title: title, headers: headers, isAudio: isAudio,
      knownDurationMs: knownDurationMs)
    result(nil)
  }

  // MARK: - FlutterEventStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
      -> FlutterError? {
    eventSink = events
    NativePlayerPlugin.shared?.attach(eventSink: events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    NativePlayerPlugin.shared?.detachEventSink()
    return nil
  }
}
