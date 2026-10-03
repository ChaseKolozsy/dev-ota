import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:flutter/services.dart';
import 'package:devota/ssh_terminal_tab.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final connected in [false, true]) {
    testWidgets(
      'switching computers preserves settings with connected=$connected',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({
          'ssh_host': 'first.example',
          'ssh_port': '2222',
          'ssh_username': 'first-user',
        });
        FlutterSecureStorage.setMockInitialValues({
          'ssh_profile:first.example:2222:password': 'first-password',
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SshTerminalTab(
                dio: Dio(),
                serverUrl: '',
                testHooks: SshTerminalTestHooks(
                  sessionSink: connected ? (_) {} : null,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('SSH settings'));
        await tester.pumpAndSettle();
        Finder field(String label) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
        );
        expect(
          tester.widget<TextField>(field('Host')).controller!.text,
          'first.example',
        );
        await tester.tap(find.text('New profile'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'Other computer',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Host')).controller!.text,
          isEmpty,
        );
        expect(
          tester.widget<TextField>(field('Password')).controller!.text,
          isEmpty,
        );
        expect(tester.widget<TextField>(field('Host')).enabled, isTrue);
        await tester.enterText(field('Host'), 'second.example');
        await tester.enterText(field('User'), 'second-user');
        await tester.enterText(field('Password'), 'second-password');
        await tester.pumpAndSettle();
        Future<void> select(String name) async {
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(name).last);
          await tester.pumpAndSettle();
        }

        await select('Existing computer');
        expect(
          tester.widget<TextField>(field('Host')).controller!.text,
          'first.example',
        );
        expect(
          tester.widget<TextField>(field('Port')).controller!.text,
          '2222',
        );
        expect(
          tester.widget<TextField>(field('User')).controller!.text,
          'first-user',
        );
        expect(
          tester.widget<TextField>(field('Password')).controller!.text,
          'first-password',
        );
        await select('Other computer');
        expect(
          tester.widget<TextField>(field('Host')).controller!.text,
          'second.example',
        );
        expect(
          tester.widget<TextField>(field('User')).controller!.text,
          'second-user',
        );
        expect(
          tester.widget<TextField>(field('Password')).controller!.text,
          'second-password',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }
  testWidgets(
    'generating a key for another computer preserves the first public key',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copiedPublicKey;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedPublicKey = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final signingKey = ed25519.SigningKey.generate();
      final originalKey = OpenSSHEd25519KeyPair(
        Uint8List.fromList(signingKey.verifyKey.asTypedList),
        Uint8List.fromList(signingKey.asTypedList),
        'original-test-key',
      );
      final originalPem = originalKey.toPem();
      final expectedPublicKey =
          '${originalKey.name} ${base64.encode(originalKey.toPublicKey().encode())} original-test-key';
      SharedPreferences.setMockInitialValues({
        'ssh_host': 'first.example',
        'ssh_username': 'first-user',
        'ssh_use_private_key': true,
      });
      FlutterSecureStorage.setMockInitialValues({
        'ssh_profile:first.example:22:private_key': originalPem,
        'ssh_terminal_generated_private_key': originalPem,
        'ssh_terminal_generated_public_key': expectedPublicKey,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshTerminalTab(dio: Dio(), serverUrl: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('SSH settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New profile'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Other computer',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final generate = find.widgetWithText(OutlinedButton, 'Key');
      await tester.ensureVisible(generate);
      await tester.tap(generate);
      await tester.pumpAndSettle();
      const storage = FlutterSecureStorage();
      expect(
        await storage.read(key: 'ssh_terminal_generated_public_key'),
        isNot(expectedPublicKey),
      );
      final dropdown = find.byType(DropdownButtonFormField<String>);
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Existing computer').last);
      await tester.pumpAndSettle();
      final copy = find.byTooltip('Copy generated public key');
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copiedPublicKey, expectedPublicKey);
      expect(
        await storage.read(key: 'ssh_profile:id:existing:private_key'),
        originalPem,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
