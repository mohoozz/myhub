import 'package:freezed_annotation/freezed_annotation.dart';

part 'feed.freezed.dart';
part 'feed.g.dart';

/// 动态条目（对应后端 feed_items 表）。
@freezed
abstract class FeedItem with _$FeedItem {
  const factory FeedItem({
    required int id,
    required String platform,
    required String contentId,
    @Default('video') String mediaType,
    @Default('') String author,
    @Default('') String title,
    @Default('') String cover,
    @Default('') String url,
    @Default('') String description,
    DateTime? publishedAt,
    DateTime? createdAt,
  }) = _FeedItem;

  factory FeedItem.fromJson(Map<String, dynamic> json) =>
      _$FeedItemFromJson(json);
}

/// 动态订阅源（对应后端 feed_subscriptions 表）。
@freezed
abstract class FeedSubscription with _$FeedSubscription {
  const factory FeedSubscription({
    required int id,
    required String platform,
    required String name,
    @Default('') String target,
    @Default('0 */6 * * *') String cronExpr,
    @Default(true) bool enabled,
    DateTime? lastFetchedAt,
    DateTime? createdAt,
  }) = _FeedSubscription;

  factory FeedSubscription.fromJson(Map<String, dynamic> json) =>
      _$FeedSubscriptionFromJson(json);
}

/// 稍后观看条目（对应后端 watch_later 表）。
@freezed
abstract class WatchLater with _$WatchLater {
  const factory WatchLater({
    required int id,
    required String platform,
    required String contentId,
    DateTime? createdAt,
  }) = _WatchLater;

  factory WatchLater.fromJson(Map<String, dynamic> json) =>
      _$WatchLaterFromJson(json);
}
