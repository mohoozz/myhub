import 'package:freezed_annotation/freezed_annotation.dart';

part 'reading_progress.freezed.dart';
part 'reading_progress.g.dart';

/// 阅读/播放进度（对应后端 reading_progress 表）。
@freezed
abstract class ReadingProgress with _$ReadingProgress {
  const factory ReadingProgress({
    required int id,
    required int sourceId,
    required String filePath,
    required String mediaType,
    @Default('') String title,
    @Default('') String cover,
    @Default('') String progressJson,
    @Default(0) double percent,
    @Default(false) bool finished,
    DateTime? updatedAt,
  }) = _ReadingProgress;

  factory ReadingProgress.fromJson(Map<String, dynamic> json) =>
      _$ReadingProgressFromJson(json);
}
