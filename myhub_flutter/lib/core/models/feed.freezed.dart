// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'feed.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

FeedItem _$FeedItemFromJson(Map<String, dynamic> json) {
  return _FeedItem.fromJson(json);
}

/// @nodoc
mixin _$FeedItem {
  int get id => throw _privateConstructorUsedError;
  String get platform => throw _privateConstructorUsedError;
  String get contentId => throw _privateConstructorUsedError;
  String get mediaType => throw _privateConstructorUsedError;
  String get author => throw _privateConstructorUsedError;
  String get title => throw _privateConstructorUsedError;
  String get cover => throw _privateConstructorUsedError;
  String get url => throw _privateConstructorUsedError;
  String get description => throw _privateConstructorUsedError;
  DateTime? get publishedAt => throw _privateConstructorUsedError;
  DateTime? get createdAt => throw _privateConstructorUsedError;

  /// Serializes this FeedItem to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of FeedItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FeedItemCopyWith<FeedItem> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FeedItemCopyWith<$Res> {
  factory $FeedItemCopyWith(FeedItem value, $Res Function(FeedItem) then) =
      _$FeedItemCopyWithImpl<$Res, FeedItem>;
  @useResult
  $Res call({
    int id,
    String platform,
    String contentId,
    String mediaType,
    String author,
    String title,
    String cover,
    String url,
    String description,
    DateTime? publishedAt,
    DateTime? createdAt,
  });
}

/// @nodoc
class _$FeedItemCopyWithImpl<$Res, $Val extends FeedItem>
    implements $FeedItemCopyWith<$Res> {
  _$FeedItemCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FeedItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? platform = null,
    Object? contentId = null,
    Object? mediaType = null,
    Object? author = null,
    Object? title = null,
    Object? cover = null,
    Object? url = null,
    Object? description = null,
    Object? publishedAt = freezed,
    Object? createdAt = freezed,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as int,
            platform: null == platform
                ? _value.platform
                : platform // ignore: cast_nullable_to_non_nullable
                      as String,
            contentId: null == contentId
                ? _value.contentId
                : contentId // ignore: cast_nullable_to_non_nullable
                      as String,
            mediaType: null == mediaType
                ? _value.mediaType
                : mediaType // ignore: cast_nullable_to_non_nullable
                      as String,
            author: null == author
                ? _value.author
                : author // ignore: cast_nullable_to_non_nullable
                      as String,
            title: null == title
                ? _value.title
                : title // ignore: cast_nullable_to_non_nullable
                      as String,
            cover: null == cover
                ? _value.cover
                : cover // ignore: cast_nullable_to_non_nullable
                      as String,
            url: null == url
                ? _value.url
                : url // ignore: cast_nullable_to_non_nullable
                      as String,
            description: null == description
                ? _value.description
                : description // ignore: cast_nullable_to_non_nullable
                      as String,
            publishedAt: freezed == publishedAt
                ? _value.publishedAt
                : publishedAt // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
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
abstract class _$$FeedItemImplCopyWith<$Res>
    implements $FeedItemCopyWith<$Res> {
  factory _$$FeedItemImplCopyWith(
    _$FeedItemImpl value,
    $Res Function(_$FeedItemImpl) then,
  ) = __$$FeedItemImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    int id,
    String platform,
    String contentId,
    String mediaType,
    String author,
    String title,
    String cover,
    String url,
    String description,
    DateTime? publishedAt,
    DateTime? createdAt,
  });
}

