import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 漫画阅读模式（TODO 7.2）。
enum ComicViewMode {
  /// 单页：PageView 左右滑动翻页。
  single,

  /// 双页：横屏/平板适用，每屏两张图。
  double,

  /// 条漫：纵向连续滚动。
  webtoon,
}

/// 漫画阅读方向（双页模式生效）。
enum ComicReadingDirection {
  /// 从左向右（国漫/美漫）。
  ltr,

  /// 从右向左（日漫，默认）。
  rtl,
}

/// 漫画阅读器偏好设置。
class ComicReaderSettings {
  const ComicReaderSettings({
    this.viewMode,
    this.direction,
    this.webtoonWidthFactor,
  });

  /// 阅读模式；null = 自动（横屏/宽屏双页，其余单页）。
  final ComicViewMode? viewMode;

  /// 双页阅读方向；null = 默认日漫 rtl。
  final ComicReadingDirection? direction;

  /// 条漫宽度占比（0.3~1.0）；null = 默认占满全宽。
  final double? webtoonWidthFactor;

  /// 实际阅读方向（缺省 rtl）。
  ComicReadingDirection get effectiveDirection =>
      direction ?? ComicReadingDirection.rtl;

  /// 实际条漫宽度占比（缺省 1.0 占满全宽）。
  double get effectiveWebtoonWidthFactor => webtoonWidthFactor ?? 1.0;

  ComicReaderSettings copyWith({
    ComicViewMode? Function()? viewMode,
    ComicReadingDirection? Function()? direction,
    double? Function()? webtoonWidthFactor,
  }) {
    return ComicReaderSettings(
      viewMode: viewMode != null ? viewMode() : this.viewMode,
      direction: direction != null ? direction() : this.direction,
      webtoonWidthFactor: webtoonWidthFactor != null
          ? webtoonWidthFactor()
          : this.webtoonWidthFactor,
    );
  }
}

/// 漫画阅读器设置 Provider（持久化到 SharedPreferences）。
final comicReaderSettingsProvider =
    NotifierProvider<ComicReaderSettingsNotifier, ComicReaderSettings>(
  ComicReaderSettingsNotifier.new,
);

class ComicReaderSettingsNotifier extends Notifier<ComicReaderSettings> {
  static const _kViewMode = 'comic.view_mode';
  static const _kDirection = 'comic.direction';
  static const _kWebtoonWidth = 'comic.webtoon_width';

  /// 标记用户已显式修改（防止异步恢复覆盖新值）。
  var _dirty = false;

  @override
  ComicReaderSettings build() {
    _restore();
    return const ComicReaderSettings();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_dirty) return;
    state = ComicReaderSettings(
      viewMode: ComicViewMode.values.asNameMap()[prefs.getString(_kViewMode)],
      direction: ComicReadingDirection.values
          .asNameMap()[prefs.getString(_kDirection)],
      webtoonWidthFactor: prefs.getDouble(_kWebtoonWidth),
    );
  }

  /// 切换阅读模式（持久化；此后不再随横竖屏自动切换）。
  /// 传 null 恢复自动（横屏/宽屏双页，其余单页）。
  Future<void> setViewMode(ComicViewMode? mode) async {
    _dirty = true;
    state = state.copyWith(viewMode: () => mode);
    final prefs = await SharedPreferences.getInstance();
    if (mode == null) {
      await prefs.remove(_kViewMode);
    } else {
      await prefs.setString(_kViewMode, mode.name);
    }
  }

  /// 切换双页阅读方向（持久化）。
  Future<void> setDirection(ComicReadingDirection direction) async {
    _dirty = true;
    state = state.copyWith(direction: () => direction);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDirection, direction.name);
  }

  /// 调节条漫宽度占比（持久化）。
  Future<void> setWebtoonWidthFactor(double factor) async {
    _dirty = true;
    state = state.copyWith(webtoonWidthFactor: () => factor);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kWebtoonWidth, factor);
  }
}
