// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'trash_item.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

TrashItem _$TrashItemFromJson(Map<String, dynamic> json) {
  return _TrashItem.fromJson(json);
}

/// @nodoc
mixin _$TrashItem {
  int get id => throw _privateConstructorUsedError;
  int get sourceId => throw _privateConstructorUsedError;
  String get originalPath => throw _privateConstructorUsedError;
  String get trashPath => throw _privateConstructorUsedError;
  int get size => throw _privateConstructorUsedError;
  DateTime? get deletedAt => throw _privateConstructorUsedError;

  /// Serializes this TrashItem to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of TrashItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $TrashItemCopyWith<TrashItem> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $TrashItemCopyWith<$Res> {
  factory $TrashItemCopyWith(TrashItem value, $Res Function(TrashItem) then) =
      _$TrashItemCopyWithImpl<$Res, TrashItem>;
  @useResult
  $Res call({
    int id,
    int sourceId,
    String originalPath,
    String trashPath,
    int size,
    DateTime? deletedAt,
  });
}

/// @nodoc
class _$TrashItemCopyWithImpl<$Res, $Val extends TrashItem>
    implements $TrashItemCopyWith<$Res> {
  _$TrashItemCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of TrashItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? sourceId = null,
    Object? originalPath = null,
    Object? trashPath = null,
    Object? size = null,
    Object? deletedAt = freezed,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as int,
            sourceId: null == sourceId
                ? _value.sourceId
                : sourceId // ignore: cast_nullable_to_non_nullable
                      as int,
            originalPath: null == originalPath
                ? _value.originalPath
                : originalPath // ignore: cast_nullable_to_non_nullable
                      as String,
            trashPath: null == trashPath
                ? _value.trashPath
                : trashPath // ignore: cast_nullable_to_non_nullable
                      as String,
            size: null == size
                ? _value.size
                : size // ignore: cast_nullable_to_non_nullable
                      as int,
            deletedAt: freezed == deletedAt
                ? _value.deletedAt
                : deletedAt // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$TrashItemImplCopyWith<$Res>
    implements $TrashItemCopyWith<$Res> {
  factory _$$TrashItemImplCopyWith(
    _$TrashItemImpl value,
    $Res Function(_$TrashItemImpl) then,
  ) = __$$TrashItemImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    int id,
    int sourceId,
    String originalPath,
    String trashPath,
    int size,
    DateTime? deletedAt,
  });
}

/// @nodoc
class __$$TrashItemImplCopyWithImpl<$Res>
    extends _$TrashItemCopyWithImpl<$Res, _$TrashItemImpl>
    implements _$$TrashItemImplCopyWith<$Res> {
  __$$TrashItemImplCopyWithImpl(
    _$TrashItemImpl _value,
    $Res Function(_$TrashItemImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of TrashItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? sourceId = null,
    Object? originalPath = null,
    Object? trashPath = null,
    Object? size = null,
    Object? deletedAt = freezed,
  }) {
    return _then(
      _$TrashItemImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as int,
        sourceId: null == sourceId
            ? _value.sourceId
            : sourceId // ignore: cast_nullable_to_non_nullable
                  as int,
        originalPath: null == originalPath
            ? _value.originalPath
            : originalPath // ignore: cast_nullable_to_non_nullable
                  as String,
        trashPath: null == trashPath
            ? _value.trashPath
            : trashPath // ignore: cast_nullable_to_non_nullable
                  as String,
        size: null == size
            ? _value.size
            : size // ignore: cast_nullable_to_non_nullable
                  as int,
        deletedAt: freezed == deletedAt
            ? _value.deletedAt
            : deletedAt // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$TrashItemImpl implements _TrashItem {
  const _$TrashItemImpl({
    required this.id,
    required this.sourceId,
    required this.originalPath,
    required this.trashPath,
    this.size = 0,
    this.deletedAt,
  });

  factory _$TrashItemImpl.fromJson(Map<String, dynamic> json) =>
      _$$TrashItemImplFromJson(json);

  @override
  final int id;
  @override
  final int sourceId;
  @override
  final String originalPath;
  @override
  final String trashPath;
  @override
  @JsonKey()
  final int size;
  @override
  final DateTime? deletedAt;

  @override
  String toString() {
    return 'TrashItem(id: $id, sourceId: $sourceId, originalPath: $originalPath, trashPath: $trashPath, size: $size, deletedAt: $deletedAt)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$TrashItemImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.sourceId, sourceId) ||
                other.sourceId == sourceId) &&
            (identical(other.originalPath, originalPath) ||
                other.originalPath == originalPath) &&
            (identical(other.trashPath, trashPath) ||
                other.trashPath == trashPath) &&
            (identical(other.size, size) || other.size == size) &&
            (identical(other.deletedAt, deletedAt) ||
                other.deletedAt == deletedAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    sourceId,
    originalPath,
    trashPath,
    size,
    deletedAt,
  );

  /// Create a copy of TrashItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$TrashItemImplCopyWith<_$TrashItemImpl> get copyWith =>
      __$$TrashItemImplCopyWithImpl<_$TrashItemImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$TrashItemImplToJson(this);
  }
}

abstract class _TrashItem implements TrashItem {
  const factory _TrashItem({
    required final int id,
    required final int sourceId,
    required final String originalPath,
    required final String trashPath,
    final int size,
    final DateTime? deletedAt,
  }) = _$TrashItemImpl;

  factory _TrashItem.fromJson(Map<String, dynamic> json) =
      _$TrashItemImpl.fromJson;

  @override
  int get id;
  @override
  int get sourceId;
  @override
  String get originalPath;
  @override
  String get trashPath;
  @override
  int get size;
  @override
  DateTime? get deletedAt;

  /// Create a copy of TrashItem
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$TrashItemImplCopyWith<_$TrashItemImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
