import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_reader.dart';
import 'package:myhub_flutter/shared/widgets/image_preview/image_preview.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_reader.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';
import 'package:myhub_flutter/shared/widgets/text_viewer/text_viewer.dart';

/// 打开 EPUB 文件：先在路由层检测是否为图集型（漫画），再决定进入
/// EPUB 阅读器还是漫画阅读器，避免先闪现 EPUB 阅读器再跳转的白屏问题。
///
/// 返回的 Future 在阅读器页面关闭后完成，调用方可据此刷新列表。
Future<void> openEpubFile(
  BuildContext context,
  WidgetRef ref, {
  required int sourceId,
  required FileItem file,
}) async {
  // 先经漫画识别接口判定（对 EPUB 做图集型判定；远程源按块 Range
  // 缓存读取，仅下载所需字节块，比 epub/meta 整包加载更轻量）
  bool isComic;
  try {
    final res = await ref.read(comicApiProvider).detect(sourceId, file.path);
    isComic = res['is_comic'] == true;
  } catch (_) {
    // 检测失败：按普通 EPUB 打开（EpubReaderPage 内部仍会兜底判定）
    isComic = false;
  }
  if (!context.mounted) return;
  if (isComic) {
    await ComicReaderPage.open(context, sourceId: sourceId, file: file);
  } else {
    await EpubReaderPage.open(context, sourceId: sourceId, file: file);
  }
}

/// 按媒体类型打开对应播放器/阅读器（收藏页、正在阅读页共用）：
///
/// * video/audio → 统一播放器；
/// * novel → epub 走 EPUB 阅读器；txt 默认走纯文本阅读器
///   （[novelReader] 为 true 时才走小说阅读器，且仅在 txt 上生效）；
/// * comic → 漫画阅读器；
/// * archive → 后端内容嗅探，漫画则路由到漫画阅读器。
///
/// 返回的 Future 在播放器/阅读器页面关闭后完成，调用方可据此刷新列表。
Future<void> openMediaItem(
  BuildContext context,
  WidgetRef ref, {
  required int sourceId,
  required String filePath,
  required String mediaType,
  int size = 0,

  /// true 时 txt 文件改用小说阅读器打开（记录阅读进度）。
  /// 仅对 mediaType == 'novel' 且非 epub 生效；epub 恒为 EPUB 阅读器。
  bool novelReader = false,
}) async {
  final file = FileItem(
    name: filePath.split('/').last,
    path: filePath,
    size: size,
    mediaType: mediaType,
  );
  if (mediaType == 'video' || mediaType == 'audio') {
    // 迷你条在播时保持迷你模式直接切歌，否则进全屏播放页
    await MediaPlayerPage.openOrMini(context, ref,
        sourceId: sourceId, file: file);
    return;
  }
  if (mediaType == 'novel') {
    if (filePath.toLowerCase().endsWith('.epub')) {
      await openEpubFile(context, ref, sourceId: sourceId, file: file);
    } else if (novelReader) {
      // 以小说阅读器打开：记录章节/页内阅读进度
      await NovelReaderPage.open(context, sourceId: sourceId, file: file);
    } else {
      // 默认纯文本阅读器（不记录阅读进度）
      await PlainTextViewerPage.open(context, sourceId: sourceId, file: file);
    }
    return;
  }
  if (mediaType == 'comic') {
    await ComicReaderPage.open(context, sourceId: sourceId, file: file);
    return;
  }
  if (mediaType == 'image') {
    // 纯图片：进入独立预览页（此处无同目录列表，仅展示单张）
    await ImagePreviewPage.open(context, sourceId: sourceId, file: file);
    return;
  }
  if (mediaType == 'archive') {
    // 压缩包：直接进入漫画阅读器，由阅读器内部嗅探判定是否为漫画
    // 并立即展示加载界面（避免嗅探期间无反馈）
    await ComicReaderPage.open(context, sourceId: sourceId, file: file);
    return;
  }
  // 不支持预览的文件：底部弹出菜单栏，含"以纯文本打开"选项
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.fileText),
            title: const Text('以纯文本打开'),
            subtitle: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              PlainTextViewerPage.open(context, sourceId: sourceId, file: file);
            },
          ),
          const SizedBox(height: 4),
        ],
      ),
    ),
  );
}
