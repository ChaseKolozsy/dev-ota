import 'dart:async';
import 'dart:io';

import 'package:devota/voice/voice_commands.dart';
import 'package:devota/voice/voice_control.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Terminal tab as a fake: records which button handler ran.
class FakeSurface implements VoiceSurface {
  bool connected = true;
  bool busy = false;
  bool canSend = true;
  String composer = '';
  List<String> screen = const [];
  final ran = <String>[];
  int sends = 0;
  List<VoiceTarget> Function(FakeSurface) build = defaultTargets;

  static List<VoiceTarget> defaultTargets(FakeSurface s) => [
    VoiceTarget(
      kind: VoiceTargetKind.padKey,
      id: 'page_up',
      label: 'Page Up',
      abbreviation: 'PgUp',
      run: () => s.ran.add('page_up'),
    ),
    VoiceTarget(
      kind: VoiceTargetKind.padKey,
      id: 'ctrl_c',
      label: 'Ctrl-C',
      abbreviation: 'C-c',
      confirm: true,
      run: () => s.ran.add('ctrl_c'),
    ),
    VoiceTarget(
      kind: VoiceTargetKind.command,
      id: '/exit',
      label: '/exit',
      confirm: isExitLabel('/exit'),
      run: () => s.ran.add('/exit'),
    ),
    VoiceTarget(
      kind: VoiceTargetKind.macro,
      id: 'm1',
      label: 'Deploy',
      enabled: false,
      run: () => s.ran.add('m1'),
    ),
  ];

  @override
  bool get voiceConnected => connected;
  @override
  bool get voiceBusy => busy;
  @override
  List<VoiceTarget> get voiceTargets => build(this);
  @override
  String get composerText => composer;
  @override
  void appendDictation(String text) =>
      composer = composer.isEmpty ? text : '$composer $text';
  @override
  bool submitComposer() {
    if (!canSend) return false;
    sends++;
    composer = '';
    return true;
  }

  @override
  List<String> get terminalScreenLines => screen;
  @override
  void clearComposer() => composer = '';
  @override
  void composerBackspace(int count) =>
      composer = backspaceText(composer, count);
  @override
  void composerDeleteWords(int count) =>
      composer = deleteLastWords(composer, count);
}

class FakeTimer implements Timer {
  FakeTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
  void fire() {
    if (!cancelled) callback();
  }
}

