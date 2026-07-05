import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  testWidgets('control pad shows default keys and opens customization sheet', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 700,
            child: SshTerminalTab(
              dio: Dio(),
              serverUrl: 'http://127.0.0.1:8082',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Default control pad renders its built-in text pills.
    expect(find.widgetWithText(OutlinedButton, 'Tab'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'PgUp'), findsOneWidget);

    // The tune icon in the tools header opens the customization sheet.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('Control pad buttons'), findsOneWidget);
    expect(find.text('Top row'), findsOneWidget);
    expect(find.text('Bottom row'), findsOneWidget);
  });
}
