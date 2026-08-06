import 'package:freezed_annotation/freezed_annotation.dart';

part 'file_item.freezed.dart';
part 'file_item.g.dart';

/// 文件列表项（GET /api/files 返回，含媒体类型识别结果）。
@freezed
abstract class FileItem with _$FileItem {
  const factory FileItem({
    required String name,
    required String path,
    @Default(0) int size,
    @Default(false) bool isDir,
    DateTime? modTime,
    @Default('other') String mediaType,
  }) = _FileItem;

  const FileItem._();

  factory FileItem.fromJson(Map<String, dynamic> json) =>
      _$FileItemFromJson(json);

  bool get isVideo => mediaType == 'video';
  bool get isAudio => mediaType == 'audio';
  bool get isNovel => mediaType == 'novel';
  bool get isComic => mediaType == 'comic';
  bool get isImage => mediaType == 'image';
  bool get isArchive => mediaType == 'archive';
}