/// @nodoc
class __$$FeedItemImplCopyWithImpl<$Res>
    extends _$FeedItemCopyWithImpl<$Res, _$FeedItemImpl>
    implements _$$FeedItemImplCopyWith<$Res> {
  __$$FeedItemImplCopyWithImpl(
    _$FeedItemImpl _value,
    $Res Function(_$FeedItemImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FeedItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? platform = null,
    Object? contentId = null,
    Object? mediaType = null,
    Object? author = null,
    Object? title = null,
    Object? cover = null,
    Object? url = null,
    Object? description = null,
    Object? publishedAt = freezed,
    Object? createdAt = freezed,
  }) {
    return _then(
      _$FeedItemImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as int,
        platform: null == platform
            ? _value.platform
            : platform // ignore: cast_nullable_to_non_nullable
                  as String,
        contentId: null == contentId
            ? _value.contentId
            : contentId // ignore: cast_nullable_to_non_nullable
                  as String,
        mediaType: null == mediaType
            ? _value.mediaType
            : mediaType // ignore: cast_nullable_to_non_nullable
                  as String,
        author: null == author
            ? _value.author
            : author // ignore: cast_nullable_to_non_nullable
                  as String,
        title: null == title
            ? _value.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
        cover: null == cover
            ? _value.cover
            : cover // ignore: cast_nullable_to_non_nullable
                  as String,
        url: null == url
            ? _value.url
            : url // ignore: cast_nullable_to_non_nullable
                  as String,
        description: null == description
            ? _value.description
            : description // ignore: cast_nullable_to_non_nullable
                  as String,
        publishedAt: freezed == publishedAt
            ? _value.publishedAt
            : publishedAt // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
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
class _$FeedItemImpl implements _FeedItem {
  const _$FeedItemImpl({
    required this.id,
    required this.platform,
    required this.contentId,
    this.mediaType = 'video',
    this.author = '',
    this.title = '',
    this.cover = '',
    this.url = '',
    this.description = '',
    this.publishedAt,
    this.createdAt,
  });

  factory _$FeedItemImpl.fromJson(Map<String, dynamic> json) =>
      _$$FeedItemImplFromJson(json);

  @override
  final int id;
  @override
  final String platform;
  @override
  final String contentId;
  @override
  @JsonKey()
  final String mediaType;
  @override
  @JsonKey()
  final String author;
  @override
  @JsonKey()
  final String title;
  @override
  @JsonKey()
  final String cover;
  @override
  @JsonKey()
  final String url;
  @override
  @JsonKey()
  final String description;
  @override
  final DateTime? publishedAt;
  @override
  final DateTime? createdAt;

  @override
  String toString() {
    return 'FeedItem(id: $id, platform: $platform, contentId: $contentId, mediaType: $mediaType, author: $author, title: $title, cover: $cover, url: $url, description: $description, publishedAt: $publishedAt, createdAt: $createdAt)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FeedItemImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.platform, platform) ||
                other.platform == platform) &&
            (identical(other.contentId, contentId) ||
                other.contentId == contentId) &&
            (identical(other.mediaType, mediaType) ||
                other.mediaType == mediaType) &&
            (identical(other.author, author) || other.author == author) &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.cover, cover) || other.cover == cover) &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.description, description) ||
                other.description == description) &&
            (identical(other.publishedAt, publishedAt) ||
                other.publishedAt == publishedAt) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    platform,
    contentId,
    mediaType,
    author,
    title,
    cover,
    url,
    description,
    publishedAt,
    createdAt,
  );

  /// Create a copy of FeedItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FeedItemImplCopyWith<_$FeedItemImpl> get copyWith =>
      __$$FeedItemImplCopyWithImpl<_$FeedItemImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$FeedItemImplToJson(this);
  }
}

abstract class _FeedItem implements FeedItem {
  const factory _FeedItem({
    required final int id,
    required final String platform,
    required final String contentId,
    final String mediaType,
    final String author,
    final String title,
    final String cover,
    final String url,
    final String description,
    final DateTime? publishedAt,
    final DateTime? createdAt,
  }) = _$FeedItemImpl;

  factory _FeedItem.fromJson(Map<String, dynamic> json) =
      _$FeedItemImpl.fromJson;

