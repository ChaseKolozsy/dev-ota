import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:devota/main.dart';
import 'package:devota/files_tab.dart';
import 'package:devota/ssh_terminal_tab.dart';

/// Returns a canned JSON body for every request, so widget tests can render
/// server-backed tabs without a live build server.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body);

  final String body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

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

  testWidgets('long-pressing a folded bar hides its content, not its label', (
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
              quickCommands: const ['plan'],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Both bars and their content are visible by default.
    expect(find.text('tmux'), findsOneWidget);
    expect(find.text('cmds'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Prefix'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'plan'), findsOneWidget);

    // Fold cmds: its label stays (stacked into the tmux row) and its button
    // disappears, while the tmux row is untouched — no wasted row.
    await tester.longPress(find.text('cmds'));
    await tester.pumpAndSettle();
    expect(find.text('cmds'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'plan'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Prefix'), findsOneWidget);

    // Long-press the folded cmds label again to unfold it back to a full row.
    await tester.longPress(find.text('cmds'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, 'plan'), findsOneWidget);
  });

  testWidgets('adding a custom control-pad key does not crash', (
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

    // Open the customization sheet, then the "Add" menu on the top row.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add button').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom…').last);
    await tester.pumpAndSettle();

    // Enter a human-friendly key spec; the editor resolves it live.
    await tester.enterText(
      find.widgetWithText(TextField, 'Abbreviation (shown on the button)'),
      'C-z',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Key(s) to send'),
      'Ctrl-Z',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Sends: Ctrl-Z'), findsOneWidget);

    // Saving previously tripped the `_dependents.isEmpty` assertion.
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('C-z'), findsWidgets);
  });

  testWidgets('Files tab lists files and folders with the right actions', (
    WidgetTester tester,
  ) async {
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter(
        jsonEncode({
          'status': 'ok',
          'dir': '/home/chase/dev-ota/.devota-cache/file-transfer',
          'files': [
            {
              'name': 'report.zip',
              'type': 'file',
              'size': 2048,
              'modified': '2026-07-04 21:00:00',
              'contentType': 'application/zip',
              'downloadPath': '/files/download/report.zip',
            },
            {
              'name': 'myproject',
              'type': 'dir',
              'size': 4096,
              'fileCount': 7,
              'modified': '2026-07-04 21:05:00',
              'contentType': 'application/zip',
              'archivePath': '/files/archive/myproject',
            },
          ],
        }),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 700,
            child: FilesTab(dio: dio, serverUrl: 'http://127.0.0.1:8082'),
          ),
        ),
      ),
    );
    // Let the stubbed GET /files resolve (no spinner remains after it loads).
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('File transfers'), findsOneWidget);
    expect(find.textContaining('.devota-cache/file-transfer'), findsOneWidget);
    // The zip file offers Extract; the folder renders with a folder icon.
    expect(find.text('report.zip'), findsOneWidget);
    expect(find.byIcon(Icons.unarchive_outlined), findsOneWidget);
    expect(find.text('myproject'), findsOneWidget);
    expect(find.byIcon(Icons.folder), findsOneWidget);
    expect(find.textContaining('7 files'), findsOneWidget);
    // One download button per row (zip file + folder).
    expect(find.byIcon(Icons.download), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
