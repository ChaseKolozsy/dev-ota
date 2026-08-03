import 'package:devota/macro_editor_screen.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _longCommand =
    'cd /home/chase/dev-ota && flutter build apk --debug --split-per-abi '
    '--target-platform android-arm64 --build-number=2026080201';

/// Pushes the editor and hands back the route result future (the outer future
/// completes once the editor is on screen; the inner one when it is saved).
Future<Future<TerminalMacro?>> _openEditor(
  WidgetTester tester,
  TerminalMacro macro,
) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ),
  );
  final result = navigatorKey.currentState!.push<TerminalMacro>(
    MaterialPageRoute(builder: (_) => MacroEditorScreen(macro: macro)),
  );
  await tester.pumpAndSettle();
  return result;
}

TerminalMacro _shellMacro(String command) {
  return TerminalMacro(
    id: 'macro-1',
    name: 'Build',
    steps: [
      TerminalMacroStep(
        id: 'step-1',
        type: TerminalMacroStepType.shell,
        value: command,
        delaySeconds: 0,
      ),
    ],
  );
}

Finder get _fullScreenCommandField =>
    find.byWidgetPredicate((widget) => widget is TextField && widget.expands);

void main() {
  testWidgets('inline command edits survive a save', (tester) async {
    final result = await _openEditor(tester, _shellMacro('flutter test'));

    await tester.enterText(find.widgetWithText(TextField, 'Command'), 'ls -la');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = await result;
    expect(saved, isNotNull);
    expect(saved!.steps.single.value, 'ls -la');
    expect(saved.name, 'Build');
  });

  testWidgets('long commands round-trip through the full-screen editor', (
    tester,
  ) async {
    final result = await _openEditor(tester, _shellMacro(_longCommand));

    await tester.tap(find.text('Edit full screen'));
    await tester.pumpAndSettle();

    // The whole command now sits in a field that fills the page body.
    expect(find.text('Step 1'), findsOneWidget);
    final field = tester.widget<TextField>(_fullScreenCommandField);
    expect(field.controller?.text, _longCommand);

    await tester.enterText(_fullScreenCommandField, '$_longCommand --fast');
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = await result;
    expect(saved!.steps.single.value, '$_longCommand --fast');
  });

  testWidgets('steps can be added and reordered', (tester) async {
    final result = await _openEditor(tester, _shellMacro('one'));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Key'));
    await tester.pumpAndSettle();
    expect(find.text('Terminal key'), findsOneWidget);

    // Move the new key step above the command through the step menu.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = await result;
    expect(saved!.steps, hasLength(2));
    expect(saved.steps.first.type, TerminalMacroStepType.terminalKey);
    expect(saved.steps.last.value, 'one');
  });

  testWidgets('blank commands are dropped instead of saved', (tester) async {
    final result = await _openEditor(tester, _shellMacro('keep me'));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Command'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = await result;
    expect(saved!.steps, hasLength(1));
    expect(saved.steps.single.value, 'keep me');
  });

  testWidgets('step cards lay out on a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final macro = TerminalMacro(
      id: 'macro-1',
      name: 'A macro with a fairly long name',
      steps: [
        TerminalMacroStep(
          id: 'step-1',
          type: TerminalMacroStepType.shell,
          value: _longCommand,
          delaySeconds: 12.5,
        ),
        TerminalMacroStep(
          id: 'step-2',
          type: TerminalMacroStepType.terminalKey,
          value: 'enter',
          delaySeconds: 0,
        ),
        TerminalMacroStep(
          id: 'step-3',
          type: TerminalMacroStepType.tmux,
          value: 'c',
          delaySeconds: 0,
        ),
        TerminalMacroStep(
          id: 'step-4',
          type: TerminalMacroStepType.wait,
          value: '',
          delaySeconds: 2,
        ),
      ],
    );

    await _openEditor(tester, macro);
    // Any RenderFlex overflow would surface here as a framework exception.
    expect(tester.takeException(), isNull);
    expect(find.byType(Card), findsAtLeastNWidgets(4));

    // The step menu also has to fit; it overflowed with longer labels.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(180, 8));
    await tester.pumpAndSettle();

    // ...and so does the rest of the list once it is scrolled into view.
    await tester.drag(find.byType(CircleAvatar).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(OutlinedButton, 'Wait'), findsOneWidget);
  });

  testWidgets('unknown option values from MCP macros are preserved', (
    tester,
  ) async {
    final result = await _openEditor(
      tester,
      TerminalMacro(
        id: 'macro-1',
        name: 'Agent made',
        steps: [
          TerminalMacroStep(
            id: 'step-1',
            type: TerminalMacroStepType.tmux,
            value: 'z',
            delaySeconds: 0,
          ),
        ],
      ),
    );

    expect(find.text('z  (custom)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = await result;
    expect(saved!.steps.single.value, 'z');
  });

  test('delay parsing rejects junk and negatives', () {
    expect(parseMacroDelaySeconds('1.5'), 1.5);
    expect(parseMacroDelaySeconds(' 2 '), 2);
    expect(parseMacroDelaySeconds(''), 0);
    expect(parseMacroDelaySeconds('-3'), 0);
    expect(parseMacroDelaySeconds('abc'), 0);
    expect(formatMacroDelaySeconds(0), '');
    expect(formatMacroDelaySeconds(2), '2');
    expect(formatMacroDelaySeconds(0.5), '0.5');
  });
}
