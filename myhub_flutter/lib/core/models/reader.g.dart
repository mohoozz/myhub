// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'reader.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$NovelChapterImpl _$$NovelChapterImplFromJson(Map<String, dynamic> json) =>
    _$NovelChapterImpl(
      index: (json['index'] as num).toInt(),
      title: json['title'] as String,
    );

Map<String, dynamic> _$$NovelChapterImplToJson(_$NovelChapterImpl instance) =>
    <String, dynamic>{'index': instance.index, 'title': instance.title};

_$NovelChaptersImpl _$$NovelChaptersImplFromJson(Map<String, dynamic> json) =>
    _$NovelChaptersImpl(
      ready: json['ready'] as bool? ?? false,
      encoding: json['encoding'] as String? ?? '',
      chapters:
          (json['chapters'] as List<dynamic>?)
              ?.map((e) => NovelChapter.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      total: (json['total'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$NovelChaptersImplToJson(_$NovelChaptersImpl instance) =>
    <String, dynamic>{
      'ready': instance.ready,
      'encoding': instance.encoding,
      'chapters': instance.chapters.map((e) => e.toJson()).toList(),
      'total': instance.total,
    };

_$NovelContentImpl _$$NovelContentImplFromJson(Map<String, dynamic> json) =>
    _$NovelContentImpl(
      ready: json['ready'] as bool? ?? false,
      chapter: (json['chapter'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      total: (json['total'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$NovelContentImplToJson(_$NovelContentImpl instance) =>
    <String, dynamic>{
      'ready': instance.ready,
      'chapter': instance.chapter,
      'title': instance.title,
      'content': instance.content,
      'total': instance.total,
    };

_$TocItemImpl _$$TocItemImplFromJson(Map<String, dynamic> json) =>
    _$TocItemImpl(title: json['title'] as String, href: json['href'] as String);

Map<String, dynamic> _$$TocItemImplToJson(_$TocItemImpl instance) =>
    <String, dynamic>{'title': instance.title, 'href': instance.href};

_$EpubMetaImpl _$$EpubMetaImplFromJson(Map<String, dynamic> json) =>
    _$EpubMetaImpl(
      title: json['title'] as String? ?? '',
      author: json['author'] as String? ?? '',
      coverId: json['cover_id'] as String? ?? '',
      isComic: json['is_comic'] as bool? ?? false,
      toc:
          (json['toc'] as List<dynamic>?)
              ?.map((e) => TocItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$$EpubMetaImplToJson(_$EpubMetaImpl instance) =>
    <String, dynamic>{
      'title': instance.title,
      'author': instance.author,
      'cover_id': instance.coverId,
      'is_comic': instance.isComic,
      'toc': instance.toc.map((e) => e.toJson()).toList(),
    };
