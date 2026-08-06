// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'comic.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ComicDetectImpl _$$ComicDetectImplFromJson(Map<String, dynamic> json) =>
    _$ComicDetectImpl(
      isComic: json['is_comic'] as bool? ?? false,
      reason: json['reason'] as String? ?? 'none',
    );

Map<String, dynamic> _$$ComicDetectImplToJson(_$ComicDetectImpl instance) =>
    <String, dynamic>{'is_comic': instance.isComic, 'reason': instance.reason};

_$ComicPageImpl _$$ComicPageImplFromJson(Map<String, dynamic> json) =>
    _$ComicPageImpl(
      index: (json['index'] as num).toInt(),
      name: json['name'] as String,
      size: (json['size'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ComicPageImplToJson(_$ComicPageImpl instance) =>
    <String, dynamic>{
      'index': instance.index,
      'name': instance.name,
      'size': instance.size,
      'width': instance.width,
      'height': instance.height,
    };

_$ComicPagesImpl _$$ComicPagesImplFromJson(Map<String, dynamic> json) =>
    _$ComicPagesImpl(
      pages:
          (json['pages'] as List<dynamic>?)
              ?.map((e) => ComicPage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      total: (json['total'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ComicPagesImplToJson(_$ComicPagesImpl instance) =>
    <String, dynamic>{
      'pages': instance.pages.map((e) => e.toJson()).toList(),
      'total': instance.total,
    };

_$ArchiveEntryImpl _$$ArchiveEntryImplFromJson(Map<String, dynamic> json) =>
    _$ArchiveEntryImpl(
      name: json['name'] as String,
      size: (json['size'] as num?)?.toInt() ?? 0,
      isDir: json['is_dir'] as bool? ?? false,
    );

Map<String, dynamic> _$$ArchiveEntryImplToJson(_$ArchiveEntryImpl instance) =>
    <String, dynamic>{
      'name': instance.name,
      'size': instance.size,
      'is_dir': instance.isDir,
    };

_$ArchiveTreeImpl _$$ArchiveTreeImplFromJson(Map<String, dynamic> json) =>
    _$ArchiveTreeImpl(
      entries:
          (json['entries'] as List<dynamic>?)
              ?.map((e) => ArchiveEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      total: (json['total'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ArchiveTreeImplToJson(_$ArchiveTreeImpl instance) =>
    <String, dynamic>{
      'entries': instance.entries.map((e) => e.toJson()).toList(),
      'total': instance.total,
    };
