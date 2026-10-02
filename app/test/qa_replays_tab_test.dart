import 'dart:convert';

import 'package:devota/main.dart';
import 'package:devota/macro_editor_screen.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'authoring and QA tabs separate saved macros and create device replays',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'macros_json': jsonEncode([
          {
            'id': 'author',
            'name': 'Author a lesson',
            'steps': [
              {'id': 'shell', 'type': 'shell', 'value': 'author'},
            ],
          },
          {
            'id': 'qa',
            'name': 'Replay onboarding',
            'steps': [
              {'id': 'device', 'type': 'device', 'value': '{"action":"home"}'},
              {'id': 'wait', 'type': 'wait', 'delaySeconds': 1},
            ],
          },
        ]),
      });
      await tester.pumpWidget(const DevOtaApp());
      await tester.pump(const Duration(milliseconds: 300));
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.tabs, hasLength(10));
      expect(find.text('QA replays'), findsOneWidget);
      tabs.controller!.animateTo(5);
      await tester.pumpAndSettle();
      expect(find.text('Author a lesson'), findsOneWidget);
      expect(find.text('Replay onboarding'), findsNothing);

      tabs.controller!.animateTo(6);
      await tester.pumpAndSettle();
      expect(find.text('Replay onboarding'), findsOneWidget);
      expect(find.text('Author a lesson'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Replay'));
      await tester.pumpAndSettle();
      final editor = tester.widget<MacroEditorScreen>(
        find.byType(MacroEditorScreen),
      );
      expect(editor.macro.name, 'New QA replay');
      expect(editor.macro.steps.single.type, TerminalMacroStepType.device);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
