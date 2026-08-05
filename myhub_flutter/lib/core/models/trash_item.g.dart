// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trash_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$TrashItemImpl _$$TrashItemImplFromJson(Map<String, dynamic> json) =>
    _$TrashItemImpl(
      id: (json['id'] as num).toInt(),
      sourceId: (json['source_id'] as num).toInt(),
      originalPath: json['original_path'] as String,
      trashPath: json['trash_path'] as String,
      size: (json['size'] as num?)?.toInt() ?? 0,
      deletedAt: json['deleted_at'] == null
          ? null
          : DateTime.parse(json['deleted_at'] as String),
    );

Map<String, dynamic> _$$TrashItemImplToJson(_$TrashItemImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'source_id': instance.sourceId,
      'original_path': instance.originalPath,
      'trash_path': instance.trashPath,
      'size': instance.size,
      'deleted_at': instance.deletedAt?.toIso8601String(),
    };
