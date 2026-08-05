// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'source.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$SourceImpl _$$SourceImplFromJson(Map<String, dynamic> json) => _$SourceImpl(
  id: (json['id'] as num).toInt(),
  name: json['name'] as String,
  type: $enumDecode(_$SourceTypeEnumMap, json['type']),
  configJson: json['config_json'] as String? ?? '',
  mountPoint: json['mount_point'] as String? ?? '',
  enabled: json['enabled'] as bool? ?? true,
  createdAt: json['created_at'] == null
      ? null
      : DateTime.parse(json['created_at'] as String),
);

Map<String, dynamic> _$$SourceImplToJson(_$SourceImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'type': _$SourceTypeEnumMap[instance.type]!,
      'config_json': instance.configJson,
      'mount_point': instance.mountPoint,
      'enabled': instance.enabled,
      'created_at': instance.createdAt?.toIso8601String(),
    };

const _$SourceTypeEnumMap = {
  SourceType.local: 'local',
  SourceType.webdav: 'webdav',
  SourceType.openlist: 'openlist',
};
