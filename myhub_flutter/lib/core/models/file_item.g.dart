// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'file_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$FileItemImpl _$$FileItemImplFromJson(Map<String, dynamic> json) =>
    _$FileItemImpl(
      name: json['name'] as String,
      path: json['path'] as String,
      size: (json['size'] as num?)?.toInt() ?? 0,
      isDir: json['is_dir'] as bool? ?? false,
      modTime: json['mod_time'] == null
          ? null
          : DateTime.parse(json['mod_time'] as String),
      mediaType: json['media_type'] as String? ?? 'other',
    );

Map<String, dynamic> _$$FileItemImplToJson(_$FileItemImpl instance) =>
    <String, dynamic>{
      'name': instance.name,
      'path': instance.path,
      'size': instance.size,
      'is_dir': instance.isDir,
      'mod_time': instance.modTime?.toIso8601String(),
      'media_type': instance.mediaType,
    };
