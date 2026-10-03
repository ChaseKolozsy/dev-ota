import 'dart:convert';
import 'package:devota/ssh_terminal_sessions.dart';
import 'package:devota/ssh_terminal_tab.dart';
import 'package:devota/terminal_profiles.dart';
import 'package:devota/terminal_macro.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets(
    'switching retains two connected terminals and their independent scrollback',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({
        TerminalProfiles.profilesKey: jsonEncode([
          const TerminalProfile(
            id: 'first',
            name: 'First computer',
            host: 'first.example',
            username: 'first-user',
          ).toJson(),
          const TerminalProfile(
            id: 'second',
            name: 'Second computer',
            host: 'second.example',
            username: 'second-user',
          ).toJson(),
        ]),
        TerminalProfiles.selectedKey: 'first',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final controller = TerminalMacroController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshTerminalSessions(
              terminal: SshTerminalTab(
                dio: Dio(),
                serverUrl: '',
                macroController: controller,
                testHooks: SshTerminalTestHooks(sessionSink: (_) {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      first.write('\r\nfirst retained output\r\n');
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(
        tester.getSize(find.byType(DropdownButton<String>)).height,
        lessThanOrEqualTo(30),
      );
      expect(
        tester.getRect(find.byType(DropdownButton<String>)).bottom,
        lessThan(tester.getRect(find.byTooltip('Up')).top),
      );
      final expandedHeight = tester.getSize(find.byType(TerminalView)).height;
      await tester.longPress(find.text('sessions'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.text('sessions'), findsNothing);
      expect(find.byTooltip('Sessions'), findsOneWidget);
      final folded = tester.getRect(find.byTooltip('Sessions'));
      final up = tester.getRect(find.byTooltip('Up'));
      expect(folded.right, lessThanOrEqualTo(up.left));
      expect(folded.top, up.top);
      expect(
        tester.getSize(find.byType(TerminalView)).height,
        greaterThan(expandedHeight),
      );
      await tester.longPress(find.byTooltip('Sessions'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      await tester.tap(find.text('Tools'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsNothing);
      await tester.tap(find.text('Tools'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(first),
      );

      Future<void> select(String name) async {
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is Text && widget.data?.startsWith(name) == true,
              )
              .last,
        );
        await tester.pumpAndSettle();
      }

      await select('Second computer');
      final second = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      expect(second, isNot(same(first)));
      second.write('\r\nsecond retained output\r\n');
      expect(
        find.byType(SshTerminalTab, skipOffstage: false),
        findsNWidgets(2),
      );
      await select('First computer');
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(first),
      );
      expect(first.buffer.getText(), contains('first retained output'));
      expect(first.buffer.getText(), isNot(contains('second retained output')));
      expect(controller.canRun, isTrue);
      await tester.tap(find.byTooltip('SSH settings'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect'), findsOneWidget);
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Host',
      );
      expect(tester.widget<TextField>(field).controller!.text, 'first.example');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await select('Second computer');
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(second),
      );
      expect(second.buffer.getText(), contains('second retained output'));
      expect(controller.canRun, isTrue);
      await tester.tap(find.byTooltip('SSH settings'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'second.example',
      );
      // Disconnect only the second session, then prove the first is still live.
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await select('First computer');
      expect(controller.canRun, isTrue);
      expect(first.buffer.getText(), contains('first retained output'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      controller.dispose();
    },
  );
}
