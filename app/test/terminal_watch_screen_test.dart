import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:devota/terminal_watch.dart';
import 'package:devota/terminal_watch_screen.dart';
import 'package:devota/terminal_macro.dart';

const pane = WatchedPane(
  id: '%0',
  identity: '1:2:3',
  label: 'test:1.0',
  window: '1',
);

void main() {
  late TerminalWatchController watch;
  setUp(() => watch = TerminalWatchController());
  tearDown(() => watch.dispose());

  Widget screen(Future<List<WatchedPane>> Function() load) => MaterialApp(
    home: TerminalWatchScreen(
      watch: watch,
      loadPanes: load,
      macros: [TerminalMacro(id: 'hello', name: 'Hello', steps: const [])],
      onSave: (_, _, _) async {},
    ),
  );

  testWidgets('setup opens immediately while discovery is pending', (
    tester,
  ) async {
    final pending = Completer<List<WatchedPane>>();
    await tester.pumpWidget(screen(() => pending.future));
    expect(find.text('Notification macros'), findsOneWidget);
    expect(find.text('Finding tmux windows over SSH…'), findsOneWidget);
    pending.complete([pane]);
    await tester.pumpAndSettle();
    expect(find.text('Window test:1.0 (%0)'), findsOneWidget);
    expect(find.text('Save notification controls'), findsOneWidget);
  });

  testWidgets('discovery error is visible and Retry loads windows', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      screen(() async {
        if (attempts++ == 0) throw StateError('tmux: command not found');
        return [pane];
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load terminal windows'), findsOneWidget);
    expect(find.textContaining('tmux: command not found'), findsOneWidget);
    expect(find.text('Save notification controls'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Window test:1.0 (%0)'), findsOneWidget);
  });

  testWidgets('discovery timeout stays on setup with Retry', (tester) async {
    final pending = Completer<List<WatchedPane>>();
    await tester.pumpWidget(screen(() => pending.future));
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.textContaining('timed out'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    pending.complete([pane]);
    await tester.pumpAndSettle();
    expect(find.textContaining('timed out'), findsOneWidget);
  });

  testWidgets('late discovery after leaving screen is harmless', (
    tester,
  ) async {
    final pending = Completer<List<WatchedPane>>();
    await tester.pumpWidget(screen(() => pending.future));
    await tester.pumpWidget(const MaterialApp(home: Text('Left setup')));
    pending.complete([pane]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
