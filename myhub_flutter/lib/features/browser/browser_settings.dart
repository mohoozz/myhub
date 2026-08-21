import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:myhub_flutter/features/settings/providers/app_config_provider.dart';

/// 默认搜索引擎选项。
enum SearchEngine {
  google('Google', 'https://www.google.com/search?q={query}'),
  bing('Bing', 'https://www.bing.com/search?q={query}'),
  baidu('百度', 'https://www.baidu.com/s?wd={query}'),
  custom('自定义', '');

  const SearchEngine(this.label, this.urlTemplate);

  final String label;

  /// 搜索 URL 模板（`{query}` 占位符）。
  final String urlTemplate;
}

/// 默认 UA 选项。
enum UserAgentMode {
  followPlatform('跟随平台'),
  desktop('桌面'),
  mobile('移动');

  const UserAgentMode(this.label);

  final String label;
}

/// 常用 UA 字符串（桌面 Chrome / 移动 Chrome）。
const String kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const String kMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 浏览器设置（F-605）：从 `/api/config` 读取，类型化封装。
@immutable
class BrowserSettings {
  const BrowserSettings({
    this.searchEngine = SearchEngine.bing,
    this.customSearchUrl = '',
    this.userAgent = UserAgentMode.followPlatform,
  });

  final SearchEngine searchEngine;
  final String customSearchUrl;
  final UserAgentMode userAgent;

  /// 搜索 URL 模板（含 `{query}` 占位符），供 [resolveNavigationUrl] 使用。
  String get searchUrlTemplate => switch (searchEngine) {
    SearchEngine.custom => customSearchUrl,
    _ => searchEngine.urlTemplate,
  };

  /// 实际 UA 字符串；[UserAgentMode.followPlatform] 返回空（用平台默认）。
  String? get userAgentString => switch (userAgent) {
    UserAgentMode.desktop => kDesktopUserAgent,
    UserAgentMode.mobile => kMobileUserAgent,
    UserAgentMode.followPlatform => null,
  };
}

/// 浏览器设置 Provider：从 [appConfigProvider] 派生类型化设置。
final browserSettingsProvider = Provider<BrowserSettings>((ref) {
  final config = ref.watch(appConfigProvider).valueOrNull ?? const {};
  final engine = config[AppConfigKeys.browserSearchEngine] ?? 'bing';
  final customUrl = config[AppConfigKeys.browserCustomSearchUrl] ?? '';
  final ua = config[AppConfigKeys.browserUserAgent] ?? 'follow_platform';

  return BrowserSettings(
    searchEngine: SearchEngine.values.firstWhere(
      (e) => e.name == engine,
      orElse: () => SearchEngine.bing,
    ),
    customSearchUrl: customUrl,
    userAgent: UserAgentMode.values.firstWhere(
      (e) => e.name == ua,
      orElse: () => UserAgentMode.followPlatform,
    ),
  );
});