  @override
  int get id;
  @override
  String get platform;
  @override
  String get contentId;
  @override
  String get mediaType;
  @override
  String get author;
  @override
  String get title;
  @override
  String get cover;
  @override
  String get url;
  @override
  String get description;
  @override
  DateTime? get publishedAt;
  @override
  DateTime? get createdAt;

  /// Create a copy of FeedItem
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FeedItemImplCopyWith<_$FeedItemImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

FeedSubscription _$FeedSubscriptionFromJson(Map<String, dynamic> json) {
  return _FeedSubscription.fromJson(json);
}

/// @nodoc
mixin _$FeedSubscription {
  int get id => throw _privateConstructorUsedError;
  String get platform => throw _privateConstructorUsedError;
  String get name => throw _privateConstructorUsedError;
  String get target => throw _privateConstructorUsedError;
  String get cronExpr => throw _privateConstructorUsedError;
  bool get enabled => throw _privateConstructorUsedError;
  DateTime? get lastFetchedAt => throw _privateConstructorUsedError;
  DateTime? get createdAt => throw _privateConstructorUsedError;

  /// Serializes this FeedSubscription to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of FeedSubscription
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FeedSubscriptionCopyWith<FeedSubscription> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FeedSubscriptionCopyWith<$Res> {
  factory $FeedSubscriptionCopyWith(
    FeedSubscription value,
    $Res Function(FeedSubscription) then,
  ) = _$FeedSubscriptionCopyWithImpl<$Res, FeedSubscription>;
  @useResult
  $Res call({
    int id,
    String platform,
    String name,
    String target,
    String cronExpr,
    bool enabled,
    DateTime? lastFetchedAt,
    DateTime? createdAt,
  });
}

/// @nodoc
class _$FeedSubscriptionCopyWithImpl<$Res, $Val extends FeedSubscription>
    implements $FeedSubscriptionCopyWith<$Res> {
  _$FeedSubscriptionCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FeedSubscription
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? platform = null,
    Object? name = null,
    Object? target = null,
    Object? cronExpr = null,
    Object? enabled = null,
    Object? lastFetchedAt = freezed,
    Object? createdAt = freezed,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as int,
            platform: null == platform
                ? _value.platform
                : platform // ignore: cast_nullable_to_non_nullable
                      as String,
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            target: null == target
                ? _value.target
                : target // ignore: cast_nullable_to_non_nullable
                      as String,
            cronExpr: null == cronExpr
                ? _value.cronExpr
                : cronExpr // ignore: cast_nullable_to_non_nullable
                      as String,
            enabled: null == enabled
                ? _value.enabled
                : enabled // ignore: cast_nullable_to_non_nullable
                      as bool,
            lastFetchedAt: freezed == lastFetchedAt
                ? _value.lastFetchedAt
                : lastFetchedAt // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
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
abstract class _$$FeedSubscriptionImplCopyWith<$Res>
    implements $FeedSubscriptionCopyWith<$Res> {
  factory _$$FeedSubscriptionImplCopyWith(
    _$FeedSubscriptionImpl value,
    $Res Function(_$FeedSubscriptionImpl) then,
  ) = __$$FeedSubscriptionImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    int id,
    String platform,
    String name,
    String target,
    String cronExpr,
    bool enabled,
    DateTime? lastFetchedAt,
    DateTime? createdAt,
  });
}

/// @nodoc
class __$$FeedSubscriptionImplCopyWithImpl<$Res>
    extends _$FeedSubscriptionCopyWithImpl<$Res, _$FeedSubscriptionImpl>
    implements _$$FeedSubscriptionImplCopyWith<$Res> {
  __$$FeedSubscriptionImplCopyWithImpl(
    _$FeedSubscriptionImpl _value,
    $Res Function(_$FeedSubscriptionImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FeedSubscription
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? platform = null,
    Object? name = null,
    Object? target = null,
    Object? cronExpr = null,
    Object? enabled = null,
    Object? lastFetchedAt = freezed,
    Object? createdAt = freezed,
  }) {
    return _then(
      _$FeedSubscriptionImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as int,
        platform: null == platform
            ? _value.platform
            : platform // ignore: cast_nullable_to_non_nullable
                  as String,
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        target: null == target
            ? _value.target
            : target // ignore: cast_nullable_to_non_nullable
                  as String,
        cronExpr: null == cronExpr
            ? _value.cronExpr
            : cronExpr // ignore: cast_nullable_to_non_nullable
                  as String,
        enabled: null == enabled
            ? _value.enabled
            : enabled // ignore: cast_nullable_to_non_nullable
                  as bool,
        lastFetchedAt: freezed == lastFetchedAt
            ? _value.lastFetchedAt
            : lastFetchedAt // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
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
class _$FeedSubscriptionImpl implements _FeedSubscription {
  const _$FeedSubscriptionImpl({
    required this.id,
    required this.platform,
    required this.name,
    this.target = '',
    this.cronExpr = '0 */6 * * *',
    this.enabled = true,
    this.lastFetchedAt,
    this.createdAt,
  });

  factory _$FeedSubscriptionImpl.fromJson(Map<String, dynamic> json) =>
      _$$FeedSubscriptionImplFromJson(json);

  @override
  final int id;
  @override
  final String platform;
  @override
  final String name;
  @override
  @JsonKey()
  final String target;
  @override
  @JsonKey()
  final String cronExpr;
  @override
  @JsonKey()
  final bool enabled;
  @override
  final DateTime? lastFetchedAt;
  @override
  final DateTime? createdAt;

  @override
  String toString() {
    return 'FeedSubscription(id: $id, platform: $platform, name: $name, target: $target, cronExpr: $cronExpr, enabled: $enabled, lastFetchedAt: $lastFetchedAt, createdAt: $createdAt)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FeedSubscriptionImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.platform, platform) ||
                other.platform == platform) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.target, target) || other.target == target) &&
            (identical(other.cronExpr, cronExpr) ||
                other.cronExpr == cronExpr) &&
            (identical(other.enabled, enabled) || other.enabled == enabled) &&
            (identical(other.lastFetchedAt, lastFetchedAt) ||
                other.lastFetchedAt == lastFetchedAt) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    platform,
    name,
    target,
    cronExpr,
    enabled,
    lastFetchedAt,
    createdAt,
  );

  /// Create a copy of FeedSubscription
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FeedSubscriptionImplCopyWith<_$FeedSubscriptionImpl> get copyWith =>
      __$$FeedSubscriptionImplCopyWithImpl<_$FeedSubscriptionImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$FeedSubscriptionImplToJson(this);
  }
}

