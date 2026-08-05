import 'package:freezed_annotation/freezed_annotation.dart';

part 'comic.freezed.dart';
part 'comic.g.dart';

/// 漫画识别结果。
@freezed
abstract class ComicDetect with _$ComicDetect {
  const factory ComicDetect({
    @Default(false) bool isComic,
    @Default('none') String reason,
  }) = _ComicDetect;

  factory ComicDetect.fromJson(Map<String, dynamic> json) =>
      _$ComicDetectFromJson(json);
}

/// 漫画页。
@freezed
abstract class ComicPage with _$ComicPage {
  const factory ComicPage({
    required int index,
    required String name,
    @Default(0) int size,
  }) = _ComicPage;

  factory ComicPage.fromJson(Map<String, dynamic> json) =>
      _$ComicPageFromJson(json);
}

/// 漫画页列表响应。
@freezed
abstract class ComicPages with _$ComicPages {
  const factory ComicPages({
    @Default([]) List<ComicPage> pages,
    @Default(0) int total,
  }) = _ComicPages;

  factory ComicPages.fromJson(Map<String, dynamic> json) =>
      _$ComicPagesFromJson(json);
}

/// 压缩包条目。
@freezed
abstract class ArchiveEntry with _$ArchiveEntry {
  const factory ArchiveEntry({
    required String name,
    @Default(0) int size,
    @Default(false) bool isDir,
  }) = _ArchiveEntry;

  factory ArchiveEntry.fromJson(Map<String, dynamic> json) =>
      _$ArchiveEntryFromJson(json);
}

/// 压缩包文件树响应。
@freezed
abstract class ArchiveTree with _$ArchiveTree {
  const factory ArchiveTree({
    @Default([]) List<ArchiveEntry> entries,
    @Default(0) int total,
  }) = _ArchiveTree;

  factory ArchiveTree.fromJson(Map<String, dynamic> json) =>
      _$ArchiveTreeFromJson(json);
}
