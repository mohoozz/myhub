import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:myhub_flutter/core/models/file_item.dart';

/// 按媒体类型返回图标。
IconData fileIconOf(FileItem item) {
  if (item.isDir) return LucideIcons.folder;
  return switch (item.mediaType) {
    'video' => LucideIcons.film,
    'audio' => LucideIcons.music,
    'novel' => LucideIcons.bookOpen,
    'comic' => LucideIcons.images,
    'image' => LucideIcons.image,
    'archive' => LucideIcons.package,
    _ => LucideIcons.file,
  };
}

/// 图标颜色：文件夹用主题主色，其他用弱化色（不引入新色板）。
Color fileIconColorOf(BuildContext context, FileItem item) {
  final colorScheme = Theme.of(context).colorScheme;
  return item.isDir ? colorScheme.primary : colorScheme.onSurfaceVariant;
}
