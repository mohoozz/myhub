import 'package:freezed_annotation/freezed_annotation.dart';

part 'reader.freezed.dart';
part 'reader.g.dart';

/// TXT 章节（章节列表项）。
@freezed
abstract class NovelChapter with _$NovelChapter {
  const factory NovelChapter({
    required int index,
    required String title,
  }) = _NovelChapter;

  factory NovelChapter.fromJson(Map<String, dynamic> json) =>
      _$NovelChapterFromJson(json);
}

/// TXT 章节列表响应（ready=false 表示索引构建中）。
@freezed
abstract class NovelChapters with _$NovelChapters {
  const factory NovelChapters({
    @Default(false) bool ready,
    @Default('') String encoding,
    @Default([]) List<NovelChapter> chapters,
    @Default(0) int total,
  }) = _NovelChapters;

  factory NovelChapters.fromJson(Map<String, dynamic> json) =>
      _$NovelChaptersFromJson(json);
}

/// TXT 章节内容响应。
@freezed
abstract class NovelContent with _$NovelContent {
  const factory NovelContent({
    @Default(false) bool ready,
    @Default(0) int chapter,
    @Default('') String title,
    @Default('') String content,
    @Default(0) int total,
  }) = _NovelContent;

  factory NovelContent.fromJson(Map<String, dynamic> json) =>
      _$NovelContentFromJson(json);
}

/// EPUB 目录项。
@freezed
abstract class TocItem with _$TocItem {
  const factory TocItem({
    required String title,
    required String href,
  }) = _TocItem;

  factory TocItem.fromJson(Map<String, dynamic> json) =>
      _$TocItemFromJson(json);
}

/// EPUB 元数据。
@freezed
abstract class EpubMeta with _$EpubMeta {
  const factory EpubMeta({
    @Default('') String title,
    @Default('') String author,
    @Default('') String coverId,
    @Default(false) bool isComic,
    @Default([]) List<TocItem> toc,
  }) = _EpubMeta;

  factory EpubMeta.fromJson(Map<String, dynamic> json) =>
      _$EpubMetaFromJson(json);
}
