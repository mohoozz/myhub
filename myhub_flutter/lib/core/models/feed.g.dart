// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'feed.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$FeedItemImpl _$$FeedItemImplFromJson(Map<String, dynamic> json) =>
    _$FeedItemImpl(
      id: (json['id'] as num).toInt(),
      platform: json['platform'] as String,
      contentId: json['content_id'] as String,
      mediaType: json['media_type'] as String? ?? 'video',
      author: json['author'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      url: json['url'] as String? ?? '',
      description: json['description'] as String? ?? '',
      publishedAt: json['published_at'] == null
          ? null
          : DateTime.parse(json['published_at'] as String),
      createdAt: json['created_at'] == null
          ? null
          : DateTime.parse(json['created_at'] as String),
    );

Map<String, dynamic> _$$FeedItemImplToJson(_$FeedItemImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'platform': instance.platform,
      'content_id': instance.contentId,
      'media_type': instance.mediaType,
      'author': instance.author,
      'title': instance.title,
      'cover': instance.cover,
      'url': instance.url,
      'description': instance.description,
      'published_at': instance.publishedAt?.toIso8601String(),
      'created_at': instance.createdAt?.toIso8601String(),
    };

_$FeedSubscriptionImpl _$$FeedSubscriptionImplFromJson(
  Map<String, dynamic> json,
) => _$FeedSubscriptionImpl(
  id: (json['id'] as num).toInt(),
  platform: json['platform'] as String,
  name: json['name'] as String,
  target: json['target'] as String? ?? '',
  cronExpr: json['cron_expr'] as String? ?? '0 */6 * * *',
  enabled: json['enabled'] as bool? ?? true,
  lastFetchedAt: json['last_fetched_at'] == null
      ? null
      : DateTime.parse(json['last_fetched_at'] as String),
  createdAt: json['created_at'] == null
      ? null
      : DateTime.parse(json['created_at'] as String),
);

Map<String, dynamic> _$$FeedSubscriptionImplToJson(
  _$FeedSubscriptionImpl instance,
) => <String, dynamic>{
  'id': instance.id,
  'platform': instance.platform,
  'name': instance.name,
  'target': instance.target,
  'cron_expr': instance.cronExpr,
  'enabled': instance.enabled,
  'last_fetched_at': instance.lastFetchedAt?.toIso8601String(),
  'created_at': instance.createdAt?.toIso8601String(),
};

_$WatchLaterImpl _$$WatchLaterImplFromJson(Map<String, dynamic> json) =>
    _$WatchLaterImpl(
      id: (json['id'] as num).toInt(),
      platform: json['platform'] as String,
      contentId: json['content_id'] as String,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.parse(json['created_at'] as String),
      item: json['item'] == null
          ? null
          : FeedItem.fromJson(json['item'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$$WatchLaterImplToJson(_$WatchLaterImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'platform': instance.platform,
      'content_id': instance.contentId,
      'created_at': instance.createdAt?.toIso8601String(),
      'item': instance.item?.toJson(),
    };
