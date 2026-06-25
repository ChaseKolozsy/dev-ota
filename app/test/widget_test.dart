import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:devota/main.dart';
import 'package:devota/ssh_terminal_tab.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const DevOtaApp());
    expect(find.text('DevOTA'), findsOneWidget);
  });

  testWidgets('saved terminal command prefixes existing composer text', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 700,
            child: SshTerminalTab(
              dio: Dio(),
              serverUrl: 'http://127.0.0.1:8082',
              quickCommands: const ['plan'],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final composer = find.byType(TextField);
    await tester.enterText(composer, 'summarize what I just said');
    await tester.tap(find.text('plan'));
    await tester.pump();

    final textField = tester.widget<TextField>(composer);
    expect(textField.controller?.text, 'plan summarize what I just said');
    await tester.pump(const Duration(milliseconds: 300));
  });
}