void main() {
  late FakeSurface surface;
  late List<FakeTimer> timers;
  late List<String> spoken;
  late VoiceControl control;

  setUp(() {
    surface = FakeSurface();
    timers = [];
    spoken = [];
    control = VoiceControl(
      surface: surface,
      timer: (d, cb) {
        final t = FakeTimer(d, cb);
        timers.add(t);
        return t;
      },
      speak: spoken.add,
    );
  });

  test('a button name runs that button and nothing else', () {
    final reply = control.handle('Page up');
    expect(surface.ran, ['page_up']);
    expect(reply.tone, 'command');
    expect(reply.speak, isNull);
    expect(surface.composer, isEmpty);
    expect(control.statusLine, "heard 'Page up' — Page Up");
  });

  test('the same words inside a sentence are dictation', () {
    final reply = control.handle('scroll the page up a bit');
    expect(surface.ran, isEmpty);
    expect(surface.composer, 'scroll the page up a bit');
    expect(reply.tone, 'dictation');
  });

  test('dictation builds the composer and send submits it once', () {
    control.handle('fix the failing test');
    control.handle('in the parser');
    expect(surface.composer, 'fix the failing test in the parser');
    final reply = control.handle('send');
    expect(surface.sends, 1);
    expect(reply.tone, 'command');
    // Nothing left: a second "submit" does not send again.
    final again = control.handle('submit');
    expect(surface.sends, 1);
    expect(again.speak, 'Nothing to send');
  });

  test('send while the send arrow is disabled says so', () {
    surface.composer = 'x';
    surface.canSend = false;
    final reply = control.handle('send');
    expect(surface.sends, 0);
    expect(reply.tone, 'error');
  });

  test('composer edits touch the Type command box only', () {
    surface.composer = 'git commit -m hello world';
    control.handle('backspace five');
    expect(surface.composer, 'git commit -m hello ');
    control.handle('delete two words');
    expect(surface.composer, 'git commit');
    control.handle('clear');
    expect(surface.composer, isEmpty);
    expect(surface.ran, isEmpty);
  });

  group('confirmation', () {
    test('control C waits for yes, then runs', () {
      final ask = control.handle('control C');
      expect(ask.speak, 'Say yes to confirm');
      expect(surface.ran, isEmpty);
      expect(control.pending?.id, 'ctrl_c');
      final yes = control.handle('yes');
      expect(surface.ran, ['ctrl_c']);
      expect(yes.tone, 'command');
      expect(control.pending, isNull);
      expect(timers.single.cancelled, isTrue);
    });

    test('no cancels', () {
      control.handle('control c');
      final no = control.handle('no');
      expect(no.speak, 'Cancelled');
      expect(surface.ran, isEmpty);
      expect(control.pending, isNull);
    });

    test('ten seconds of silence cancels', () {
      control.handle('exit');
      expect(control.pending?.id, '/exit');
      expect(timers.single.duration, const Duration(seconds: 10));
      timers.single.fire();
      expect(control.pending, isNull);
      expect(spoken, ['Cancelled']);
      // A late "yes" is just a word now.
      control.handle('yes');
      expect(surface.ran, isEmpty);
      expect(surface.composer, 'yes');
    });

    test('another command cancels the question and runs as itself', () {
      control.handle('/exit');
      control.handle('page up');
      expect(control.pending, isNull);
      expect(surface.ran, ['page_up']);
    });

    test('everything else runs at once, like a tap', () {
      control.handle('page up');
      expect(surface.ran, ['page_up']);
      expect(timers, isEmpty);
    });
  });

  test('not connected: nothing runs, nothing is queued', () {
    surface.connected = false;
    final reply = control.handle('page up');
    expect(reply.speak, 'Not connected');
    final dictated = control.handle('some words');
    expect(dictated.speak, 'Not connected');
    expect(surface.ran, isEmpty);
    expect(surface.composer, isEmpty);
    surface.connected = true;
    control.handle('send');
    expect(surface.sends, 0);
  });

  test('a disabled bar button does not run', () {
    final reply = control.handle('run deploy');
    expect(surface.ran, isEmpty);
    expect(reply.tone, 'error');
  });

  test('a running macro locks voice like it locks the buttons', () {
    surface.busy = true;
    final reply = control.handle('page up');
    expect(surface.ran, isEmpty);
    expect(reply.speak, 'Macro running');
  });

  test('stop listening stops, even when not connected', () {
    surface.connected = false;
    final reply = control.handle('stop listening');
    expect(reply.stop, isTrue);
    expect(reply.toJson()['stop'], isTrue);
  });

  group('reading aloud', () {
    List<String> fixture(String name) =>
        File('test/fixtures/voice_read/$name').readAsLinesSync();

    test('read screen reads the visible screen in chunks', () {
      surface.screen = fixture('claude_code_reply.txt');
      final reply = control.handle('read screen');
      expect(control.statusLine, 'reading screen…');
      expect(reply.tone, 'command');
      expect(reply.read, isNotEmpty);
      expect(reply.read!.first, startsWith('Yes, it will read Codex too.'));
      expect(reply.read!.join(' '), contains('Waiting for 5 background'));
      expect(reply.toJson()['read'], reply.read);
      expect(surface.ran, isEmpty);
      expect(surface.composer, isEmpty);
    });

    test('read reply reads only the latest answer', () {
      surface.screen = fixture('codex_working.txt');
      final reply = control.handle('Read reply.');
      expect(control.statusLine, 'reading reply…');
      expect(reply.read, [
        "I'll look at how the status bar is drawn on the phone first.",
      ]);
    });

    test('works while not connected or while a macro runs', () {
      surface.screen = fixture('plain_shell.txt');
      surface.connected = false;
      expect(control.handle('read screen').read, isNotEmpty);
      surface.connected = true;
      surface.busy = true;
      expect(control.handle('read reply').read, isNotEmpty);
    });

    test('nothing to read says so', () {
      surface.screen = const ['', '──────', ''];
      final reply = control.handle('read screen');
      expect(reply.read, isNull);
      expect(reply.speak, 'Nothing to read');
      expect(reply.tone, 'error');
      expect(control.statusLine, 'nothing to read');
    });

    test('stop reading stops, and so does any other command', () {
      final stop = control.handle('stop reading');
      expect(stop.stopReading, isTrue);
      expect(stop.toJson()['stopReading'], isTrue);
      expect(control.statusLine, 'stopped reading');
      expect(control.handle('page up').stopReading, isTrue);
      expect(surface.ran, ['page_up']);
      surface.composer = 'x';
      expect(control.handle('send').stopReading, isTrue);
      expect(control.handle('clear').stopReading, isTrue);
      expect(control.handle('control c').stopReading, isTrue);
      expect(control.handle('no').stopReading, isTrue);
      expect(control.handle('stop listening').stopReading, isTrue);
      surface.screen = fixture('plain_shell.txt');
      expect(control.handle('read screen').stopReading, isTrue);
    });

    test('dictation does not stop a reading', () {
      final reply = control.handle('stop reading the config twice');
      expect(reply.stopReading, isFalse);
      expect(reply.toJson().containsKey('stopReading'), isFalse);
      expect(surface.composer, 'stop reading the config twice');
      // "yes" with no question waiting is a word, not a command.
      expect(control.handle('yes').stopReading, isFalse);
    });

    test('the status line follows the phone to the end of the reading', () {
      surface.screen = fixture('plain_shell.txt');
      control.handle('read screen');
      control.readingEnded('finished');
      expect(control.statusLine, 'finished reading');
      control.handle('read reply');
      control.readingEnded('failed');
      expect(control.statusLine, 'could not read aloud');
      // A later outcome is not overwritten by a late end.
      control.handle('read reply');
      control.handle('page up');
      control.readingEnded('stopped');
      expect(control.statusLine, "heard 'page up' — Page Up");
    });
  });

  group('session', () {
    const channel = MethodChannel('devota/voice_control_test');
    late List<MethodCall> calls;
    late VoiceControlSession session;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      session = VoiceControlSession(
        surface: surface,
        channel: channel,
        requestMicrophone: () async => true,
      );
    });

    tearDown(() {
      session.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<Map?> say(String text) async {
      const codec = StandardMethodCodec();
      ByteData? reply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(MethodCall('utterance', {'text': text})),
            (data) => reply = data,
          );
      return codec.decodeEnvelope(reply!) as Map?;
    }

    test('toggle off: no service, and a stray transcript is refused', () async {
      expect(session.enabled, isFalse);
      final reply = await say('page up');
      expect(reply, {'stop': true});
      expect(surface.ran, isEmpty);
      expect(calls, isEmpty, reason: 'no start, no recognizer');
    });

    test('toggle on starts the service; off stops it', () async {
      expect(await session.setEnabled(true), isTrue);
      expect(calls.map((c) => c.method), ['start']);
      expect(session.statusLine, 'Voice: listening');
      final reply = await say('page up');
      expect(reply?['tone'], 'command');
      expect(surface.ran, ['page_up']);
      expect(session.statusLine, "Voice: heard 'page up' — Page Up");
      await session.setEnabled(false);
      expect(calls.map((c) => c.method), contains('stop'));
      expect(await say('page up'), {'stop': true});
      expect(surface.ran, ['page_up']);
    });

    test(
      'a read reply carries the chunks; the end updates the status',
      () async {
        surface.screen = File(
          'test/fixtures/voice_read/codex_reply.txt',
        ).readAsLinesSync();
        await session.setEnabled(true);
        final reply = await say('read reply');
        expect(reply?['tone'], 'command');
        expect(reply?['stopReading'], isTrue);
        expect((reply?['read'] as List).first, startsWith('All three suites'));
        expect(session.statusLine, 'Voice: reading reply…');
        const codec = StandardMethodCodec();
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              codec.encodeMethodCall(
                const MethodCall('reading', {
                  'active': false,
                  'reason': 'finished',
                }),
              ),
              (_) {},
            );
        expect(session.statusLine, 'Voice: finished reading');
        final stop = await say('stop reading');
        expect(stop?['stopReading'], isTrue);
        expect(session.statusLine, 'Voice: stopped reading');
      },
    );

    test('"stop listening" turns the toggle off', () async {
      await session.setEnabled(true);
      final reply = await say('stop listening');
      expect(reply?['stop'], isTrue);
      expect(session.enabled, isFalse);
      expect(session.statusLine, 'Voice: stopped by voice');
    });

    test('microphone refused: no start', () async {
      final denied = VoiceControlSession(
        surface: surface,
        channel: const MethodChannel('devota/voice_control_denied'),
        requestMicrophone: () async => false,
      );
      expect(await denied.setEnabled(true), isFalse);
      expect(denied.enabled, isFalse);
      expect(calls, isEmpty);
      denied.dispose();
    });
  });
}
