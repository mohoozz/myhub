// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'file_item.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

FileItem _$FileItemFromJson(Map<String, dynamic> json) {
  return _FileItem.fromJson(json);
}

/// @nodoc
mixin _$FileItem {
  String get name => throw _privateConstructorUsedError;
  String get path => throw _privateConstructorUsedError;
  int get size => throw _privateConstructorUsedError;
  bool get isDir => throw _privateConstructorUsedError;
  DateTime? get modTime => throw _privateConstructorUsedError;
  String get mediaType => throw _privateConstructorUsedError;

  /// Serializes this FileItem to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of FileItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FileItemCopyWith<FileItem> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FileItemCopyWith<$Res> {
  factory $FileItemCopyWith(FileItem value, $Res Function(FileItem) then) =
      _$FileItemCopyWithImpl<$Res, FileItem>;
  @useResult
  $Res call({
    String name,
    String path,
    int size,
    bool isDir,
    DateTime? modTime,
    String mediaType,
  });
}

/// @nodoc
class _$FileItemCopyWithImpl<$Res, $Val extends FileItem>
    implements $FileItemCopyWith<$Res> {
  _$FileItemCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FileItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? name = null,
    Object? path = null,
    Object? size = null,
    Object? isDir = null,
    Object? modTime = freezed,
    Object? mediaType = null,
  }) {
    return _then(
      _value.copyWith(
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            path: null == path
                ? _value.path
                : path // ignore: cast_nullable_to_non_nullable
                      as String,
            size: null == size
                ? _value.size
                : size // ignore: cast_nullable_to_non_nullable
                      as int,
            isDir: null == isDir
                ? _value.isDir
                : isDir // ignore: cast_nullable_to_non_nullable
                      as bool,
            modTime: freezed == modTime
                ? _value.modTime
                : modTime // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
            mediaType: null == mediaType
                ? _value.mediaType
                : mediaType // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$FileItemImplCopyWith<$Res>
    implements $FileItemCopyWith<$Res> {
  factory _$$FileItemImplCopyWith(
    _$FileItemImpl value,
    $Res Function(_$FileItemImpl) then,
  ) = __$$FileItemImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String name,
    String path,
    int size,
    bool isDir,
    DateTime? modTime,
    String mediaType,
  });
}

/// @nodoc
class __$$FileItemImplCopyWithImpl<$Res>
    extends _$FileItemCopyWithImpl<$Res, _$FileItemImpl>
    implements _$$FileItemImplCopyWith<$Res> {
  __$$FileItemImplCopyWithImpl(
    _$FileItemImpl _value,
    $Res Function(_$FileItemImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FileItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? name = null,
    Object? path = null,
    Object? size = null,
    Object? isDir = null,
    Object? modTime = freezed,
    Object? mediaType = null,
  }) {
    return _then(
      _$FileItemImpl(
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        path: null == path
            ? _value.path
            : path // ignore: cast_nullable_to_non_nullable
                  as String,
        size: null == size
            ? _value.size
            : size // ignore: cast_nullable_to_non_nullable
                  as int,
        isDir: null == isDir
            ? _value.isDir
            : isDir // ignore: cast_nullable_to_non_nullable
                  as bool,
        modTime: freezed == modTime
            ? _value.modTime
            : modTime // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
        mediaType: null == mediaType
            ? _value.mediaType
            : mediaType // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$FileItemImpl extends _FileItem {
  const _$FileItemImpl({
    required this.name,
    required this.path,
    this.size = 0,
    this.isDir = false,
    this.modTime,
    this.mediaType = 'other',
  }) : super._();

  factory _$FileItemImpl.fromJson(Map<String, dynamic> json) =>
      _$$FileItemImplFromJson(json);

  @override
  final String name;
  @override
  final String path;
  @override
  @JsonKey()
  final int size;
  @override
  @JsonKey()
  final bool isDir;
  @override
  final DateTime? modTime;
  @override
  @JsonKey()
  final String mediaType;

  @override
  String toString() {
    return 'FileItem(name: $name, path: $path, size: $size, isDir: $isDir, modTime: $modTime, mediaType: $mediaType)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FileItemImpl &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.path, path) || other.path == path) &&
            (identical(other.size, size) || other.size == size) &&
            (identical(other.isDir, isDir) || other.isDir == isDir) &&
            (identical(other.modTime, modTime) || other.modTime == modTime) &&
            (identical(other.mediaType, mediaType) ||
                other.mediaType == mediaType));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, name, path, size, isDir, modTime, mediaType);

  /// Create a copy of FileItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FileItemImplCopyWith<_$FileItemImpl> get copyWith =>
      __$$FileItemImplCopyWithImpl<_$FileItemImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$FileItemImplToJson(this);
  }
}

abstract class _FileItem extends FileItem {
  const factory _FileItem({
    required final String name,
    required final String path,
    final int size,
    final bool isDir,
    final DateTime? modTime,
    final String mediaType,
  }) = _$FileItemImpl;
  const _FileItem._() : super._();

  factory _FileItem.fromJson(Map<String, dynamic> json) =
      _$FileItemImpl.fromJson;

  @override
  String get name;
  @override
  String get path;
  @override
  int get size;
  @override
  bool get isDir;
  @override
  DateTime? get modTime;
  @override
  String get mediaType;

  /// Create a copy of FileItem
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FileItemImplCopyWith<_$FileItemImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
