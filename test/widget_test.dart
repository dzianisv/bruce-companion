// Smoke test: the app boots to its home screen without any device connected.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bruce_companion/app.dart';

void main() {
  testWidgets('App boots without connecting', (WidgetTester tester) async {
    await tester.pumpWidget(const BruceCompanionApp());
    await tester.pump();

    // Root MaterialApp is present and nothing threw during first build.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
