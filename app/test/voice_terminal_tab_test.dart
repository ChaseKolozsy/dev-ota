import 'dart:convert';

import 'package:devota/ssh_terminal_tab.dart';
import 'package:devota/terminal_macro.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real Terminal tab through the devota/voice_control channel and
/// asserts on the bytes its own button handlers write to the session.
void main() {
  const channel = MethodChannel('devota/voice_control');
  const codec = StandardMethodCodec();
  late List<String> writes;
  late List<MethodCall> native;

  const deploy = TerminalMacro(
    id: 'macro-deploy',
    name: 'Deploy staging',
    steps: [
      TerminalMacroStep(
        id: 's1',
        type: TerminalMacroStepType.shell,
        value: 'make deploy',
        delaySeconds: 0,
      ),
    ],
  );

  setUp(() {
    writes = [];
    native = [];
    SharedPreferences.setMockInitialValues({
      // A custom pad key the user added, known only at runtime.
      'terminal_pad_config_json': jsonEncode({
        'version': 1,
        'customKeys': [
          {
            'id': 'custom:1',
            'abbreviation': 'C-z',
            'name': 'Ctrl-Z',
            'sequence': '\x1a',
            'builtin': false,
          },
        ],
        'rows': [
          {
            'middleIds': ['tab', 'esc', 'ctrl_c', 'slash', 'custom:1'],
            'fixedRightId': 'backspace',
          },
          {
            'middleIds': ['home', 'end', 'page_up', 'page_down'],
            'fixedRightId': 'enter',
          },
        ],
      }),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          native.add(call);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpTab(WidgetTester tester, {bool connected = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 800,
            child: SshTerminalTab(
              dio: Dio(),
              serverUrl: 'http://127.0.0.1:8082',
              quickCommands: const ['/compact', '/exit', 'git status'],
              quickMacros: const [deploy],
              testHooks: SshTerminalTestHooks(
                sessionSink: connected ? writes.add : null,
                requestMicrophone: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> toggleOn(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Voice control off'));
    await tester.pump();
    expect(find.byTooltip('Voice control on'), findsOneWidget);
  }

  Future<Map?> say(WidgetTester tester, String text) async {
    ByteData? reply;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('utterance', {'text': text})),
      (data) => reply = data,
    );
    await tester.pump();
    return codec.decodeEnvelope(reply!) as Map?;
  }

  String composer(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  testWidgets('with the toggle off there is no recognizer and no service', (
    tester,
  ) async {
    await pumpTab(tester);
    expect(native, isEmpty);
    expect(await say(tester, 'page up'), {'stop': true});
    expect(writes, isEmpty);
    await toggleOn(tester);
    expect(native.map((c) => c.method), ['start']);
    await tester.tap(find.byTooltip('Voice control on'));
    await tester.pump();
    expect(native.map((c) => c.method), contains('stop'));
    expect(await say(tester, 'page up'), {'stop': true});
    expect(writes, isEmpty);
    await settle(tester);
  });

  testWidgets('pad keys and arrows run the pad-key path', (tester) async {
    await pumpTab(tester);
    await toggleOn(tester);
    final expected = {
      'tab': '\t',
      'escape': '\x1B',
      'slash': '/',
      'home': '\x1B[H',
      'end': '\x1B[F',
      'page up': '\x1B[5~',
      'Page down': '\x1B[6~',
      'enter': '\r',
      'backspace': '\x7F',
      'arrow up': '\x1B[A',
      'arrow down': '\x1B[B',
      'left': '\x1B[D',
      'right arrow': '\x1B[C',
      'control Z': '\x1a',
    };
    for (final entry in expected.entries) {
      writes.clear();
      final reply = await say(tester, entry.key);
      expect(reply?['tone'], 'command', reason: entry.key);
      expect(writes, [entry.value], reason: entry.key);
    }
    expect(composer(tester), isEmpty);
    expect(find.textContaining("Voice: heard 'control Z'"), findsOneWidget);
    await settle(tester);
  });

  testWidgets('tmux row commands run the tmux buttons', (tester) async {
    await pumpTab(tester);
    await toggleOn(tester);
    final expected = {
      'next window': '\x02n',
      'previous window': '\x02p',
      'new window': '\x02c',
      'list': '\x02w',
      'scroll': '\x02[',
    };
    for (final entry in expected.entries) {
      writes.clear();
      await say(tester, entry.key);
      expect(writes, [entry.value], reason: entry.key);
    }
    // Scroll mode is on now, so the row shows "Exit scroll" and that is
    // what the voice vocabulary holds.
    expect(find.widgetWithText(OutlinedButton, 'Exit scroll'), findsOneWidget);
    writes.clear();
    await say(tester, 'exit scroll');
    expect(writes, ['q']);
    await settle(tester);
  });

  testWidgets('macros and cmds run by the name on their button', (
    tester,
  ) async {
    await pumpTab(tester);
    await toggleOn(tester);
    await say(tester, 'compact');
    expect(writes, ['/compact\n']);
    writes.clear();
    await say(tester, 'run deploy staging');
    await tester.pump(const Duration(milliseconds: 300));
    expect(writes.join(), 'make deploy\r');
    await settle(tester);
  });

  testWidgets('dictation builds the composer; send submits it once', (
    tester,
  ) async {
    await pumpTab(tester);
    await toggleOn(tester);
    final reply = await say(tester, 'fix the failing test');
    expect(reply?['tone'], 'dictation');
    await say(tester, 'in the parser');
    expect(composer(tester), 'fix the failing test in the parser');
    expect(writes, isEmpty);
    await say(tester, 'delete two words');
    expect(composer(tester), 'fix the failing test in');
    await say(tester, 'backspace three');
    expect(composer(tester), 'fix the failing test');
    expect(writes, isEmpty, reason: 'composer edits never reach the terminal');
    await say(tester, 'send');
    expect(writes, ['fix the failing test\n']);
    expect(composer(tester), isEmpty);
    await say(tester, 'submit');
    expect(writes, ['fix the failing test\n']);
    await say(tester, 'scratch that');
    await say(tester, 'clear');
    expect(composer(tester), isEmpty);
    await settle(tester);
  });

  testWidgets('control C and exit wait for yes', (tester) async {
    await pumpTab(tester);
    await toggleOn(tester);
    final ask = await say(tester, 'control C');
    expect(ask?['speak'], 'Say yes to confirm');
    expect(writes, isEmpty);
    expect(find.textContaining('say yes to run Ctrl-C'), findsOneWidget);
    await say(tester, 'yes');
    expect(writes, ['\x03']);

    writes.clear();
    await say(tester, 'exit');
    await say(tester, 'no');
    expect(writes, isEmpty);

    await say(tester, '/exit');
    await tester.pump(const Duration(seconds: 11));
    expect(find.textContaining('no answer'), findsOneWidget);
    expect(native.where((c) => c.method == 'speak').last.arguments, {
      'text': 'Cancelled',
    });
    await say(tester, 'yes');
    expect(writes, isEmpty);
    expect(composer(tester), 'yes');
    await settle(tester);
  });

  testWidgets('not connected: says so and queues nothing', (tester) async {
    await pumpTab(tester, connected: false);
    await toggleOn(tester);
    final reply = await say(tester, 'page up');
    expect(reply?['speak'], 'Not connected');
    await say(tester, 'some dictation');
    expect(composer(tester), isEmpty);
    expect(writes, isEmpty);
    expect(find.textContaining('not connected'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('"stop listening" turns the toggle off', (tester) async {
    await pumpTab(tester);
    await toggleOn(tester);
    final reply = await say(tester, 'stop listening');
    expect(reply?['stop'], isTrue);
    expect(find.byTooltip('Voice control off'), findsOneWidget);
    expect(find.text('Voice: stopped by voice'), findsOneWidget);
    await settle(tester);
  });
}
