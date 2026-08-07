// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $LocalProgressTable extends LocalProgress
    with TableInfo<$LocalProgressTable, LocalProgressData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalProgressTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<int> sourceId = GeneratedColumn<int>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _filePathMeta = const VerificationMeta(
    'filePath',
  );
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
    'file_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mediaTypeMeta = const VerificationMeta(
    'mediaType',
  );
  @override
  late final GeneratedColumn<String> mediaType = GeneratedColumn<String>(
    'media_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _coverMeta = const VerificationMeta('cover');
  @override
  late final GeneratedColumn<String> cover = GeneratedColumn<String>(
    'cover',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _progressJsonMeta = const VerificationMeta(
    'progressJson',
  );
  @override
  late final GeneratedColumn<String> progressJson = GeneratedColumn<String>(
    'progress_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _percentMeta = const VerificationMeta(
    'percent',
  );
  @override
  late final GeneratedColumn<double> percent = GeneratedColumn<double>(
    'percent',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _finishedMeta = const VerificationMeta(
    'finished',
  );
  @override
  late final GeneratedColumn<bool> finished = GeneratedColumn<bool>(
    'finished',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("finished" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _syncedMeta = const VerificationMeta('synced');
  @override
  late final GeneratedColumn<bool> synced = GeneratedColumn<bool>(
    'synced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("synced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sourceId,
    filePath,
    mediaType,
    title,
    cover,
    progressJson,
    percent,
    finished,
    deleted,
    synced,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_progress';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalProgressData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('file_path')) {
      context.handle(
        _filePathMeta,
        filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta),
      );
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('media_type')) {
      context.handle(
        _mediaTypeMeta,
        mediaType.isAcceptableOrUnknown(data['media_type']!, _mediaTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_mediaTypeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('cover')) {
      context.handle(
        _coverMeta,
        cover.isAcceptableOrUnknown(data['cover']!, _coverMeta),
      );
    }
    if (data.containsKey('progress_json')) {
      context.handle(
        _progressJsonMeta,
        progressJson.isAcceptableOrUnknown(
          data['progress_json']!,
          _progressJsonMeta,
        ),
      );
    }
    if (data.containsKey('percent')) {
      context.handle(
        _percentMeta,
        percent.isAcceptableOrUnknown(data['percent']!, _percentMeta),
      );
    }
    if (data.containsKey('finished')) {
      context.handle(
        _finishedMeta,
        finished.isAcceptableOrUnknown(data['finished']!, _finishedMeta),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    if (data.containsKey('synced')) {
      context.handle(
        _syncedMeta,
        synced.isAcceptableOrUnknown(data['synced']!, _syncedMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {sourceId, filePath},
  ];
  @override
  LocalProgressData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalProgressData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_id'],
      )!,
      filePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_path'],
      )!,
      mediaType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_type'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      cover: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover'],
      )!,
      progressJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}progress_json'],
      )!,
      percent: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}percent'],
      )!,
      finished: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}finished'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      synced: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}synced'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LocalProgressTable createAlias(String alias) {
    return $LocalProgressTable(attachedDatabase, alias);
  }
}

