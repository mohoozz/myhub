import 'package:freezed_annotation/freezed_annotation.dart';

part 'source.freezed.dart';
part 'source.g.dart';

/// 路径源类型。
enum SourceType {
  @JsonValue('local')
  local,
  @JsonValue('webdav')
  webdav,
  @JsonValue('openlist')
  openlist,
}

/// 路径源（对应后端 sources 表）。
@freezed
abstract class Source with _$Source {
  const factory Source({
    required int id,
    required String name,
    required SourceType type,
    @Default('') String configJson,
    @Default('') String mountPoint,
    @Default(true) bool enabled,
    DateTime? createdAt,
  }) = _Source;

  factory Source.fromJson(Map<String, dynamic> json) =>
      _$SourceFromJson(json);
}
