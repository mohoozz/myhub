import 'package:drift/drift.dart';

/// 离线进度缓存表。
///
/// 网络不可用时先落本地（synced=false），恢复后由同步任务批量上报
/// （PUT /api/progress）并标记 synced=true。
class LocalProgress extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sourceId => integer()();
  TextColumn get filePath => text()();
  TextColumn get mediaType => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get cover => text().withDefault(const Constant(''))();
  TextColumn get progressJson => text().withDefault(const Constant(''))();
  RealColumn get percent => real().withDefault(const Constant(0))();
  BoolColumn get finished => boolean().withDefault(const Constant(false))();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {sourceId, filePath},
      ];
}

/// 离线下载队列（二期 M6）。
class DownloadTask extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sourceId => integer()();
  TextColumn get filePath => text()();
  TextColumn get localPath => text().withDefault(const Constant(''))();

  /// pending / downloading / paused / completed / failed
  TextColumn get status => text().withDefault(const Constant('pending'))();

  IntColumn get totalBytes => integer().withDefault(const Constant(0))();
  IntColumn get downloadedBytes => integer().withDefault(const Constant(0))();
  TextColumn get error => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
