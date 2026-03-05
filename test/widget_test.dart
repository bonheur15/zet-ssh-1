import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:testing/main.dart';

void main() {
  testWidgets('renders cozy glass window', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const CozyGlassApp());

    expect(find.text('Cozy Workspace'), findsOneWidget);
    expect(find.text('Warm. Calm. Focused.'), findsOneWidget);
  });
}