abstract class _FeedSubscription implements FeedSubscription {
  const factory _FeedSubscription({
    required final int id,
    required final String platform,
    required final String name,
    final String target,
    final String cronExpr,
    final bool enabled,
    final DateTime? lastFetchedAt,
    final DateTime? createdAt,
  }) = _$FeedSubscriptionImpl;

  factory _FeedSubscription.fromJson(Map<String, dynamic> json) =
      _$FeedSubscriptionImpl.fromJson;

  @override
  int get id;
  @override
  String get platform;
  @override
  String get name;
  @override
  String get target;
  @override
  String get cronExpr;
  @override
  bool get enabled;
  @override
  DateTime? get lastFetchedAt;
  @override
  DateTime? get createdAt;

  /// Create a copy of FeedSubscription
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FeedSubscriptionImplCopyWith<_$FeedSubscriptionImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

WatchLater _$WatchLaterFromJson(Map<String, dynamic> json) {
  return _WatchLater.fromJson(json);
}

/// @nodoc
mixin _$WatchLater {
  int get id => throw _privateConstructorUsedError;
  String get platform => throw _privateConstructorUsedError;
  String get contentId => throw _privateConstructorUsedError;
  DateTime? get createdAt => throw _privateConstructorUsedError;

  /// Serializes this WatchLater to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of WatchLater
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $WatchLaterCopyWith<WatchLater> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $WatchLaterCopyWith<$Res> {
  factory $WatchLaterCopyWith(
    WatchLater value,
    $Res Function(WatchLater) then,
  ) = _$WatchLaterCopyWithImpl<$Res, WatchLater>;
  @useResult
  $Res call({int id, String platform, String contentId, DateTime? createdAt});
}

/// @nodoc
class _$WatchLaterCopyWithImpl<$Res, $Val extends WatchLater>
    implements $WatchLaterCopyWith<$Res> {
  _$WatchLaterCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of WatchLater
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? platform = null,
    Object? contentId = null,
    Object? createdAt = freezed,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as int,
            platform: null == platform
                ? _value.platform
                : platform // ignore: cast_nullable_to_non_nullable
                      as String,
            contentId: null == contentId
                ? _value.contentId
                : contentId // ignore: cast_nullable_to_non_nullable
                      as String,
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
abstract class _$$WatchLaterImplCopyWith<$Res>
    implements $WatchLaterCopyWith<$Res> {
  factory _$$WatchLaterImplCopyWith(
    _$WatchLaterImpl value,
    $Res Function(_$WatchLaterImpl) then,
  ) = __$$WatchLaterImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({int id, String platform, String contentId, DateTime? createdAt});
}

/// @nodoc
class __$$WatchLaterImplCopyWithImpl<$Res>
    extends _$WatchLaterCopyWithImpl<$Res, _$WatchLaterImpl>
    implements _$$WatchLaterImplCopyWith<$Res> {
  __$$WatchLaterImplCopyWithImpl(
    _$WatchLaterImpl _value,
    $Res Function(_$WatchLaterImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of WatchLater
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? platform = null,
    Object? contentId = null,
    Object? createdAt = freezed,
  }) {
    return _then(
      _$WatchLaterImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as int,
        platform: null == platform
            ? _value.platform
            : platform // ignore: cast_nullable_to_non_nullable
                  as String,
        contentId: null == contentId
            ? _value.contentId
            : contentId // ignore: cast_nullable_to_non_nullable
                  as String,
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
class _$WatchLaterImpl implements _WatchLater {
  const _$WatchLaterImpl({
    required this.id,
    required this.platform,
    required this.contentId,
    this.createdAt,
  });

  factory _$WatchLaterImpl.fromJson(Map<String, dynamic> json) =>
      _$$WatchLaterImplFromJson(json);

  @override
  final int id;
  @override
  final String platform;
  @override
  final String contentId;
  @override
  final DateTime? createdAt;

  @override
  String toString() {
    return 'WatchLater(id: $id, platform: $platform, contentId: $contentId, createdAt: $createdAt)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$WatchLaterImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.platform, platform) ||
                other.platform == platform) &&
            (identical(other.contentId, contentId) ||
                other.contentId == contentId) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, id, platform, contentId, createdAt);

  /// Create a copy of WatchLater
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$WatchLaterImplCopyWith<_$WatchLaterImpl> get copyWith =>
      __$$WatchLaterImplCopyWithImpl<_$WatchLaterImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$WatchLaterImplToJson(this);
  }
}

abstract class _WatchLater implements WatchLater {
  const factory _WatchLater({
    required final int id,
    required final String platform,
    required final String contentId,
    final DateTime? createdAt,
  }) = _$WatchLaterImpl;

  factory _WatchLater.fromJson(Map<String, dynamic> json) =
      _$WatchLaterImpl.fromJson;

  @override
  int get id;
  @override
  String get platform;
  @override
  String get contentId;
  @override
  DateTime? get createdAt;

  /// Create a copy of WatchLater
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$WatchLaterImplCopyWith<_$WatchLaterImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
