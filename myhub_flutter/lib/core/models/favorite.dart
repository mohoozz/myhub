import 'package:freezed_annotation/freezed_annotation.dart';

part 'favorite.freezed.dart';
part 'favorite.g.dart';

/// 收藏条目（对应后端 favorites 表）。
@freezed
abstract class Favorite with _$Favorite {
  const factory Favorite({
    required int id,
    required int sourceId,
    required String filePath,
    @Default('') String mediaType,
    @Default(0) int size,
    DateTime? createdAt,
  }) = _Favorite;

  factory Favorite.fromJson(Map<String, dynamic> json) =>
      _$FavoriteFromJson(json);
}

/// 收藏分页列表响应。
@freezed
abstract class FavoritePage with _$FavoritePage {
  const factory FavoritePage({
    @Default([]) List<Favorite> list,
    @Default(0) int total,
    @Default(1) int page,
    @Default(50) int pageSize,
  }) = _FavoritePage;

  factory FavoritePage.fromJson(Map<String, dynamic> json) =>
      _$FavoritePageFromJson(json);
}
