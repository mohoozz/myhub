import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/core/models/comic.dart';
import 'package:myhub_flutter/core/models/favorite.dart';
import 'package:myhub_flutter/core/models/feed.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/core/models/reader.dart';
import 'package:myhub_flutter/core/models/reading_progress.dart';
import 'package:myhub_flutter/core/models/source.dart';
import 'package:myhub_flutter/core/models/trash_item.dart';
import 'package:myhub_flutter/core/models/user.dart';

void main() {
  test('User fromJson', () {
    final u = User.fromJson({
      'id': 1,
      'username': 'admin',
      'created_at': '2026-08-06T01:00:00Z',
    });
    expect(u.id, 1);
    expect(u.username, 'admin');
    expect(u.createdAt, isNotNull);
  });

  test('Source fromJson（snake_case 映射 + 枚举）', () {
    final s = Source.fromJson({
      'id': 2,
      'name': 'NAS',
      'type': 'webdav',
      'config_json': '{"url":"https://nas"}',
      'mount_point': '/media',
      'enabled': true,
      'created_at': '2026-08-06T01:00:00Z',
    });
    expect(s.type, SourceType.webdav);
    expect(s.configJson, contains('nas'));
    expect(s.mountPoint, '/media');
  });

  test('FileItem fromJson + 便捷判定', () {
    final f = FileItem.fromJson({
      'name': 'movie.mp4',
      'path': '/v/movie.mp4',
      'size': 1024,
      'is_dir': false,
      'mod_time': '2026-08-06T01:00:00Z',
      'media_type': 'video',
    });
    expect(f.isVideo, isTrue);
    expect(f.isNovel, isFalse);
  });

  test('TrashItem fromJson', () {
    final t = TrashItem.fromJson({
      'id': 1,
      'source_id': 1,
      'original_path': '/a.txt',
      'trash_path': '/.trash/x_a.txt',
      'size': 5,
      'deleted_at': '2026-08-06T01:00:00Z',
    });
    expect(t.originalPath, '/a.txt');
  });

  test('FavoritePage 分页结构', () {
    final p = FavoritePage.fromJson({
      'list': [
        {
          'id': 1,
          'source_id': 1,
          'file_path': '/v/a.mp4',
          'media_type': 'video',
          'size': 10,
          'created_at': '2026-08-06T01:00:00Z',
        }
      ],
      'total': 1,
      'page': 1,
      'page_size': 50,
    });
    expect(p.list.single.filePath, '/v/a.mp4');
    expect(p.total, 1);
  });

  test('ReadingProgress fromJson', () {
    final p = ReadingProgress.fromJson({
      'id': 1,
      'source_id': 1,
      'file_path': '/b/a.txt',
      'media_type': 'novel',
      'title': 'Novel',
      'progress_json': '{"chapter":3}',
      'percent': 30.5,
      'finished': false,
      'updated_at': '2026-08-06T01:00:00Z',
    });
    expect(p.percent, 30.5);
    expect(p.finished, isFalse);
  });

  test('NovelChapters / NovelContent fromJson', () {
    final c = NovelChapters.fromJson({
      'ready': true,
      'encoding': 'gbk',
      'chapters': [
        {'index': 0, 'title': '卷首'},
        {'index': 1, 'title': '第一章 开始'},
      ],
      'total': 2,
    });
    expect(c.chapters[1].title, '第一章 开始');

    final content = NovelContent.fromJson({
      'ready': true,
      'chapter': 1,
      'title': '第一章 开始',
      'content': '正文',
      'total': 2,
    });
    expect(content.content, '正文');
  });

  test('EpubMeta fromJson（含 TOC）', () {
    final m = EpubMeta.fromJson({
      'title': '测试书',
      'author': '作者',
      'cover_id': 'cover',
      'is_comic': false,
      'toc': [
        {'title': '第一章', 'href': 'OEBPS/ch1.xhtml'},
      ],
    });
    expect(m.toc.single.href, 'OEBPS/ch1.xhtml');
  });

  test('ComicDetect / ComicPages / ArchiveTree fromJson', () {
    final d = ComicDetect.fromJson({'is_comic': true, 'reason': 'sniff'});
    expect(d.isComic, isTrue);

    final pages = ComicPages.fromJson({
      'pages': [
        {'index': 0, 'name': 'p1.jpg', 'size': 100},
      ],
      'total': 1,
    });
    expect(pages.pages.single.name, 'p1.jpg');

    final tree = ArchiveTree.fromJson({
      'entries': [
        {'name': 'dir/', 'size': 0, 'is_dir': true},
      ],
      'total': 1,
    });
    expect(tree.entries.single.isDir, isTrue);
  });

  test('FeedItem / FeedSubscription / WatchLater fromJson', () {
    final item = FeedItem.fromJson({
      'id': 1,
      'platform': 'bilibili',
      'content_id': 'BV1xx',
      'media_type': 'video',
      'author': 'UP主',
      'title': '标题',
      'published_at': '2026-08-06T01:00:00Z',
    });
    expect(item.contentId, 'BV1xx');

    final sub = FeedSubscription.fromJson({
      'id': 1,
      'platform': 'youtube',
      'name': '频道',
      'target': 'UCxxx',
      'cron_expr': '0 */6 * * *',
      'enabled': true,
      'last_fetched_at': null,
    });
    expect(sub.cronExpr, '0 */6 * * *');
    expect(sub.lastFetchedAt, isNull);

    final wl = WatchLater.fromJson({
      'id': 1,
      'platform': 'bilibili',
      'content_id': 'BV1xx',
    });
    expect(wl.platform, 'bilibili');
  });

  test('toJson 回写 snake_case', () {
    const f = FileItem(name: 'a.mp4', path: '/a.mp4', mediaType: 'video');
    final json = f.toJson();
    expect(json['media_type'], 'video');
    expect(json['is_dir'], isFalse);
  });
}
