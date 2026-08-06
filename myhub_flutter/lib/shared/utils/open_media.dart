import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/comic_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/utils/top_snack_bar.dart';
import 'package:myhub_flutter/shared/widgets/comic_reader/comic_reader.dart';
import 'package:myhub_flutter/shared/widgets/media_player/media_player.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/epub_reader.dart';
import 'package:myhub_flutter/shared/widgets/novel_reader/novel_reader.dart';

/// 按媒体类型打开对应播放器/阅读器（收藏页、正在阅读页共用）：
///
/// * video/audio → 统一播放器；
/// * novel → txt 走 TXT 阅读器，epub 走 EPUB 阅读器；
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
      await EpubReaderPage.open(context, sourceId: sourceId, file: file);
    } else {
      await NovelReaderPage.open(context, sourceId: sourceId, file: file);
    }
    return;
  }
  if (mediaType == 'comic') {
    await ComicReaderPage.open(context, sourceId: sourceId, file: file);
    return;
  }
  if (mediaType == 'archive') {
    // 普通压缩包：后端内容嗅探，漫画则路由到漫画阅读器
    try {
      final res = await ref.read(comicApiProvider).detect(sourceId, filePath);
      if (!context.mounted) return;
      if (res['is_comic'] == true) {
        await ComicReaderPage.open(context, sourceId: sourceId, file: file);
        return;
      }
      showTopSnackBar(context, '该压缩包不是漫画，暂不支持浏览');
    } catch (e) {
      if (!context.mounted) return;
      showTopSnackBar(context, '打开失败：$e');
    }
    return;
  }
  showTopSnackBar(context, '打开 ${filePath.split('/').last}');
}
