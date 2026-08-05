// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'reading_progress.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ReadingProgressImpl _$$ReadingProgressImplFromJson(
  Map<String, dynamic> json,
) => _$ReadingProgressImpl(
  id: (json['id'] as num).toInt(),
  sourceId: (json['source_id'] as num).toInt(),
  filePath: json['file_path'] as String,
  mediaType: json['media_type'] as String,
  title: json['title'] as String? ?? '',
  cover: json['cover'] as String? ?? '',
  progressJson: json['progress_json'] as String? ?? '',
  percent: (json['percent'] as num?)?.toDouble() ?? 0,
  finished: json['finished'] as bool? ?? false,
  updatedAt: json['updated_at'] == null
      ? null
      : DateTime.parse(json['updated_at'] as String),
);

Map<String, dynamic> _$$ReadingProgressImplToJson(
  _$ReadingProgressImpl instance,
) => <String, dynamic>{
  'id': instance.id,
  'source_id': instance.sourceId,
  'file_path': instance.filePath,
  'media_type': instance.mediaType,
  'title': instance.title,
  'cover': instance.cover,
  'progress_json': instance.progressJson,
  'percent': instance.percent,
  'finished': instance.finished,
  'updated_at': instance.updatedAt?.toIso8601String(),
};