class LocalProgressData extends DataClass
    implements Insertable<LocalProgressData> {
  final int id;
  final int sourceId;
  final String filePath;
  final String mediaType;
  final String title;
  final String cover;
  final String progressJson;
  final double percent;
  final bool finished;

  /// 本地已删除待同步标记：离线删除时置 true，联网后由同步任务删后端并清理。
  final bool deleted;
  final bool synced;
  final DateTime updatedAt;
  const LocalProgressData({
    required this.id,
    required this.sourceId,
    required this.filePath,
    required this.mediaType,
    required this.title,
    required this.cover,
    required this.progressJson,
    required this.percent,
    required this.finished,
    required this.deleted,
    required this.synced,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['source_id'] = Variable<int>(sourceId);
    map['file_path'] = Variable<String>(filePath);
    map['media_type'] = Variable<String>(mediaType);
    map['title'] = Variable<String>(title);
    map['cover'] = Variable<String>(cover);
    map['progress_json'] = Variable<String>(progressJson);
    map['percent'] = Variable<double>(percent);
    map['finished'] = Variable<bool>(finished);
    map['deleted'] = Variable<bool>(deleted);
    map['synced'] = Variable<bool>(synced);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LocalProgressCompanion toCompanion(bool nullToAbsent) {
    return LocalProgressCompanion(
      id: Value(id),
      sourceId: Value(sourceId),
      filePath: Value(filePath),
      mediaType: Value(mediaType),
      title: Value(title),
      cover: Value(cover),
      progressJson: Value(progressJson),
      percent: Value(percent),
      finished: Value(finished),
      deleted: Value(deleted),
      synced: Value(synced),
      updatedAt: Value(updatedAt),
    );
  }

  factory LocalProgressData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalProgressData(
      id: serializer.fromJson<int>(json['id']),
      sourceId: serializer.fromJson<int>(json['sourceId']),
      filePath: serializer.fromJson<String>(json['filePath']),
      mediaType: serializer.fromJson<String>(json['mediaType']),
      title: serializer.fromJson<String>(json['title']),
      cover: serializer.fromJson<String>(json['cover']),
      progressJson: serializer.fromJson<String>(json['progressJson']),
      percent: serializer.fromJson<double>(json['percent']),
      finished: serializer.fromJson<bool>(json['finished']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      synced: serializer.fromJson<bool>(json['synced']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceId': serializer.toJson<int>(sourceId),
      'filePath': serializer.toJson<String>(filePath),
      'mediaType': serializer.toJson<String>(mediaType),
      'title': serializer.toJson<String>(title),
      'cover': serializer.toJson<String>(cover),
      'progressJson': serializer.toJson<String>(progressJson),
      'percent': serializer.toJson<double>(percent),
      'finished': serializer.toJson<bool>(finished),
      'deleted': serializer.toJson<bool>(deleted),
      'synced': serializer.toJson<bool>(synced),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  LocalProgressData copyWith({
    int? id,
    int? sourceId,
    String? filePath,
    String? mediaType,
    String? title,
    String? cover,
    String? progressJson,
    double? percent,
    bool? finished,
    bool? deleted,
    bool? synced,
    DateTime? updatedAt,
  }) => LocalProgressData(
    id: id ?? this.id,
    sourceId: sourceId ?? this.sourceId,
    filePath: filePath ?? this.filePath,
    mediaType: mediaType ?? this.mediaType,
    title: title ?? this.title,
    cover: cover ?? this.cover,
    progressJson: progressJson ?? this.progressJson,
    percent: percent ?? this.percent,
    finished: finished ?? this.finished,
    deleted: deleted ?? this.deleted,
    synced: synced ?? this.synced,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LocalProgressData copyWithCompanion(LocalProgressCompanion data) {
    return LocalProgressData(
      id: data.id.present ? data.id.value : this.id,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType,
      title: data.title.present ? data.title.value : this.title,
      cover: data.cover.present ? data.cover.value : this.cover,
      progressJson: data.progressJson.present
          ? data.progressJson.value
          : this.progressJson,
      percent: data.percent.present ? data.percent.value : this.percent,
      finished: data.finished.present ? data.finished.value : this.finished,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      synced: data.synced.present ? data.synced.value : this.synced,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalProgressData(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('filePath: $filePath, ')
          ..write('mediaType: $mediaType, ')
          ..write('title: $title, ')
          ..write('cover: $cover, ')
          ..write('progressJson: $progressJson, ')
          ..write('percent: $percent, ')
          ..write('finished: $finished, ')
          ..write('deleted: $deleted, ')
          ..write('synced: $synced, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourceId,
    filePath,
    mediaType,
    title,
    cover,
    progressJson,
    percent,
    finished,
    deleted,
    synced,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalProgressData &&
          other.id == this.id &&
          other.sourceId == this.sourceId &&
          other.filePath == this.filePath &&
          other.mediaType == this.mediaType &&
          other.title == this.title &&
          other.cover == this.cover &&
          other.progressJson == this.progressJson &&
          other.percent == this.percent &&
          other.finished == this.finished &&
          other.deleted == this.deleted &&
          other.synced == this.synced &&
          other.updatedAt == this.updatedAt);
}

class LocalProgressCompanion extends UpdateCompanion<LocalProgressData> {
  final Value<int> id;
  final Value<int> sourceId;
  final Value<String> filePath;
  final Value<String> mediaType;
  final Value<String> title;
  final Value<String> cover;
  final Value<String> progressJson;
  final Value<double> percent;
  final Value<bool> finished;
  final Value<bool> deleted;
  final Value<bool> synced;
  final Value<DateTime> updatedAt;
  const LocalProgressCompanion({
    this.id = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.filePath = const Value.absent(),
    this.mediaType = const Value.absent(),
    this.title = const Value.absent(),
    this.cover = const Value.absent(),
    this.progressJson = const Value.absent(),
    this.percent = const Value.absent(),
    this.finished = const Value.absent(),
    this.deleted = const Value.absent(),
    this.synced = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  LocalProgressCompanion.insert({
    this.id = const Value.absent(),
    required int sourceId,
    required String filePath,
    required String mediaType,
    this.title = const Value.absent(),
    this.cover = const Value.absent(),
    this.progressJson = const Value.absent(),
    this.percent = const Value.absent(),
    this.finished = const Value.absent(),
    this.deleted = const Value.absent(),
    this.synced = const Value.absent(),
    required DateTime updatedAt,
  }) : sourceId = Value(sourceId),
       filePath = Value(filePath),
       mediaType = Value(mediaType),
       updatedAt = Value(updatedAt);
  static Insertable<LocalProgressData> custom({
    Expression<int>? id,
    Expression<int>? sourceId,
    Expression<String>? filePath,
    Expression<String>? mediaType,
    Expression<String>? title,
    Expression<String>? cover,
    Expression<String>? progressJson,
    Expression<double>? percent,
    Expression<bool>? finished,
    Expression<bool>? deleted,
    Expression<bool>? synced,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceId != null) 'source_id': sourceId,
      if (filePath != null) 'file_path': filePath,
      if (mediaType != null) 'media_type': mediaType,
      if (title != null) 'title': title,
      if (cover != null) 'cover': cover,
      if (progressJson != null) 'progress_json': progressJson,
      if (percent != null) 'percent': percent,
      if (finished != null) 'finished': finished,
      if (deleted != null) 'deleted': deleted,
      if (synced != null) 'synced': synced,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  LocalProgressCompanion copyWith({
    Value<int>? id,
    Value<int>? sourceId,
    Value<String>? filePath,
    Value<String>? mediaType,
    Value<String>? title,
    Value<String>? cover,
    Value<String>? progressJson,
    Value<double>? percent,
    Value<bool>? finished,
    Value<bool>? deleted,
    Value<bool>? synced,
    Value<DateTime>? updatedAt,
  }) {
    return LocalProgressCompanion(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      filePath: filePath ?? this.filePath,
      mediaType: mediaType ?? this.mediaType,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      progressJson: progressJson ?? this.progressJson,
      percent: percent ?? this.percent,
      finished: finished ?? this.finished,
      deleted: deleted ?? this.deleted,
      synced: synced ?? this.synced,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<int>(sourceId.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (mediaType.present) {
      map['media_type'] = Variable<String>(mediaType.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (cover.present) {
      map['cover'] = Variable<String>(cover.value);
    }
    if (progressJson.present) {
      map['progress_json'] = Variable<String>(progressJson.value);
    }
    if (percent.present) {
      map['percent'] = Variable<double>(percent.value);
    }
    if (finished.present) {
      map['finished'] = Variable<bool>(finished.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (synced.present) {
      map['synced'] = Variable<bool>(synced.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalProgressCompanion(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('filePath: $filePath, ')
          ..write('mediaType: $mediaType, ')
          ..write('title: $title, ')
          ..write('cover: $cover, ')
          ..write('progressJson: $progressJson, ')
          ..write('percent: $percent, ')
          ..write('finished: $finished, ')
          ..write('deleted: $deleted, ')
          ..write('synced: $synced, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $DownloadTaskTable extends DownloadTask
    with TableInfo<$DownloadTaskTable, DownloadTaskData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadTaskTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<int> sourceId = GeneratedColumn<int>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _filePathMeta = const VerificationMeta(
    'filePath',
  );
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
    'file_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _totalBytesMeta = const VerificationMeta(
    'totalBytes',
  );
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
    'total_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _downloadedBytesMeta = const VerificationMeta(
    'downloadedBytes',
  );
  @override
  late final GeneratedColumn<int> downloadedBytes = GeneratedColumn<int>(
    'downloaded_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sourceId,
    filePath,
    localPath,
    status,
    totalBytes,
    downloadedBytes,
    error,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_task';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadTaskData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('file_path')) {
      context.handle(
        _filePathMeta,
        filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta),
      );
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
        _totalBytesMeta,
        totalBytes.isAcceptableOrUnknown(data['total_bytes']!, _totalBytesMeta),
      );
    }
    if (data.containsKey('downloaded_bytes')) {
      context.handle(
        _downloadedBytesMeta,
        downloadedBytes.isAcceptableOrUnknown(
          data['downloaded_bytes']!,
          _downloadedBytesMeta,
        ),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadTaskData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadTaskData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_id'],
      )!,
      filePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_path'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      totalBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_bytes'],
      )!,
      downloadedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}downloaded_bytes'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DownloadTaskTable createAlias(String alias) {
    return $DownloadTaskTable(attachedDatabase, alias);
  }
}

class DownloadTaskData extends DataClass
    implements Insertable<DownloadTaskData> {
  final int id;
  final int sourceId;
  final String filePath;
  final String localPath;

  /// pending / downloading / paused / completed / failed
  final String status;
  final int totalBytes;
  final int downloadedBytes;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;
  const DownloadTaskData({
    required this.id,
    required this.sourceId,
    required this.filePath,
    required this.localPath,
    required this.status,
    required this.totalBytes,
    required this.downloadedBytes,
    this.error,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['source_id'] = Variable<int>(sourceId);
    map['file_path'] = Variable<String>(filePath);
    map['local_path'] = Variable<String>(localPath);
    map['status'] = Variable<String>(status);
    map['total_bytes'] = Variable<int>(totalBytes);
    map['downloaded_bytes'] = Variable<int>(downloadedBytes);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  DownloadTaskCompanion toCompanion(bool nullToAbsent) {
    return DownloadTaskCompanion(
      id: Value(id),
      sourceId: Value(sourceId),
      filePath: Value(filePath),
      localPath: Value(localPath),
      status: Value(status),
      totalBytes: Value(totalBytes),
      downloadedBytes: Value(downloadedBytes),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory DownloadTaskData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadTaskData(
      id: serializer.fromJson<int>(json['id']),
      sourceId: serializer.fromJson<int>(json['sourceId']),
      filePath: serializer.fromJson<String>(json['filePath']),
      localPath: serializer.fromJson<String>(json['localPath']),
      status: serializer.fromJson<String>(json['status']),
      totalBytes: serializer.fromJson<int>(json['totalBytes']),
      downloadedBytes: serializer.fromJson<int>(json['downloadedBytes']),
      error: serializer.fromJson<String?>(json['error']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceId': serializer.toJson<int>(sourceId),
      'filePath': serializer.toJson<String>(filePath),
      'localPath': serializer.toJson<String>(localPath),
      'status': serializer.toJson<String>(status),
      'totalBytes': serializer.toJson<int>(totalBytes),
      'downloadedBytes': serializer.toJson<int>(downloadedBytes),
      'error': serializer.toJson<String?>(error),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  DownloadTaskData copyWith({
    int? id,
    int? sourceId,
    String? filePath,
    String? localPath,
    String? status,
    int? totalBytes,
    int? downloadedBytes,
    Value<String?> error = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => DownloadTaskData(
    id: id ?? this.id,
    sourceId: sourceId ?? this.sourceId,
    filePath: filePath ?? this.filePath,
    localPath: localPath ?? this.localPath,
    status: status ?? this.status,
    totalBytes: totalBytes ?? this.totalBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    error: error.present ? error.value : this.error,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DownloadTaskData copyWithCompanion(DownloadTaskCompanion data) {
    return DownloadTaskData(
      id: data.id.present ? data.id.value : this.id,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      status: data.status.present ? data.status.value : this.status,
      totalBytes: data.totalBytes.present
          ? data.totalBytes.value
          : this.totalBytes,
      downloadedBytes: data.downloadedBytes.present
          ? data.downloadedBytes.value
          : this.downloadedBytes,
      error: data.error.present ? data.error.value : this.error,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadTaskData(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('filePath: $filePath, ')
          ..write('localPath: $localPath, ')
          ..write('status: $status, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('error: $error, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourceId,
    filePath,
    localPath,
    status,
    totalBytes,
    downloadedBytes,
    error,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadTaskData &&
          other.id == this.id &&
          other.sourceId == this.sourceId &&
          other.filePath == this.filePath &&
          other.localPath == this.localPath &&
          other.status == this.status &&
          other.totalBytes == this.totalBytes &&
          other.downloadedBytes == this.downloadedBytes &&
          other.error == this.error &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class DownloadTaskCompanion extends UpdateCompanion<DownloadTaskData> {
  final Value<int> id;
  final Value<int> sourceId;
  final Value<String> filePath;
  final Value<String> localPath;
  final Value<String> status;
  final Value<int> totalBytes;
  final Value<int> downloadedBytes;
  final Value<String?> error;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const DownloadTaskCompanion({
    this.id = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.filePath = const Value.absent(),
    this.localPath = const Value.absent(),
    this.status = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.error = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  DownloadTaskCompanion.insert({
    this.id = const Value.absent(),
    required int sourceId,
    required String filePath,
    this.localPath = const Value.absent(),
    this.status = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.error = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : sourceId = Value(sourceId),
       filePath = Value(filePath),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<DownloadTaskData> custom({
    Expression<int>? id,
    Expression<int>? sourceId,
    Expression<String>? filePath,
    Expression<String>? localPath,
    Expression<String>? status,
    Expression<int>? totalBytes,
    Expression<int>? downloadedBytes,
    Expression<String>? error,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceId != null) 'source_id': sourceId,
      if (filePath != null) 'file_path': filePath,
      if (localPath != null) 'local_path': localPath,
      if (status != null) 'status': status,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (downloadedBytes != null) 'downloaded_bytes': downloadedBytes,
      if (error != null) 'error': error,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  DownloadTaskCompanion copyWith({
    Value<int>? id,
    Value<int>? sourceId,
    Value<String>? filePath,
    Value<String>? localPath,
    Value<String>? status,
    Value<int>? totalBytes,
    Value<int>? downloadedBytes,
    Value<String?>? error,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
  }) {
    return DownloadTaskCompanion(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      filePath: filePath ?? this.filePath,
      localPath: localPath ?? this.localPath,
      status: status ?? this.status,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<int>(sourceId.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (downloadedBytes.present) {
      map['downloaded_bytes'] = Variable<int>(downloadedBytes.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadTaskCompanion(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('filePath: $filePath, ')
          ..write('localPath: $localPath, ')
          ..write('status: $status, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('error: $error, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $LocalProgressTable localProgress = $LocalProgressTable(this);
  late final $DownloadTaskTable downloadTask = $DownloadTaskTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localProgress,
    downloadTask,
  ];
}

typedef $$LocalProgressTableCreateCompanionBuilder =
    LocalProgressCompanion Function({
      Value<int> id,
      required int sourceId,
      required String filePath,
      required String mediaType,
      Value<String> title,
      Value<String> cover,
      Value<String> progressJson,
      Value<double> percent,
      Value<bool> finished,
      Value<bool> deleted,
      Value<bool> synced,
      required DateTime updatedAt,
    });
typedef $$LocalProgressTableUpdateCompanionBuilder =
    LocalProgressCompanion Function({
      Value<int> id,
      Value<int> sourceId,
      Value<String> filePath,
      Value<String> mediaType,
      Value<String> title,
      Value<String> cover,
      Value<String> progressJson,
      Value<double> percent,
      Value<bool> finished,
      Value<bool> deleted,
      Value<bool> synced,
      Value<DateTime> updatedAt,
    });

class $$LocalProgressTableFilterComposer
    extends Composer<_$AppDatabase, $LocalProgressTable> {
  $$LocalProgressTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cover => $composableBuilder(
    column: $table.cover,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get progressJson => $composableBuilder(
    column: $table.progressJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get finished => $composableBuilder(
    column: $table.finished,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalProgressTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalProgressTable> {
  $$LocalProgressTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cover => $composableBuilder(
    column: $table.cover,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get progressJson => $composableBuilder(
    column: $table.progressJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get finished => $composableBuilder(
    column: $table.finished,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalProgressTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalProgressTable> {
  $$LocalProgressTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<String> get mediaType =>
      $composableBuilder(column: $table.mediaType, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get cover =>
      $composableBuilder(column: $table.cover, builder: (column) => column);

  GeneratedColumn<String> get progressJson => $composableBuilder(
    column: $table.progressJson,
    builder: (column) => column,
  );

  GeneratedColumn<double> get percent =>
      $composableBuilder(column: $table.percent, builder: (column) => column);

  GeneratedColumn<bool> get finished =>
      $composableBuilder(column: $table.finished, builder: (column) => column);

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<bool> get synced =>
      $composableBuilder(column: $table.synced, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LocalProgressTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalProgressTable,
          LocalProgressData,
          $$LocalProgressTableFilterComposer,
          $$LocalProgressTableOrderingComposer,
          $$LocalProgressTableAnnotationComposer,
          $$LocalProgressTableCreateCompanionBuilder,
          $$LocalProgressTableUpdateCompanionBuilder,
          (
            LocalProgressData,
            BaseReferences<
              _$AppDatabase,
              $LocalProgressTable,
              LocalProgressData
            >,
          ),
          LocalProgressData,
          PrefetchHooks Function()
        > {
  $$LocalProgressTableTableManager(_$AppDatabase db, $LocalProgressTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalProgressTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalProgressTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalProgressTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> sourceId = const Value.absent(),
                Value<String> filePath = const Value.absent(),
                Value<String> mediaType = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> cover = const Value.absent(),
                Value<String> progressJson = const Value.absent(),
                Value<double> percent = const Value.absent(),
                Value<bool> finished = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => LocalProgressCompanion(
                id: id,
                sourceId: sourceId,
                filePath: filePath,
                mediaType: mediaType,
                title: title,
                cover: cover,
                progressJson: progressJson,
                percent: percent,
                finished: finished,
                deleted: deleted,
                synced: synced,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int sourceId,
                required String filePath,
                required String mediaType,
                Value<String> title = const Value.absent(),
                Value<String> cover = const Value.absent(),
                Value<String> progressJson = const Value.absent(),
                Value<double> percent = const Value.absent(),
                Value<bool> finished = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                required DateTime updatedAt,
              }) => LocalProgressCompanion.insert(
                id: id,
                sourceId: sourceId,
                filePath: filePath,
                mediaType: mediaType,
                title: title,
                cover: cover,
                progressJson: progressJson,
                percent: percent,
                finished: finished,
                deleted: deleted,
                synced: synced,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalProgressTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalProgressTable,
      LocalProgressData,
      $$LocalProgressTableFilterComposer,
      $$LocalProgressTableOrderingComposer,
      $$LocalProgressTableAnnotationComposer,
      $$LocalProgressTableCreateCompanionBuilder,
      $$LocalProgressTableUpdateCompanionBuilder,
      (
        LocalProgressData,
        BaseReferences<_$AppDatabase, $LocalProgressTable, LocalProgressData>,
      ),
      LocalProgressData,
      PrefetchHooks Function()
    >;
typedef $$DownloadTaskTableCreateCompanionBuilder =
    DownloadTaskCompanion Function({
      Value<int> id,
      required int sourceId,
      required String filePath,
      Value<String> localPath,
      Value<String> status,
      Value<int> totalBytes,
      Value<int> downloadedBytes,
      Value<String?> error,
      required DateTime createdAt,
      required DateTime updatedAt,
    });
typedef $$DownloadTaskTableUpdateCompanionBuilder =
    DownloadTaskCompanion Function({
      Value<int> id,
      Value<int> sourceId,
      Value<String> filePath,
      Value<String> localPath,
      Value<String> status,
      Value<int> totalBytes,
      Value<int> downloadedBytes,
      Value<String?> error,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
    });

class $$DownloadTaskTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadTaskTable> {
  $$DownloadTaskTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadTaskTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadTaskTable> {
  $$DownloadTaskTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadTaskTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadTaskTable> {
  $$DownloadTaskTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DownloadTaskTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadTaskTable,
          DownloadTaskData,
          $$DownloadTaskTableFilterComposer,
          $$DownloadTaskTableOrderingComposer,
          $$DownloadTaskTableAnnotationComposer,
          $$DownloadTaskTableCreateCompanionBuilder,
          $$DownloadTaskTableUpdateCompanionBuilder,
          (
            DownloadTaskData,
            BaseReferences<_$AppDatabase, $DownloadTaskTable, DownloadTaskData>,
          ),
          DownloadTaskData,
          PrefetchHooks Function()
        > {
  $$DownloadTaskTableTableManager(_$AppDatabase db, $DownloadTaskTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadTaskTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadTaskTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadTaskTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> sourceId = const Value.absent(),
                Value<String> filePath = const Value.absent(),
                Value<String> localPath = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<int> downloadedBytes = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => DownloadTaskCompanion(
                id: id,
                sourceId: sourceId,
                filePath: filePath,
                localPath: localPath,
                status: status,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                error: error,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int sourceId,
                required String filePath,
                Value<String> localPath = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<int> downloadedBytes = const Value.absent(),
                Value<String?> error = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
              }) => DownloadTaskCompanion.insert(
                id: id,
                sourceId: sourceId,
                filePath: filePath,
                localPath: localPath,
                status: status,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                error: error,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadTaskTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadTaskTable,
      DownloadTaskData,
      $$DownloadTaskTableFilterComposer,
      $$DownloadTaskTableOrderingComposer,
      $$DownloadTaskTableAnnotationComposer,
      $$DownloadTaskTableCreateCompanionBuilder,
      $$DownloadTaskTableUpdateCompanionBuilder,
      (
        DownloadTaskData,
        BaseReferences<_$AppDatabase, $DownloadTaskTable, DownloadTaskData>,
      ),
      DownloadTaskData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalProgressTableTableManager get localProgress =>
      $$LocalProgressTableTableManager(_db, _db.localProgress);
  $$DownloadTaskTableTableManager get downloadTask =>
      $$DownloadTaskTableTableManager(_db, _db.downloadTask);
}
