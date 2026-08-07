import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/features/browse/providers/browse_provider.dart';
import 'package:myhub_flutter/features/browse/widgets/breadcrumb_bar.dart';
import 'package:myhub_flutter/shared/utils/format.dart';

void main() {
  group('parentPathOf', () {
    test('逐级向上', () {
      expect(parentPathOf('/a/b/c'), '/a/b');
      expect(parentPathOf('/a/b'), '/a');
      expect(parentPathOf('/a'), '/');
      expect(parentPathOf('/'), '/');
      expect(parentPathOf('/a/'), '/');
    });
  });

  group('formatBytes', () {
    test('各单位换算', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });

  group('formatModTime', () {
    test('null 显示 -', () {
      expect(formatModTime(null), '-');
    });

    test('格式化时间', () {
      final t = DateTime(2026, 8, 6, 2, 30);
      expect(formatModTime(t), '2026-08-06 02:30');
    });
  });

  group('BreadcrumbBar', () {
    testWidgets('根路径只显示根标签且不可点', (tester) async {
      final navigated = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BreadcrumbBar(
              rootLabel: 'NAS',
              path: '/',
              onNavigate: navigated.add,
            ),
          ),
        ),
      );
      expect(find.text('NAS/'), findsOneWidget);
      await tester.tap(find.text('NAS/'));
      expect(navigated, isEmpty);
    });

    testWidgets('逐级渲染并可回跳', (tester) async {
      final navigated = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BreadcrumbBar(
              rootLabel: 'NAS',
              path: '/videos/movies',
              onNavigate: navigated.add,
            ),
          ),
        ),
      );

      expect(find.text('NAS'), findsOneWidget);
      expect(find.text('videos'), findsOneWidget);
      expect(find.text('movies'), findsOneWidget);

      await tester.tap(find.text('videos'));
      expect(navigated, ['/videos']);

      await tester.tap(find.text('NAS'));
      expect(navigated, ['/videos', '/']);

      // 当前层级不可点
      await tester.tap(find.text('movies'));
      expect(navigated, hasLength(2));
    });
  });
}
