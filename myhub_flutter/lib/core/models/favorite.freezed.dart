// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'favorite.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

Favorite _$FavoriteFromJson(Map<String, dynamic> json) {
  return _Favorite.fromJson(json);
}

/// @nodoc
mixin _$Favorite {
  int get id => throw _privateConstructorUsedError;
  int get sourceId => throw _privateConstructorUsedError;
  String get filePath => throw _privateConstructorUsedError;
  String get mediaType => throw _privateConstructorUsedError;
  int get size => throw _privateConstructorUsedError;
  DateTime? get createdAt => throw _privateConstructorUsedError;

  /// Serializes this Favorite to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of Favorite
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FavoriteCopyWith<Favorite> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FavoriteCopyWith<$Res> {
  factory $FavoriteCopyWith(Favorite value, $Res Function(Favorite) then) =
      _$FavoriteCopyWithImpl<$Res, Favorite>;
  @useResult
  $Res call({
    int id,
    int sourceId,
    String filePath,
    String mediaType,
    int size,
    DateTime? createdAt,
  });
}

/// @nodoc
class _$FavoriteCopyWithImpl<$Res, $Val extends Favorite>
    implements $FavoriteCopyWith<$Res> {
  _$FavoriteCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of Favorite
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? sourceId = null,
    Object? filePath = null,
    Object? mediaType = null,
    Object? size = null,
    Object? createdAt = freezed,
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
            filePath: null == filePath
                ? _value.filePath
                : filePath // ignore: cast_nullable_to_non_nullable
                      as String,
            mediaType: null == mediaType
                ? _value.mediaType
                : mediaType // ignore: cast_nullable_to_non_nullable
                      as String,
            size: null == size
                ? _value.size
                : size // ignore: cast_nullable_to_non_nullable
                      as int,
            createdAt: freezed == createdAt
                ? _value.createdAt
                : createdAt // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$FavoriteImplCopyWith<$Res>
    implements $FavoriteCopyWith<$Res> {
  factory _$$FavoriteImplCopyWith(
    _$FavoriteImpl value,
    $Res Function(_$FavoriteImpl) then,
  ) = __$$FavoriteImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    int id,
    int sourceId,
    String filePath,
    String mediaType,
    int size,
    DateTime? createdAt,
  });
}

/// @nodoc
class __$$FavoriteImplCopyWithImpl<$Res>
    extends _$FavoriteCopyWithImpl<$Res, _$FavoriteImpl>
    implements _$$FavoriteImplCopyWith<$Res> {
  __$$FavoriteImplCopyWithImpl(
    _$FavoriteImpl _value,
    $Res Function(_$FavoriteImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of Favorite
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? sourceId = null,
    Object? filePath = null,
    Object? mediaType = null,
    Object? size = null,
    Object? createdAt = freezed,
  }) {
    return _then(
      _$FavoriteImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as int,
        sourceId: null == sourceId
            ? _value.sourceId
            : sourceId // ignore: cast_nullable_to_non_nullable
                  as int,
        filePath: null == filePath
            ? _value.filePath
            : filePath // ignore: cast_nullable_to_non_nullable
                  as String,
        mediaType: null == mediaType
            ? _value.mediaType
            : mediaType // ignore: cast_nullable_to_non_nullable
                  as String,
        size: null == size
            ? _value.size
            : size // ignore: cast_nullable_to_non_nullable
                  as int,
        createdAt: freezed == createdAt
            ? _value.createdAt
            : createdAt // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$FavoriteImpl implements _Favorite {
  const _$FavoriteImpl({
    required this.id,
    required this.sourceId,
    required this.filePath,
    this.mediaType = '',
    this.size = 0,
    this.createdAt,
  });

  factory _$FavoriteImpl.fromJson(Map<String, dynamic> json) =>
      _$$FavoriteImplFromJson(json);

  @override
  final int id;
  @override
  final int sourceId;
  @override
  final String filePath;
  @override
  @JsonKey()
  final String mediaType;
  @override
  @JsonKey()
  final int size;
  @override
  final DateTime? createdAt;

  @override
  String toString() {
    return 'Favorite(id: $id, sourceId: $sourceId, filePath: $filePath, mediaType: $mediaType, size: $size, createdAt: $createdAt)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FavoriteImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.sourceId, sourceId) ||
                other.sourceId == sourceId) &&
            (identical(other.filePath, filePath) ||
                other.filePath == filePath) &&
            (identical(other.mediaType, mediaType) ||
                other.mediaType == mediaType) &&
            (identical(other.size, size) || other.size == size) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    sourceId,
    filePath,
    mediaType,
    size,
    createdAt,
  );

  /// Create a copy of Favorite
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FavoriteImplCopyWith<_$FavoriteImpl> get copyWith =>
      __$$FavoriteImplCopyWithImpl<_$FavoriteImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$FavoriteImplToJson(this);
  }
}

abstract class _Favorite implements Favorite {
  const factory _Favorite({
    required final int id,
    required final int sourceId,
    required final String filePath,
    final String mediaType,
    final int size,
    final DateTime? createdAt,
  }) = _$FavoriteImpl;

  factory _Favorite.fromJson(Map<String, dynamic> json) =
      _$FavoriteImpl.fromJson;

