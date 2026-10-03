import 'dart:convert';
import 'package:devota/main.dart';
import 'package:devota/terminal_profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final running in [false, true]) {
    testWidgets('computer selection controls all tabs while running=$running', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const channel = MethodChannel(
        'io.github.chasekolozsy.devota/control_agent',
      );
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'getAgentStatus') {
          return {'running': running, 'connected': running};
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      const first = TerminalProfile(
        id: 'first',
        name: 'Desktop',
        host: 'original',
        username: 'chase',
        serverUrl: 'http://original:8082',
        agentUrl: 'ws://original:8083/phone',
        agentWholeDevice: true,
      );
      const second = TerminalProfile(
        id: 'second',
        name: 'Palm',
        host: 'palm',
        username: 'chase',
        serverUrl: 'http://palm:8084',
        agentUrl: 'ws://palm:8083/phone',
      );
      SharedPreferences.setMockInitialValues({
        TerminalProfiles.profilesKey: jsonEncode([
          first.toJson(),
          second.toJson(),
        ]),
        TerminalProfiles.selectedKey: first.id,
        TerminalProfiles.unifiedKey: true,
      });
      FlutterSecureStorage.setMockInitialValues({
        first.secretKey('agent_token'): 'original-test-token',
        second.secretKey('agent_token'): 'palm-test-token',
      });
      await tester.pumpWidget(const DevOtaApp());
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      Future<void> tab(int i) async {
        tester
            .widget<TabBar>(find.byType(TabBar).first)
            .controller!
            .animateTo(i);
        await tester.pumpAndSettle();
      }

      Future<void> select(String name) async {
        final selector = find.byType(DropdownButtonFormField<String>);
        await tester.tap(
          selector.evaluate().isNotEmpty
              ? selector.first
              : find.byType(DropdownButton<String>),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(name).last);
        await tester.pumpAndSettle();
      }

      await tab(0);
      expect(find.text('New computer'), findsOneWidget);
      await select('Palm');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TerminalProfiles.selectedKey), 'second');
      expect(prefs.getString('active_server'), 'http://palm:8084');
      await tab(7);
      expect(find.text('Computer: Palm'), findsOneWidget);
      expect(find.text('ws://palm:8083/phone'), findsOneWidget);
      expect(find.text('palm-test-token'), findsOneWidget);
      expect(find.text('New profile'), findsNothing);
      await tab(3);
      await select('Desktop');
      expect(prefs.getString('active_server'), 'http://original:8082');
      await tab(7);
      expect(find.text('Computer: Desktop'), findsOneWidget);
      expect(find.text('original-test-token'), findsOneWidget);
      await tab(0);
      await tester.tap(find.text('New computer'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'Laptop');
      await tester.enterText(fields.at(1), 'http://laptop:8082');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(prefs.getString('active_server'), 'http://laptop:8082');
      await tab(7);
      expect(find.text('Computer: Laptop'), findsOneWidget);
      expect(find.text('original-test-token'), findsNothing);
      await tab(0);
      await select('Desktop');
      await tab(7);
      expect(find.text('original-test-token'), findsOneWidget);
      expect(
        calls.where((c) => c.method == 'startAgent' || c.method == 'stopAgent'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
