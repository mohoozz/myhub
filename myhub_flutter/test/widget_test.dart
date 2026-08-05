import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhub_flutter/app.dart';

void main() {
  testWidgets('app boots and shows the login page', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MyhubApp()));
    await tester.pump();
    expect(find.text('myhub'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });
}
