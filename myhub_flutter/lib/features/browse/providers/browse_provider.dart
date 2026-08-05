import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myhub_flutter/core/api/file_api.dart';
import 'package:myhub_flutter/core/models/file_item.dart';
import 'package:myhub_flutter/shared/providers/source_provider.dart';

/// 浏览页视图模式。
enum BrowseViewMode { grid, list }

/// 排序字段。
enum SortField { name, size, modTime }

/// 排序规则。
class SortSpec {
  const SortSpec({this.field = SortField.name, this.ascending = true});

  final SortField field;
  final bool ascending;

  String get label => switch (field) {
        SortField.name => '按名称',
        SortField.size => '按大小',
        SortField.modTime => '按时间',
      };
}

/// 当前目录路径（相对路径源根，'/' 开头）。
final browsePathProvider = StateProvider<String>((ref) => '/');

/// 计算上级目录路径：'/a/b' → '/a'，'/a' → '/'。
String parentPathOf(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final idx = trimmed.lastIndexOf('/');
  return idx <= 0 ? '/' : trimmed.substring(0, idx);
}

/// 视图模式。
final viewModeProvider = StateProvider<BrowseViewMode>(
  (ref) => BrowseViewMode.list,
);

/// 排序规则。
final sortProvider = StateProvider<SortSpec>((ref) => const SortSpec());

/// 当前目录搜索关键字（前端过滤）。
final searchQueryProvider = StateProvider<String>((ref) => '');

/// 当前目录文件列表。
final fileListProvider =
    AsyncNotifierProvider<FileListNotifier, List<FileItem>>(
  FileListNotifier.new,
);

class FileListNotifier extends AsyncNotifier<List<FileItem>> {
  @override
  Future<List<FileItem>> build() {
    final source = ref.watch(effectiveSourceProvider);
    final path = ref.watch(browsePathProvider);
    if (source == null) {
      return Future.value(const []);
    }
    return _fetch(source.id, path);
  }

  Future<List<FileItem>> _fetch(int sourceId, String path) async {
    final raw = await ref.read(fileApiProvider).listFiles(sourceId, path);
    return raw
        .map((e) => FileItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 下拉刷新。
  Future<void> refresh() async {
    final source = ref.read(effectiveSourceProvider);
    if (source == null) return;
    final path = ref.read(browsePathProvider);
    state = await AsyncValue.guard(() => _fetch(source.id, path));
  }
}

/// 应用搜索过滤 + 排序后的可见文件列表。
final visibleFilesProvider = Provider<AsyncValue<List<FileItem>>>((ref) {
  final async = ref.watch(fileListProvider);
  final query = ref.watch(searchQueryProvider).trim().toLowerCase();
  final sort = ref.watch(sortProvider);

  return async.whenData((items) {
    final filtered = query.isEmpty
        ? items
        : items
            .where((f) => f.name.toLowerCase().contains(query))
            .toList();

    // 文件夹恒在前，组内按排序规则
    int rank(FileItem f) => f.isDir ? 0 : 1;
    int compare(FileItem a, FileItem b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final result = switch (sort.field) {
        SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortField.size => a.size.compareTo(b.size),
        SortField.modTime => (a.modTime ?? DateTime(1970))
            .compareTo(b.modTime ?? DateTime(1970)),
      };
      return sort.ascending ? result : -result;
    }

    return [...filtered]..sort(compare);
  });
});