  @override
  int get id;
  @override
  int get sourceId;
  @override
  String get filePath;
  @override
  String get mediaType;
  @override
  int get size;
  @override
  DateTime? get createdAt;

  /// Create a copy of Favorite
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FavoriteImplCopyWith<_$FavoriteImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

FavoritePage _$FavoritePageFromJson(Map<String, dynamic> json) {
  return _FavoritePage.fromJson(json);
}

/// @nodoc
mixin _$FavoritePage {
  List<Favorite> get list => throw _privateConstructorUsedError;
  int get total => throw _privateConstructorUsedError;
  int get page => throw _privateConstructorUsedError;
  int get pageSize => throw _privateConstructorUsedError;

  /// Serializes this FavoritePage to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of FavoritePage
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FavoritePageCopyWith<FavoritePage> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FavoritePageCopyWith<$Res> {
  factory $FavoritePageCopyWith(
    FavoritePage value,
    $Res Function(FavoritePage) then,
  ) = _$FavoritePageCopyWithImpl<$Res, FavoritePage>;
  @useResult
  $Res call({List<Favorite> list, int total, int page, int pageSize});
}

/// @nodoc
class _$FavoritePageCopyWithImpl<$Res, $Val extends FavoritePage>
    implements $FavoritePageCopyWith<$Res> {
  _$FavoritePageCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FavoritePage
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? list = null,
    Object? total = null,
    Object? page = null,
    Object? pageSize = null,
  }) {
    return _then(
      _value.copyWith(
            list: null == list
                ? _value.list
                : list // ignore: cast_nullable_to_non_nullable
                      as List<Favorite>,
            total: null == total
                ? _value.total
                : total // ignore: cast_nullable_to_non_nullable
                      as int,
            page: null == page
                ? _value.page
                : page // ignore: cast_nullable_to_non_nullable
                      as int,
            pageSize: null == pageSize
                ? _value.pageSize
                : pageSize // ignore: cast_nullable_to_non_nullable
                      as int,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$FavoritePageImplCopyWith<$Res>
    implements $FavoritePageCopyWith<$Res> {
  factory _$$FavoritePageImplCopyWith(
    _$FavoritePageImpl value,
    $Res Function(_$FavoritePageImpl) then,
  ) = __$$FavoritePageImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<Favorite> list, int total, int page, int pageSize});
}

/// @nodoc
class __$$FavoritePageImplCopyWithImpl<$Res>
    extends _$FavoritePageCopyWithImpl<$Res, _$FavoritePageImpl>
    implements _$$FavoritePageImplCopyWith<$Res> {
  __$$FavoritePageImplCopyWithImpl(
    _$FavoritePageImpl _value,
    $Res Function(_$FavoritePageImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FavoritePage
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? list = null,
    Object? total = null,
    Object? page = null,
    Object? pageSize = null,
  }) {
    return _then(
      _$FavoritePageImpl(
        list: null == list
            ? _value._list
            : list // ignore: cast_nullable_to_non_nullable
                  as List<Favorite>,
        total: null == total
            ? _value.total
            : total // ignore: cast_nullable_to_non_nullable
                  as int,
        page: null == page
            ? _value.page
            : page // ignore: cast_nullable_to_non_nullable
                  as int,
        pageSize: null == pageSize
            ? _value.pageSize
            : pageSize // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$FavoritePageImpl implements _FavoritePage {
  const _$FavoritePageImpl({
    final List<Favorite> list = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 50,
  }) : _list = list;

  factory _$FavoritePageImpl.fromJson(Map<String, dynamic> json) =>
      _$$FavoritePageImplFromJson(json);

  final List<Favorite> _list;
  @override
  @JsonKey()
  List<Favorite> get list {
    if (_list is EqualUnmodifiableListView) return _list;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_list);
  }

  @override
  @JsonKey()
  final int total;
  @override
  @JsonKey()
  final int page;
  @override
  @JsonKey()
  final int pageSize;

  @override
  String toString() {
    return 'FavoritePage(list: $list, total: $total, page: $page, pageSize: $pageSize)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FavoritePageImpl &&
            const DeepCollectionEquality().equals(other._list, _list) &&
            (identical(other.total, total) || other.total == total) &&
            (identical(other.page, page) || other.page == page) &&
            (identical(other.pageSize, pageSize) ||
                other.pageSize == pageSize));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    const DeepCollectionEquality().hash(_list),
    total,
    page,
    pageSize,
  );

  /// Create a copy of FavoritePage
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FavoritePageImplCopyWith<_$FavoritePageImpl> get copyWith =>
      __$$FavoritePageImplCopyWithImpl<_$FavoritePageImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$FavoritePageImplToJson(this);
  }
}

abstract class _FavoritePage implements FavoritePage {
  const factory _FavoritePage({
    final List<Favorite> list,
    final int total,
    final int page,
    final int pageSize,
  }) = _$FavoritePageImpl;

  factory _FavoritePage.fromJson(Map<String, dynamic> json) =
      _$FavoritePageImpl.fromJson;

  @override
  List<Favorite> get list;
  @override
  int get total;
  @override
  int get page;
  @override
  int get pageSize;

  /// Create a copy of FavoritePage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FavoritePageImplCopyWith<_$FavoritePageImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
