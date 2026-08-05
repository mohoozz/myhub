import 'package:freezed_annotation/freezed_annotation.dart';

part 'user.freezed.dart';
part 'user.g.dart';

/// 用户（对应后端 users 表；password_hash 不下发）。
@freezed
abstract class User with _$User {
  const factory User({
    required int id,
    required String username,
    DateTime? createdAt,
  }) = _User;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
}
