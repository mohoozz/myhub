// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'reader.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

NovelChapter _$NovelChapterFromJson(Map<String, dynamic> json) {
  return _NovelChapter.fromJson(json);
}

/// @nodoc
mixin _$NovelChapter {
  int get index => throw _privateConstructorUsedError;
  String get title => throw _privateConstructorUsedError;

  /// Serializes this NovelChapter to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of NovelChapter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $NovelChapterCopyWith<NovelChapter> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $NovelChapterCopyWith<$Res> {
  factory $NovelChapterCopyWith(
    NovelChapter value,
    $Res Function(NovelChapter) then,
  ) = _$NovelChapterCopyWithImpl<$Res, NovelChapter>;
  @useResult
  $Res call({int index, String title});
}

/// @nodoc
class _$NovelChapterCopyWithImpl<$Res, $Val extends NovelChapter>
    implements $NovelChapterCopyWith<$Res> {
  _$NovelChapterCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of NovelChapter
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? index = null, Object? title = null}) {
    return _then(
      _value.copyWith(
            index: null == index
                ? _value.index
                : index // ignore: cast_nullable_to_non_nullable
                      as int,
            title: null == title
                ? _value.title
                : title // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$NovelChapterImplCopyWith<$Res>
    implements $NovelChapterCopyWith<$Res> {
  factory _$$NovelChapterImplCopyWith(
    _$NovelChapterImpl value,
    $Res Function(_$NovelChapterImpl) then,
  ) = __$$NovelChapterImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({int index, String title});
}

/// @nodoc
class __$$NovelChapterImplCopyWithImpl<$Res>
    extends _$NovelChapterCopyWithImpl<$Res, _$NovelChapterImpl>
    implements _$$NovelChapterImplCopyWith<$Res> {
  __$$NovelChapterImplCopyWithImpl(
    _$NovelChapterImpl _value,
    $Res Function(_$NovelChapterImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of NovelChapter
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? index = null, Object? title = null}) {
    return _then(
      _$NovelChapterImpl(
        index: null == index
            ? _value.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        title: null == title
            ? _value.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$NovelChapterImpl implements _NovelChapter {
  const _$NovelChapterImpl({required this.index, required this.title});

  factory _$NovelChapterImpl.fromJson(Map<String, dynamic> json) =>
      _$$NovelChapterImplFromJson(json);

  @override
  final int index;
  @override
  final String title;

  @override
  String toString() {
    return 'NovelChapter(index: $index, title: $title)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$NovelChapterImpl &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.title, title) || other.title == title));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, index, title);

  /// Create a copy of NovelChapter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$NovelChapterImplCopyWith<_$NovelChapterImpl> get copyWith =>
      __$$NovelChapterImplCopyWithImpl<_$NovelChapterImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$NovelChapterImplToJson(this);
  }
}

abstract class _NovelChapter implements NovelChapter {
  const factory _NovelChapter({
    required final int index,
    required final String title,
  }) = _$NovelChapterImpl;

  factory _NovelChapter.fromJson(Map<String, dynamic> json) =
      _$NovelChapterImpl.fromJson;

  @override
  int get index;
  @override
  String get title;

  /// Create a copy of NovelChapter
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$NovelChapterImplCopyWith<_$NovelChapterImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

NovelChapters _$NovelChaptersFromJson(Map<String, dynamic> json) {
  return _NovelChapters.fromJson(json);
}

/// @nodoc
mixin _$NovelChapters {
  bool get ready => throw _privateConstructorUsedError;
  String get encoding => throw _privateConstructorUsedError;
  List<NovelChapter> get chapters => throw _privateConstructorUsedError;
  int get total => throw _privateConstructorUsedError;

  /// Serializes this NovelChapters to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of NovelChapters
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $NovelChaptersCopyWith<NovelChapters> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $NovelChaptersCopyWith<$Res> {
  factory $NovelChaptersCopyWith(
    NovelChapters value,
    $Res Function(NovelChapters) then,
  ) = _$NovelChaptersCopyWithImpl<$Res, NovelChapters>;
  @useResult
  $Res call({
    bool ready,
    String encoding,
    List<NovelChapter> chapters,
    int total,
  });
}

/// @nodoc
class _$NovelChaptersCopyWithImpl<$Res, $Val extends NovelChapters>
    implements $NovelChaptersCopyWith<$Res> {
  _$NovelChaptersCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of NovelChapters
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? ready = null,
    Object? encoding = null,
    Object? chapters = null,
    Object? total = null,
  }) {
    return _then(
      _value.copyWith(
            ready: null == ready
                ? _value.ready
                : ready // ignore: cast_nullable_to_non_nullable
                      as bool,
            encoding: null == encoding
                ? _value.encoding
                : encoding // ignore: cast_nullable_to_non_nullable
                      as String,
            chapters: null == chapters
                ? _value.chapters
                : chapters // ignore: cast_nullable_to_non_nullable
                      as List<NovelChapter>,
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
abstract class _$$NovelChaptersImplCopyWith<$Res>
    implements $NovelChaptersCopyWith<$Res> {
  factory _$$NovelChaptersImplCopyWith(
    _$NovelChaptersImpl value,
    $Res Function(_$NovelChaptersImpl) then,
  ) = __$$NovelChaptersImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    bool ready,
    String encoding,
    List<NovelChapter> chapters,
    int total,
  });
}

/// @nodoc
class __$$NovelChaptersImplCopyWithImpl<$Res>
    extends _$NovelChaptersCopyWithImpl<$Res, _$NovelChaptersImpl>
    implements _$$NovelChaptersImplCopyWith<$Res> {
  __$$NovelChaptersImplCopyWithImpl(
    _$NovelChaptersImpl _value,
    $Res Function(_$NovelChaptersImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of NovelChapters
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? ready = null,
    Object? encoding = null,
    Object? chapters = null,
    Object? total = null,
  }) {
    return _then(
      _$NovelChaptersImpl(
        ready: null == ready
            ? _value.ready
            : ready // ignore: cast_nullable_to_non_nullable
                  as bool,
        encoding: null == encoding
            ? _value.encoding
            : encoding // ignore: cast_nullable_to_non_nullable
                  as String,
        chapters: null == chapters
            ? _value._chapters
            : chapters // ignore: cast_nullable_to_non_nullable
                  as List<NovelChapter>,
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
class _$NovelChaptersImpl implements _NovelChapters {
  const _$NovelChaptersImpl({
    this.ready = false,
    this.encoding = '',
    final List<NovelChapter> chapters = const [],
    this.total = 0,
  }) : _chapters = chapters;

  factory _$NovelChaptersImpl.fromJson(Map<String, dynamic> json) =>
      _$$NovelChaptersImplFromJson(json);

  @override
  @JsonKey()
  final bool ready;
  @override
  @JsonKey()
  final String encoding;
  final List<NovelChapter> _chapters;
  @override
  @JsonKey()
  List<NovelChapter> get chapters {
    if (_chapters is EqualUnmodifiableListView) return _chapters;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_chapters);
  }

  @override
  @JsonKey()
  final int total;

  @override
  String toString() {
    return 'NovelChapters(ready: $ready, encoding: $encoding, chapters: $chapters, total: $total)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$NovelChaptersImpl &&
            (identical(other.ready, ready) || other.ready == ready) &&
            (identical(other.encoding, encoding) ||
                other.encoding == encoding) &&
            const DeepCollectionEquality().equals(other._chapters, _chapters) &&
            (identical(other.total, total) || other.total == total));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    ready,
    encoding,
    const DeepCollectionEquality().hash(_chapters),
    total,
  );

  /// Create a copy of NovelChapters
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$NovelChaptersImplCopyWith<_$NovelChaptersImpl> get copyWith =>
      __$$NovelChaptersImplCopyWithImpl<_$NovelChaptersImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$NovelChaptersImplToJson(this);
  }
}

abstract class _NovelChapters implements NovelChapters {
  const factory _NovelChapters({
    final bool ready,
    final String encoding,
    final List<NovelChapter> chapters,
    final int total,
  }) = _$NovelChaptersImpl;

  factory _NovelChapters.fromJson(Map<String, dynamic> json) =
      _$NovelChaptersImpl.fromJson;

  @override
  bool get ready;
  @override
  String get encoding;
  @override
  List<NovelChapter> get chapters;
  @override
  int get total;

  /// Create a copy of NovelChapters
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$NovelChaptersImplCopyWith<_$NovelChaptersImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

NovelContent _$NovelContentFromJson(Map<String, dynamic> json) {
  return _NovelContent.fromJson(json);
}

/// @nodoc
mixin _$NovelContent {
  bool get ready => throw _privateConstructorUsedError;
  int get chapter => throw _privateConstructorUsedError;
  String get title => throw _privateConstructorUsedError;
  String get content => throw _privateConstructorUsedError;
  int get total => throw _privateConstructorUsedError;

  /// Serializes this NovelContent to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of NovelContent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $NovelContentCopyWith<NovelContent> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $NovelContentCopyWith<$Res> {
  factory $NovelContentCopyWith(
    NovelContent value,
    $Res Function(NovelContent) then,
  ) = _$NovelContentCopyWithImpl<$Res, NovelContent>;
  @useResult
  $Res call({bool ready, int chapter, String title, String content, int total});
}

/// @nodoc
class _$NovelContentCopyWithImpl<$Res, $Val extends NovelContent>
    implements $NovelContentCopyWith<$Res> {
  _$NovelContentCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of NovelContent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? ready = null,
    Object? chapter = null,
    Object? title = null,
    Object? content = null,
    Object? total = null,
  }) {
    return _then(
      _value.copyWith(
            ready: null == ready
                ? _value.ready
                : ready // ignore: cast_nullable_to_non_nullable
                      as bool,
            chapter: null == chapter
                ? _value.chapter
                : chapter // ignore: cast_nullable_to_non_nullable
                      as int,
            title: null == title
                ? _value.title
                : title // ignore: cast_nullable_to_non_nullable
                      as String,
            content: null == content
                ? _value.content
                : content // ignore: cast_nullable_to_non_nullable
                      as String,
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
abstract class _$$NovelContentImplCopyWith<$Res>
    implements $NovelContentCopyWith<$Res> {
  factory _$$NovelContentImplCopyWith(
    _$NovelContentImpl value,
    $Res Function(_$NovelContentImpl) then,
  ) = __$$NovelContentImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({bool ready, int chapter, String title, String content, int total});
}

/// @nodoc
class __$$NovelContentImplCopyWithImpl<$Res>
    extends _$NovelContentCopyWithImpl<$Res, _$NovelContentImpl>
    implements _$$NovelContentImplCopyWith<$Res> {
  __$$NovelContentImplCopyWithImpl(
    _$NovelContentImpl _value,
    $Res Function(_$NovelContentImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of NovelContent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? ready = null,
    Object? chapter = null,
    Object? title = null,
    Object? content = null,
    Object? total = null,
  }) {
    return _then(
      _$NovelContentImpl(
        ready: null == ready
            ? _value.ready
            : ready // ignore: cast_nullable_to_non_nullable
                  as bool,
        chapter: null == chapter
            ? _value.chapter
            : chapter // ignore: cast_nullable_to_non_nullable
                  as int,
        title: null == title
            ? _value.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
        content: null == content
            ? _value.content
            : content // ignore: cast_nullable_to_non_nullable
                  as String,
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
class _$NovelContentImpl implements _NovelContent {
  const _$NovelContentImpl({
    this.ready = false,
    this.chapter = 0,
    this.title = '',
    this.content = '',
    this.total = 0,
  });

  factory _$NovelContentImpl.fromJson(Map<String, dynamic> json) =>
      _$$NovelContentImplFromJson(json);

  @override
  @JsonKey()
  final bool ready;
  @override
  @JsonKey()
  final int chapter;
  @override
  @JsonKey()
  final String title;
  @override
  @JsonKey()
  final String content;
  @override
  @JsonKey()
  final int total;

  @override
  String toString() {
    return 'NovelContent(ready: $ready, chapter: $chapter, title: $title, content: $content, total: $total)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$NovelContentImpl &&
            (identical(other.ready, ready) || other.ready == ready) &&
            (identical(other.chapter, chapter) || other.chapter == chapter) &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.content, content) || other.content == content) &&
            (identical(other.total, total) || other.total == total));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, ready, chapter, title, content, total);

  /// Create a copy of NovelContent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$NovelContentImplCopyWith<_$NovelContentImpl> get copyWith =>
      __$$NovelContentImplCopyWithImpl<_$NovelContentImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$NovelContentImplToJson(this);
  }
}

abstract class _NovelContent implements NovelContent {
  const factory _NovelContent({
    final bool ready,
    final int chapter,
    final String title,
    final String content,
    final int total,
  }) = _$NovelContentImpl;

  factory _NovelContent.fromJson(Map<String, dynamic> json) =
      _$NovelContentImpl.fromJson;

  @override
  bool get ready;
  @override
  int get chapter;
  @override
  String get title;
  @override
  String get content;
  @override
  int get total;

  /// Create a copy of NovelContent
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$NovelContentImplCopyWith<_$NovelContentImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

TocItem _$TocItemFromJson(Map<String, dynamic> json) {
  return _TocItem.fromJson(json);
}

/// @nodoc
mixin _$TocItem {
  String get title => throw _privateConstructorUsedError;
  String get href => throw _privateConstructorUsedError;

  /// Serializes this TocItem to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of TocItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $TocItemCopyWith<TocItem> get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $TocItemCopyWith<$Res> {
  factory $TocItemCopyWith(TocItem value, $Res Function(TocItem) then) =
      _$TocItemCopyWithImpl<$Res, TocItem>;
  @useResult
  $Res call({String title, String href});
}

/// @nodoc
class _$TocItemCopyWithImpl<$Res, $Val extends TocItem>
    implements $TocItemCopyWith<$Res> {
  _$TocItemCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of TocItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? title = null, Object? href = null}) {
    return _then(
      _value.copyWith(
            title: null == title
                ? _value.title
                : title // ignore: cast_nullable_to_non_nullable
                      as String,
            href: null == href
                ? _value.href
                : href // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$TocItemImplCopyWith<$Res> implements $TocItemCopyWith<$Res> {
  factory _$$TocItemImplCopyWith(
    _$TocItemImpl value,
    $Res Function(_$TocItemImpl) then,
  ) = __$$TocItemImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String title, String href});
}

/// @nodoc
class __$$TocItemImplCopyWithImpl<$Res>
    extends _$TocItemCopyWithImpl<$Res, _$TocItemImpl>
    implements _$$TocItemImplCopyWith<$Res> {
  __$$TocItemImplCopyWithImpl(
    _$TocItemImpl _value,
    $Res Function(_$TocItemImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of TocItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? title = null, Object? href = null}) {
    return _then(
      _$TocItemImpl(
        title: null == title
            ? _value.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
        href: null == href
            ? _value.href
            : href // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$TocItemImpl implements _TocItem {
  const _$TocItemImpl({required this.title, required this.href});

  factory _$TocItemImpl.fromJson(Map<String, dynamic> json) =>
      _$$TocItemImplFromJson(json);

  @override
  final String title;
  @override
  final String href;

  @override
  String toString() {
    return 'TocItem(title: $title, href: $href)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$TocItemImpl &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.href, href) || other.href == href));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, title, href);

  /// Create a copy of TocItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$TocItemImplCopyWith<_$TocItemImpl> get copyWith =>
      __$$TocItemImplCopyWithImpl<_$TocItemImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$TocItemImplToJson(this);
  }
}

abstract class _TocItem implements TocItem {
  const factory _TocItem({
    required final String title,
    required final String href,
  }) = _$TocItemImpl;

  factory _TocItem.fromJson(Map<String, dynamic> json) = _$TocItemImpl.fromJson;

  @override
  String get title;
  @override
  String get href;

  /// Create a copy of TocItem
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$TocItemImplCopyWith<_$TocItemImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

EpubMeta _$EpubMetaFromJson(Map<String, dynamic> json) {
  return _EpubMeta.fromJson(json);
}

/// @nodoc
mixin _$EpubMeta {
  String get title => throw _privateConstructorUsedError;
  String get author => throw _privateConstructorUsedError;
  String get coverId => throw _privateConstructorUsedError;
  bool get isComic => throw _privateConstructorUsedError;
  List<TocItem> get toc => throw _privateConstructorUsedError;

  /// Serializes this EpubMeta to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of EpubMeta
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $EpubMetaCopyWith<EpubMeta> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $EpubMetaCopyWith<$Res> {
  factory $EpubMetaCopyWith(EpubMeta value, $Res Function(EpubMeta) then) =
      _$EpubMetaCopyWithImpl<$Res, EpubMeta>;
  @useResult
  $Res call({
    String title,
    String author,
    String coverId,
    bool isComic,
    List<TocItem> toc,
  });
}

/// @nodoc
class _$EpubMetaCopyWithImpl<$Res, $Val extends EpubMeta>
    implements $EpubMetaCopyWith<$Res> {
  _$EpubMetaCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of EpubMeta
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? title = null,
    Object? author = null,
    Object? coverId = null,
    Object? isComic = null,
    Object? toc = null,
  }) {
    return _then(
      _value.copyWith(
            title: null == title
                ? _value.title
                : title // ignore: cast_nullable_to_non_nullable
                      as String,
            author: null == author
                ? _value.author
                : author // ignore: cast_nullable_to_non_nullable
                      as String,
            coverId: null == coverId
                ? _value.coverId
                : coverId // ignore: cast_nullable_to_non_nullable
                      as String,
            isComic: null == isComic
                ? _value.isComic
                : isComic // ignore: cast_nullable_to_non_nullable
                      as bool,
            toc: null == toc
                ? _value.toc
                : toc // ignore: cast_nullable_to_non_nullable
                      as List<TocItem>,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$EpubMetaImplCopyWith<$Res>
    implements $EpubMetaCopyWith<$Res> {
  factory _$$EpubMetaImplCopyWith(
    _$EpubMetaImpl value,
    $Res Function(_$EpubMetaImpl) then,
  ) = __$$EpubMetaImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String title,
    String author,
    String coverId,
    bool isComic,
    List<TocItem> toc,
  });
}

/// @nodoc
class __$$EpubMetaImplCopyWithImpl<$Res>
    extends _$EpubMetaCopyWithImpl<$Res, _$EpubMetaImpl>
    implements _$$EpubMetaImplCopyWith<$Res> {
  __$$EpubMetaImplCopyWithImpl(
    _$EpubMetaImpl _value,
    $Res Function(_$EpubMetaImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of EpubMeta
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? title = null,
    Object? author = null,
    Object? coverId = null,
    Object? isComic = null,
    Object? toc = null,
  }) {
    return _then(
      _$EpubMetaImpl(
        title: null == title
            ? _value.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
        author: null == author
            ? _value.author
            : author // ignore: cast_nullable_to_non_nullable
                  as String,
        coverId: null == coverId
            ? _value.coverId
            : coverId // ignore: cast_nullable_to_non_nullable
                  as String,
        isComic: null == isComic
            ? _value.isComic
            : isComic // ignore: cast_nullable_to_non_nullable
                  as bool,
        toc: null == toc
            ? _value._toc
            : toc // ignore: cast_nullable_to_non_nullable
                  as List<TocItem>,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$EpubMetaImpl implements _EpubMeta {
  const _$EpubMetaImpl({
    this.title = '',
    this.author = '',
    this.coverId = '',
    this.isComic = false,
    final List<TocItem> toc = const [],
  }) : _toc = toc;

  factory _$EpubMetaImpl.fromJson(Map<String, dynamic> json) =>
      _$$EpubMetaImplFromJson(json);

  @override
  @JsonKey()
  final String title;
  @override
  @JsonKey()
  final String author;
  @override
  @JsonKey()
  final String coverId;
  @override
  @JsonKey()
  final bool isComic;
  final List<TocItem> _toc;
  @override
  @JsonKey()
  List<TocItem> get toc {
    if (_toc is EqualUnmodifiableListView) return _toc;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_toc);
  }

  @override
  String toString() {
    return 'EpubMeta(title: $title, author: $author, coverId: $coverId, isComic: $isComic, toc: $toc)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EpubMetaImpl &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.author, author) || other.author == author) &&
            (identical(other.coverId, coverId) || other.coverId == coverId) &&
            (identical(other.isComic, isComic) || other.isComic == isComic) &&
            const DeepCollectionEquality().equals(other._toc, _toc));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    title,
    author,
    coverId,
    isComic,
    const DeepCollectionEquality().hash(_toc),
  );

  /// Create a copy of EpubMeta
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EpubMetaImplCopyWith<_$EpubMetaImpl> get copyWith =>
      __$$EpubMetaImplCopyWithImpl<_$EpubMetaImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$EpubMetaImplToJson(this);
  }
}

abstract class _EpubMeta implements EpubMeta {
  const factory _EpubMeta({
    final String title,
    final String author,
    final String coverId,
    final bool isComic,
    final List<TocItem> toc,
  }) = _$EpubMetaImpl;

  factory _EpubMeta.fromJson(Map<String, dynamic> json) =
      _$EpubMetaImpl.fromJson;

  @override
  String get title;
  @override
  String get author;
  @override
  String get coverId;
  @override
  bool get isComic;
  @override
  List<TocItem> get toc;

  /// Create a copy of EpubMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EpubMetaImplCopyWith<_$EpubMetaImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
