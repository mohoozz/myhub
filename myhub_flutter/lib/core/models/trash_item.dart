import 'package:freezed_annotation/freezed_annotation.dart';

part 'trash_item.freezed.dart';
part 'trash_item.g.dart';

/// 回收站条目（对应后端 trash_items 表）。
@freezed
abstract class TrashItem with _$TrashItem {
  const factory TrashItem({
    required int id,
    required int sourceId,
    required String originalPath,
    required String trashPath,
    @Default(0) int size,
    DateTime? deletedAt,
  }) = _TrashItem;

  factory TrashItem.fromJson(Map<String, dynamic> json) =>
      _$TrashItemFromJson(json);
}
