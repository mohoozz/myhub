// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'favorite.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$FavoriteImpl _$$FavoriteImplFromJson(Map<String, dynamic> json) =>
    _$FavoriteImpl(
      id: (json['id'] as num).toInt(),
      sourceId: (json['source_id'] as num).toInt(),
      filePath: json['file_path'] as String,
      mediaType: json['media_type'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.parse(json['created_at'] as String),
    );

Map<String, dynamic> _$$FavoriteImplToJson(_$FavoriteImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'source_id': instance.sourceId,
      'file_path': instance.filePath,
      'media_type': instance.mediaType,
      'size': instance.size,
      'created_at': instance.createdAt?.toIso8601String(),
    };

_$FavoritePageImpl _$$FavoritePageImplFromJson(Map<String, dynamic> json) =>
    _$FavoritePageImpl(
      list:
          (json['list'] as List<dynamic>?)
              ?.map((e) => Favorite.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 50,
    );

Map<String, dynamic> _$$FavoritePageImplToJson(_$FavoritePageImpl instance) =>
    <String, dynamic>{
      'list': instance.list.map((e) => e.toJson()).toList(),
      'total': instance.total,
      'page': instance.page,
      'page_size': instance.pageSize,
    };
