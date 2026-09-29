import 'dart:async';

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
