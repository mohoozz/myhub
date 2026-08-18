import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/connectivity_probe.dart';
import 'package:myhub_flutter/core/config/env.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 服务器配置：记录客户端连接的服务端主机地址。
///
/// 支持双地址（参考路径源的 `url` + `lan_url` 模式）：
/// * [wanUrl] 外网地址（原 baseUrl）
/// * [lanUrl]  内网地址（可选）
///
/// [activeNetwork] 记录当前实际使用的网络（'lan' 内网 / 'wan' 外网）。
/// 客户端重启时自动探测（见 [ServerConfigNotifier.autoDetect]）：
/// 内网可用则优先内网，否则退回外网。
final serverConfigProvider =
    NotifierProvider<ServerConfigNotifier, ServerConfig>(ServerConfigNotifier.new);

/// 服务器连接配置。
class ServerConfig {
  const ServerConfig({
    required this.wanUrl,
    this.lanUrl = '',
    this.activeNetwork = 'wan',
  });

  /// 外网主机地址（含协议与端口，不带 /api 后缀）。
  final String wanUrl;

  /// 内网主机地址（可选，可为空）。
  final String lanUrl;

  /// 当前生效网络：'lan' 内网 / 'wan' 外网。
  final String activeNetwork;

  /// 当前生效的主机地址（去除尾部斜杠，供 URL 拼接与 Dio baseUrl 使用）。
  String get baseUrl {
    final url = activeNetwork == 'lan' && lanUrl.trim().isNotEmpty
        ? lanUrl.trim()
        : wanUrl.trim();
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  /// 是否有配置内网地址。
  bool get hasLanUrl => lanUrl.trim().isNotEmpty;

  ServerConfig copyWith({
    String? wanUrl,
    String? lanUrl,
    String? activeNetwork,
  }) {
    return ServerConfig(
      wanUrl: wanUrl ?? this.wanUrl,
      lanUrl: lanUrl ?? this.lanUrl,
      activeNetwork: activeNetwork ?? this.activeNetwork,
    );
  }
}

/// 测试连接结果。
class ServerTestResult {
  const ServerTestResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

class ServerConfigNotifier extends Notifier<ServerConfig> {
  /// 外网地址（兼容旧 key `server.base_url`）。
  static const kWanUrlKey = 'server.base_url';

  /// 内网地址。
  static const kLanUrlKey = 'server.lan_url';

  /// 当前生效网络。
  static const kActiveNetworkKey = 'server.active_network';

  bool _restored = false;

  @override
  ServerConfig build() {
    _restore();
    return ServerConfig(wanUrl: Env.apiBaseUrl);
  }

  Future<void> _restore() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    final wan = prefs.getString(kWanUrlKey)?.trim() ?? '';
    final lan = prefs.getString(kLanUrlKey)?.trim() ?? '';
    final active = prefs.getString(kActiveNetworkKey) ?? 'wan';
    _restored = true;
    state = ServerConfig(
      wanUrl: wan.isEmpty ? Env.apiBaseUrl : wan,
      lanUrl: lan,
      activeNetwork: active == 'lan' ? 'lan' : 'wan',
    );
  }

  /// 等待本地存储恢复完成（供启动探测调用）。
  Future<void> ensureRestored() => _restore();

  /// 更新外网/内网地址并持久化。内网地址可为空。
  Future<void> setUrls({required String wanUrl, String lanUrl = ''}) async {
    await _restore();
    final wan = _normalize(wanUrl);
    final lan = _normalize(lanUrl);
    state = state.copyWith(wanUrl: wan, lanUrl: lan);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kWanUrlKey, wan);
    if (lan.isEmpty) {
      await prefs.remove(kLanUrlKey);
    } else {
      await prefs.setString(kLanUrlKey, lan);
    }
  }

  /// 切换当前生效的网络（'lan' / 'wan'）并持久化。
  Future<void> setActiveNetwork(String network) async {
    final n = network == 'lan' ? 'lan' : 'wan';
    state = state.copyWith(activeNetwork: n);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kActiveNetworkKey, n);
  }

  /// 启动时自动判断内网/外网：内网可连则用内网，否则用外网。
  Future<void> autoDetect() async {
    await _restore();
    final cfg = state;
    final lanOk = cfg.hasLanUrl && await probeServer(cfg.lanUrl) == null;
    await setActiveNetwork(lanOk ? 'lan' : 'wan');
  }

  /// 测试连接：优先探测内网，内网不可用再探测外网。
  ///
  /// 返回结果并同步切换当前生效网络。
  Future<ServerTestResult> testConnection() async {
    await _restore();
    final cfg = state;

    // 优先内网
    if (cfg.hasLanUrl) {
      final lanError = await probeServer(cfg.lanUrl);
      if (lanError == null) {
        await setActiveNetwork('lan');
        return const ServerTestResult(ok: true, message: '连接成功（内网）');
      }
      await setActiveNetwork('wan');
      return ServerTestResult(
        ok: false,
        message: '连接失败（内网）（$lanError）',
      );
    }

    // 未配置内网，直接测外网
    final wanError = await probeServer(cfg.wanUrl);
    if (wanError == null) {
      await setActiveNetwork('wan');
      return const ServerTestResult(ok: true, message: '连接成功（外网）');
    }
    return ServerTestResult(
      ok: false,
      message: '连接失败（外网）（$wanError）',
    );
  }

  static String _normalize(String url) {
    final t = url.trim();
    if (t.isEmpty) return '';
    return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
  }
}

/// 当前生效的服务端主机地址（供 URL 拼接与 Dio baseUrl 使用）。
final apiBaseUrlProvider = Provider<String>((ref) => ref.watch(serverConfigProvider).baseUrl);

/// 启动引导：恢复服务器配置并完成内网/外网探测。
///
/// 探测在首帧渲染后进行（不再阻塞 `runApp`），期间 `MyhubApp` 显示启动
/// loading 页（BootSplash），完成后放行主界面，保证首页首次请求即使用
/// 正确的基础地址。
final bootProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  final server = ref.read(serverConfigProvider.notifier);
  await server.ensureRestored();
  await server.autoDetect();
});
