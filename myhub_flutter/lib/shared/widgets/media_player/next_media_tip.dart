import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放结束后查询同目录同类型文件列表，找出 [current] 的下一个（TODO 5.8）。
///
/// * 同类型：`mediaType` 相同（video/audio；other 不推荐——无法确定
///   下一个文件是否可播放）；
/// * 排序与浏览页展示顺序一致：优先读排序缓存 `browse.sort_cache`
///   （按 路径源+目录 记忆，见 browse_provider.dart），无记录时名称升序；
/// * 当前文件是目录内最后一个（或不在列表中）时返回 null，不提示；
/// * 目录查询/缓存解析失败静默返回 null，不影响播放。
Future<FileItem?> findNextMediaItem({
  required FileApi fileApi,
  required int sourceId,
  required FileItem current,
}) async {
  if (!current.isVideo && !current.isAudio) return null;
  final path = current.path;
  final slash = path.lastIndexOf('/');
  final dir = slash <= 0 ? '/' : path.substring(0, slash);

  try {
    final raw = await fileApi.listFiles(sourceId, dir);
    // 过滤出同目录同类型文件（目录与其他类型不参与推荐）
    final siblings = raw
        .map((e) => FileItem.fromJson(e as Map<String, dynamic>))
        .where((e) => !e.isDir && e.mediaType == current.mediaType)
        .toList();
    // 排序：与 visibleFilesProvider 的组内规则一致（此处已无目录，直接比较）
    final (field, ascending) = await _readSortCache(sourceId, dir);
    int compare(FileItem a, FileItem b) {
      final result = switch (field) {
        'size' => a.size.compareTo(b.size),
        'modTime' => (a.modTime ?? DateTime(1970))
            .compareTo(b.modTime ?? DateTime(1970)),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return ascending ? result : -result;
    }

    siblings.sort(compare);
    final idx = siblings.indexWhere((e) => e.path == current.path);
    if (idx < 0 || idx + 1 >= siblings.length) return null;
    return siblings[idx + 1];
  } catch (_) {
    return null; // 目录查询失败：不提示
  }
}

/// 读取浏览页排序缓存（`browse.sort_cache`，key 为 `sourceId|dir`）。
///
/// 返回 (字段, 升序)；无缓存/解析失败时回退 (name, true)。
/// 直接读 SharedPreferences 原始缓存而非 sortProvider：后者跟随浏览页
/// 当前目录，播放期间通常指向别处。
Future<(String, bool)> _readSortCache(int sourceId, String dir) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('browse.sort_cache');
    if (raw == null || raw.isEmpty) return ('name', true);
    final cache = jsonDecode(raw) as Map<String, dynamic>;
    final entry = cache['$sourceId|$dir'];
    if (entry is! Map) return ('name', true);
    final f = entry['f'] as String?;
    final field = (f == 'name' || f == 'size' || f == 'modTime') ? f! : 'name';
    return (field, entry['asc'] as bool? ?? true);
  } catch (_) {
    return ('name', true);
  }
}

/// 底部"下一个：xxx"推荐提示条（TODO 5.8）。
///
/// 全屏覆盖层：
/// * 点击提示条以外的空白区域 → 关闭（[onDismiss]）；
/// * 点击条身或"播放"按钮 → 立即播放下一个（[onPlay]）；
/// * SnackBar 风格深色圆角条，底部居中（最大宽度 560，桌面端不横贯全屏），
///   底部避开控制栏（播完时常显）约 96 逻辑像素。
class NextMediaTip extends StatelessWidget {
  const NextMediaTip({
    super.key,
    required this.file,
    required this.onPlay,
    required this.onDismiss,
  });

  /// 推荐播放的下一个文件。
  final FileItem file;

  /// 立即播放。
  final VoidCallback onPlay;

  /// 关闭提示。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        // 不绘制遮罩（播放背景已是黑色）：仅拦截点击，空白处点击关闭，
        // 同时避免误触下层控制栏按钮
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            minimum: const EdgeInsets.only(bottom: 96),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: FractionalTranslation(
                      translation: Offset(0, 0.4 * (1 - t)),
                      child: child,
                    ),
                  ),
                  child: GestureDetector(
                    onTap: onPlay,
                    child: _buildBar(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    return Material(
      color: const Color(0xF0141414),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.listVideo,
              size: 18,
              color: Colors.white54,
            ),
            const SizedBox(width: 10),
            const Text(
              '下一个',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              icon: const Icon(LucideIcons.x, size: 16),
              color: Colors.white54,
              onPressed: onDismiss,
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: Colors.white,
                foregroundColor: Colors.black87,
              ),
              onPressed: onPlay,
              icon: const Icon(LucideIcons.play, size: 14),
              label: const Text('播放'),
            ),
          ],
        ),
      ),
    );
  }
}
