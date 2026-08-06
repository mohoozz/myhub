// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'comic.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

ComicDetect _$ComicDetectFromJson(Map<String, dynamic> json) {
  return _ComicDetect.fromJson(json);
}

/// @nodoc
mixin _$ComicDetect {
  bool get isComic => throw _privateConstructorUsedError;
  String get reason => throw _privateConstructorUsedError;

  /// Serializes this ComicDetect to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ComicDetect
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ComicDetectCopyWith<ComicDetect> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ComicDetectCopyWith<$Res> {
  factory $ComicDetectCopyWith(
    ComicDetect value,
    $Res Function(ComicDetect) then,
  ) = _$ComicDetectCopyWithImpl<$Res, ComicDetect>;
  @useResult
  $Res call({bool isComic, String reason});
}

/// @nodoc
class _$ComicDetectCopyWithImpl<$Res, $Val extends ComicDetect>
    implements $ComicDetectCopyWith<$Res> {
  _$ComicDetectCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ComicDetect
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? isComic = null, Object? reason = null}) {
    return _then(
      _value.copyWith(
            isComic: null == isComic
                ? _value.isComic
                : isComic // ignore: cast_nullable_to_non_nullable
                      as bool,
            reason: null == reason
                ? _value.reason
                : reason // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ComicDetectImplCopyWith<$Res>
    implements $ComicDetectCopyWith<$Res> {
  factory _$$ComicDetectImplCopyWith(
    _$ComicDetectImpl value,
    $Res Function(_$ComicDetectImpl) then,
  ) = __$$ComicDetectImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({bool isComic, String reason});
}

/// @nodoc
class __$$ComicDetectImplCopyWithImpl<$Res>
    extends _$ComicDetectCopyWithImpl<$Res, _$ComicDetectImpl>
    implements _$$ComicDetectImplCopyWith<$Res> {
  __$$ComicDetectImplCopyWithImpl(
    _$ComicDetectImpl _value,
    $Res Function(_$ComicDetectImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ComicDetect
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? isComic = null, Object? reason = null}) {
    return _then(
      _$ComicDetectImpl(
        isComic: null == isComic
            ? _value.isComic
            : isComic // ignore: cast_nullable_to_non_nullable
                  as bool,
        reason: null == reason
            ? _value.reason
            : reason // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ComicDetectImpl implements _ComicDetect {
  const _$ComicDetectImpl({this.isComic = false, this.reason = 'none'});

  factory _$ComicDetectImpl.fromJson(Map<String, dynamic> json) =>
      _$$ComicDetectImplFromJson(json);

  @override
  @JsonKey()
  final bool isComic;
  @override
  @JsonKey()
  final String reason;

  @override
  String toString() {
    return 'ComicDetect(isComic: $isComic, reason: $reason)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ComicDetectImpl &&
            (identical(other.isComic, isComic) || other.isComic == isComic) &&
            (identical(other.reason, reason) || other.reason == reason));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, isComic, reason);

  /// Create a copy of ComicDetect
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ComicDetectImplCopyWith<_$ComicDetectImpl> get copyWith =>
      __$$ComicDetectImplCopyWithImpl<_$ComicDetectImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$ComicDetectImplToJson(this);
  }
}

abstract class _ComicDetect implements ComicDetect {
  const factory _ComicDetect({final bool isComic, final String reason}) =
      _$ComicDetectImpl;

  factory _ComicDetect.fromJson(Map<String, dynamic> json) =
      _$ComicDetectImpl.fromJson;

  @override
  bool get isComic;
  @override
  String get reason;

  /// Create a copy of ComicDetect
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ComicDetectImplCopyWith<_$ComicDetectImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

ComicPage _$ComicPageFromJson(Map<String, dynamic> json) {
  return _ComicPage.fromJson(json);
}

/// @nodoc
mixin _$ComicPage {
  int get index => throw _privateConstructorUsedError;
  String get name => throw _privateConstructorUsedError;
  int get size => throw _privateConstructorUsedError;

  /// 图片像素尺寸（服务端仅对 ZIP/CBZ、EPUB 提供；RAR 为 0）。
  /// 条漫模式据此精确计算页高与进度恢复。
  int get width => throw _privateConstructorUsedError;
  int get height => throw _privateConstructorUsedError;

  /// Serializes this ComicPage to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ComicPage
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ComicPageCopyWith<ComicPage> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ComicPageCopyWith<$Res> {
  factory $ComicPageCopyWith(ComicPage value, $Res Function(ComicPage) then) =
      _$ComicPageCopyWithImpl<$Res, ComicPage>;
  @useResult
  $Res call({int index, String name, int size, int width, int height});
}

/// @nodoc
class _$ComicPageCopyWithImpl<$Res, $Val extends ComicPage>
    implements $ComicPageCopyWith<$Res> {
  _$ComicPageCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ComicPage
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? index = null,
    Object? name = null,
    Object? size = null,
    Object? width = null,
    Object? height = null,
  }) {
    return _then(
      _value.copyWith(
            index: null == index
                ? _value.index
                : index // ignore: cast_nullable_to_non_nullable
                      as int,
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            size: null == size
                ? _value.size
                : size // ignore: cast_nullable_to_non_nullable
                      as int,
            width: null == width
                ? _value.width
                : width // ignore: cast_nullable_to_non_nullable
                      as int,
            height: null == height
                ? _value.height
                : height // ignore: cast_nullable_to_non_nullable
                      as int,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ComicPageImplCopyWith<$Res>
    implements $ComicPageCopyWith<$Res> {
  factory _$$ComicPageImplCopyWith(
    _$ComicPageImpl value,
    $Res Function(_$ComicPageImpl) then,
  ) = __$$ComicPageImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({int index, String name, int size, int width, int height});
}

/// @nodoc
class __$$ComicPageImplCopyWithImpl<$Res>
    extends _$ComicPageCopyWithImpl<$Res, _$ComicPageImpl>
    implements _$$ComicPageImplCopyWith<$Res> {
  __$$ComicPageImplCopyWithImpl(
    _$ComicPageImpl _value,
    $Res Function(_$ComicPageImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ComicPage
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? index = null,
    Object? name = null,
    Object? size = null,
    Object? width = null,
    Object? height = null,
  }) {
    return _then(
      _$ComicPageImpl(
        index: null == index
            ? _value.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        size: null == size
            ? _value.size
            : size // ignore: cast_nullable_to_non_nullable
                  as int,
        width: null == width
            ? _value.width
            : width // ignore: cast_nullable_to_non_nullable
                  as int,
        height: null == height
            ? _value.height
            : height // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ComicPageImpl implements _ComicPage {
  const _$ComicPageImpl({
    required this.index,
    required this.name,
    this.size = 0,
    this.width = 0,
    this.height = 0,
  });

  factory _$ComicPageImpl.fromJson(Map<String, dynamic> json) =>
      _$$ComicPageImplFromJson(json);

  @override
  final int index;
  @override
  final String name;
  @override
  @JsonKey()
  final int size;

  /// 图片像素尺寸（服务端仅对 ZIP/CBZ、EPUB 提供；RAR 为 0）。
  /// 条漫模式据此精确计算页高与进度恢复。
  @override
  @JsonKey()
  final int width;
  @override
  @JsonKey()
  final int height;

  @override
  String toString() {
    return 'ComicPage(index: $index, name: $name, size: $size, width: $width, height: $height)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ComicPageImpl &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.size, size) || other.size == size) &&
            (identical(other.width, width) || other.width == width) &&
            (identical(other.height, height) || other.height == height));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, index, name, size, width, height);

  /// Create a copy of ComicPage
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ComicPageImplCopyWith<_$ComicPageImpl> get copyWith =>
      __$$ComicPageImplCopyWithImpl<_$ComicPageImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$ComicPageImplToJson(this);
  }
}

abstract class _ComicPage implements ComicPage {
  const factory _ComicPage({
    required final int index,
    required final String name,
    final int size,
    final int width,
    final int height,
  }) = _$ComicPageImpl;

  factory _ComicPage.fromJson(Map<String, dynamic> json) =
      _$ComicPageImpl.fromJson;

  @override
  int get index;
  @override
  String get name;
  @override
  int get size;

  /// 图片像素尺寸（服务端仅对 ZIP/CBZ、EPUB 提供；RAR 为 0）。
  /// 条漫模式据此精确计算页高与进度恢复。
  @override
  int get width;
  @override
  int get height;

  /// Create a copy of ComicPage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ComicPageImplCopyWith<_$ComicPageImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

ComicPages _$ComicPagesFromJson(Map<String, dynamic> json) {
  return _ComicPages.fromJson(json);
}

/// @nodoc
mixin _$ComicPages {
  List<ComicPage> get pages => throw _privateConstructorUsedError;
  int get total => throw _privateConstructorUsedError;

  /// Serializes this ComicPages to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ComicPages
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ComicPagesCopyWith<ComicPages> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ComicPagesCopyWith<$Res> {
  factory $ComicPagesCopyWith(
    ComicPages value,
    $Res Function(ComicPages) then,
  ) = _$ComicPagesCopyWithImpl<$Res, ComicPages>;
  @useResult
  $Res call({List<ComicPage> pages, int total});
}

/// @nodoc
class _$ComicPagesCopyWithImpl<$Res, $Val extends ComicPages>
    implements $ComicPagesCopyWith<$Res> {
  _$ComicPagesCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ComicPages
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? pages = null, Object? total = null}) {
    return _then(
      _value.copyWith(
            pages: null == pages
                ? _value.pages
                : pages // ignore: cast_nullable_to_non_nullable
                      as List<ComicPage>,
            total: null == total
                ? _value.total
                : total // ignore: cast_nullable_to_non_nullable
                      as int,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ComicPagesImplCopyWith<$Res>
    implements $ComicPagesCopyWith<$Res> {
  factory _$$ComicPagesImplCopyWith(
    _$ComicPagesImpl value,
    $Res Function(_$ComicPagesImpl) then,
  ) = __$$ComicPagesImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<ComicPage> pages, int total});
}

/// @nodoc
class __$$ComicPagesImplCopyWithImpl<$Res>
    extends _$ComicPagesCopyWithImpl<$Res, _$ComicPagesImpl>
    implements _$$ComicPagesImplCopyWith<$Res> {
  __$$ComicPagesImplCopyWithImpl(
    _$ComicPagesImpl _value,
    $Res Function(_$ComicPagesImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ComicPages
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? pages = null, Object? total = null}) {
    return _then(
      _$ComicPagesImpl(
        pages: null == pages
            ? _value._pages
            : pages // ignore: cast_nullable_to_non_nullable
                  as List<ComicPage>,
        total: null == total
            ? _value.total
            : total // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ComicPagesImpl implements _ComicPages {
  const _$ComicPagesImpl({
    final List<ComicPage> pages = const [],
    this.total = 0,
  }) : _pages = pages;

  factory _$ComicPagesImpl.fromJson(Map<String, dynamic> json) =>
      _$$ComicPagesImplFromJson(json);

  final List<ComicPage> _pages;
  @override
  @JsonKey()
  List<ComicPage> get pages {
    if (_pages is EqualUnmodifiableListView) return _pages;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_pages);
  }

  @override
  @JsonKey()
  final int total;

  @override
  String toString() {
    return 'ComicPages(pages: $pages, total: $total)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ComicPagesImpl &&
            const DeepCollectionEquality().equals(other._pages, _pages) &&
            (identical(other.total, total) || other.total == total));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    const DeepCollectionEquality().hash(_pages),
    total,
  );

  /// Create a copy of ComicPages
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ComicPagesImplCopyWith<_$ComicPagesImpl> get copyWith =>
      __$$ComicPagesImplCopyWithImpl<_$ComicPagesImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$ComicPagesImplToJson(this);
  }
}

abstract class _ComicPages implements ComicPages {
  const factory _ComicPages({final List<ComicPage> pages, final int total}) =
      _$ComicPagesImpl;

  factory _ComicPages.fromJson(Map<String, dynamic> json) =
      _$ComicPagesImpl.fromJson;

  @override
  List<ComicPage> get pages;
  @override
  int get total;

  /// Create a copy of ComicPages
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ComicPagesImplCopyWith<_$ComicPagesImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

ArchiveEntry _$ArchiveEntryFromJson(Map<String, dynamic> json) {
  return _ArchiveEntry.fromJson(json);
}

/// @nodoc
mixin _$ArchiveEntry {
  String get name => throw _privateConstructorUsedError;
  int get size => throw _privateConstructorUsedError;
  bool get isDir => throw _privateConstructorUsedError;

  /// Serializes this ArchiveEntry to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ArchiveEntry
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ArchiveEntryCopyWith<ArchiveEntry> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ArchiveEntryCopyWith<$Res> {
  factory $ArchiveEntryCopyWith(
    ArchiveEntry value,
    $Res Function(ArchiveEntry) then,
  ) = _$ArchiveEntryCopyWithImpl<$Res, ArchiveEntry>;
  @useResult
  $Res call({String name, int size, bool isDir});
}

/// @nodoc
class _$ArchiveEntryCopyWithImpl<$Res, $Val extends ArchiveEntry>
    implements $ArchiveEntryCopyWith<$Res> {
  _$ArchiveEntryCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ArchiveEntry
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? name = null, Object? size = null, Object? isDir = null}) {
    return _then(
      _value.copyWith(
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            size: null == size
                ? _value.size
                : size // ignore: cast_nullable_to_non_nullable
                      as int,
            isDir: null == isDir
                ? _value.isDir
                : isDir // ignore: cast_nullable_to_non_nullable
                      as bool,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ArchiveEntryImplCopyWith<$Res>
    implements $ArchiveEntryCopyWith<$Res> {
  factory _$$ArchiveEntryImplCopyWith(
    _$ArchiveEntryImpl value,
    $Res Function(_$ArchiveEntryImpl) then,
  ) = __$$ArchiveEntryImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String name, int size, bool isDir});
}

/// @nodoc
class __$$ArchiveEntryImplCopyWithImpl<$Res>
    extends _$ArchiveEntryCopyWithImpl<$Res, _$ArchiveEntryImpl>
    implements _$$ArchiveEntryImplCopyWith<$Res> {
  __$$ArchiveEntryImplCopyWithImpl(
    _$ArchiveEntryImpl _value,
    $Res Function(_$ArchiveEntryImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ArchiveEntry
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? name = null, Object? size = null, Object? isDir = null}) {
    return _then(
      _$ArchiveEntryImpl(
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        size: null == size
            ? _value.size
            : size // ignore: cast_nullable_to_non_nullable
                  as int,
        isDir: null == isDir
            ? _value.isDir
            : isDir // ignore: cast_nullable_to_non_nullable
                  as bool,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ArchiveEntryImpl implements _ArchiveEntry {
  const _$ArchiveEntryImpl({
    required this.name,
    this.size = 0,
    this.isDir = false,
  });

  factory _$ArchiveEntryImpl.fromJson(Map<String, dynamic> json) =>
      _$$ArchiveEntryImplFromJson(json);

  @override
  final String name;
  @override
  @JsonKey()
  final int size;
  @override
  @JsonKey()
  final bool isDir;

  @override
  String toString() {
    return 'ArchiveEntry(name: $name, size: $size, isDir: $isDir)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ArchiveEntryImpl &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.size, size) || other.size == size) &&
            (identical(other.isDir, isDir) || other.isDir == isDir));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, name, size, isDir);

  /// Create a copy of ArchiveEntry
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ArchiveEntryImplCopyWith<_$ArchiveEntryImpl> get copyWith =>
      __$$ArchiveEntryImplCopyWithImpl<_$ArchiveEntryImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$ArchiveEntryImplToJson(this);
  }
}

abstract class _ArchiveEntry implements ArchiveEntry {
  const factory _ArchiveEntry({
    required final String name,
    final int size,
    final bool isDir,
  }) = _$ArchiveEntryImpl;

  factory _ArchiveEntry.fromJson(Map<String, dynamic> json) =
      _$ArchiveEntryImpl.fromJson;

  @override
  String get name;
  @override
  int get size;
  @override
  bool get isDir;

  /// Create a copy of ArchiveEntry
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ArchiveEntryImplCopyWith<_$ArchiveEntryImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

ArchiveTree _$ArchiveTreeFromJson(Map<String, dynamic> json) {
  return _ArchiveTree.fromJson(json);
}

/// @nodoc
mixin _$ArchiveTree {
  List<ArchiveEntry> get entries => throw _privateConstructorUsedError;
  int get total => throw _privateConstructorUsedError;

  /// Serializes this ArchiveTree to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ArchiveTree
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ArchiveTreeCopyWith<ArchiveTree> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ArchiveTreeCopyWith<$Res> {
  factory $ArchiveTreeCopyWith(
    ArchiveTree value,
    $Res Function(ArchiveTree) then,
  ) = _$ArchiveTreeCopyWithImpl<$Res, ArchiveTree>;
  @useResult
  $Res call({List<ArchiveEntry> entries, int total});
}

/// @nodoc
class _$ArchiveTreeCopyWithImpl<$Res, $Val extends ArchiveTree>
    implements $ArchiveTreeCopyWith<$Res> {
  _$ArchiveTreeCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ArchiveTree
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? entries = null, Object? total = null}) {
    return _then(
      _value.copyWith(
            entries: null == entries
                ? _value.entries
                : entries // ignore: cast_nullable_to_non_nullable
                      as List<ArchiveEntry>,
            total: null == total
                ? _value.total
                : total // ignore: cast_nullable_to_non_nullable
                      as int,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ArchiveTreeImplCopyWith<$Res>
    implements $ArchiveTreeCopyWith<$Res> {
  factory _$$ArchiveTreeImplCopyWith(
    _$ArchiveTreeImpl value,
    $Res Function(_$ArchiveTreeImpl) then,
  ) = __$$ArchiveTreeImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<ArchiveEntry> entries, int total});
}

/// @nodoc
class __$$ArchiveTreeImplCopyWithImpl<$Res>
    extends _$ArchiveTreeCopyWithImpl<$Res, _$ArchiveTreeImpl>
    implements _$$ArchiveTreeImplCopyWith<$Res> {
  __$$ArchiveTreeImplCopyWithImpl(
    _$ArchiveTreeImpl _value,
    $Res Function(_$ArchiveTreeImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ArchiveTree
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? entries = null, Object? total = null}) {
    return _then(
      _$ArchiveTreeImpl(
        entries: null == entries
            ? _value._entries
            : entries // ignore: cast_nullable_to_non_nullable
                  as List<ArchiveEntry>,
        total: null == total
            ? _value.total
            : total // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ArchiveTreeImpl implements _ArchiveTree {
  const _$ArchiveTreeImpl({
    final List<ArchiveEntry> entries = const [],
    this.total = 0,
  }) : _entries = entries;

  factory _$ArchiveTreeImpl.fromJson(Map<String, dynamic> json) =>
      _$$ArchiveTreeImplFromJson(json);

  final List<ArchiveEntry> _entries;
  @override
  @JsonKey()
  List<ArchiveEntry> get entries {
    if (_entries is EqualUnmodifiableListView) return _entries;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_entries);
  }

  @override
  @JsonKey()
  final int total;

  @override
  String toString() {
    return 'ArchiveTree(entries: $entries, total: $total)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ArchiveTreeImpl &&
            const DeepCollectionEquality().equals(other._entries, _entries) &&
            (identical(other.total, total) || other.total == total));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    const DeepCollectionEquality().hash(_entries),
    total,
  );

  /// Create a copy of ArchiveTree
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ArchiveTreeImplCopyWith<_$ArchiveTreeImpl> get copyWith =>
      __$$ArchiveTreeImplCopyWithImpl<_$ArchiveTreeImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$ArchiveTreeImplToJson(this);
  }
}

abstract class _ArchiveTree implements ArchiveTree {
  const factory _ArchiveTree({
    final List<ArchiveEntry> entries,
    final int total,
  }) = _$ArchiveTreeImpl;

  factory _ArchiveTree.fromJson(Map<String, dynamic> json) =
      _$ArchiveTreeImpl.fromJson;

  @override
  List<ArchiveEntry> get entries;
  @override
  int get total;

  /// Create a copy of ArchiveTree
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ArchiveTreeImplCopyWith<_$ArchiveTreeImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
