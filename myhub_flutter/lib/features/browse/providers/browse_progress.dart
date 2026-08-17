import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/data/database/app_database.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';

/// 浏览页进度映射：当前路径源下 `文件路径 -> 本地进度记录`。
///
/// 数据源为本地 drift 表（实时流）：播放器每 5 秒上报、阅读器保存、
/// "正在阅读"页远端合并回写都会更新本地表，此 Provider 自动推送最新
/// 数据，文件条目据此刷新进度圆环，无需每次打开浏览页都请求后端。
final browseProgressProvider = StreamProvider<Map<String, LocalProgressData>>(
  (ref) {
    final source = ref.watch(effectiveSourceProvider);
    if (source == null) return Stream.value(const {});
    return ref
        .watch(appDatabaseProvider)
        .watchProgressBySource(source.id)
        .map(
          (rows) => {for (final r in rows) r.filePath: r},
        );
  },
);
