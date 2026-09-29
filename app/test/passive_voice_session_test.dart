import 'package:devota/terminal_macro.dart';
import 'package:devota/voice/passive_voice_session.dart';
import 'package:devota/voice/voice_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingTerminal implements VoiceTerminal {
  final calls = <String>[];
  @override
  List<VoiceWindow> windows = const [VoiceWindow('%1', 'main:1.0')];
  @override
  List<TerminalMacro> get macros => const [];
  Future<String?> _r(String c) async {
    calls.add(c);
    return null;
  }

  @override
  Future<String?> submitText(String paneId, String text) => _r('submit $text');
  @override
  Future<String?> sendBytes(String paneId, String bytes) =>
      _r('bytes ${bytes.codeUnits}');
  @override
  Future<String?> backspace(String paneId, int count) => _r('backspace');
  @override
  Future<String?> scroll(String paneId, int lines, {required bool up}) =>
      _r('scroll');
  @override
  Future<String?> scrollBottom(String paneId) => _r('bottom');
  @override
  Future<String?> runMacro(String paneId, TerminalMacro macro) => _r('macro');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/passive_voice');
  const codec = StandardMethodCodec();
  late List<MethodCall> native;
  late RecordingTerminal terminal;
  late PassiveVoiceSession session;
  String? startRefusal;
  var micGranted = true;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    native = [];
    startRefusal = null;
    micGranted = true;
    terminal = RecordingTerminal();
    messenger.setMockMethodCallHandler(channel, (call) async {
      native.add(call);
      if (call.method == 'start' && startRefusal != null) {
        throw PlatformException(code: 'refused', message: startRefusal);
      }
      if (call.method == 'consumeStartRequest') return false;
      return true;
    });
    session = PassiveVoiceSession(
      terminal: terminal,
      channel: channel,
      requestMicrophone: () async => micGranted,
      canStart: () => terminal.windows.isEmpty ? 'Bind a window first' : null,
      isAppVisible: () => true,
    );
  });

  tearDown(() {
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// Sends a call from the "native" side and decodes Dart's reply.
  Future<Object?> fromNative(String method, [Object? args]) async {
    Object? reply;
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      (data) {
        reply = data == null ? null : codec.decodeEnvelope(data);
      },
    );
    return reply;
  }

  List<String> methods() => native.map((c) => c.method).toList();

  group('switch off means no recognizer and no service', () {
    test('a session that is never switched on never starts anything', () async {
      await session.init();
      expect(methods(), ['consumeStartRequest']);
      expect(session.enabled, isFalse);
      // A transcript that still arrives (a stale service) is not
      // interpreted and the service is told to stop.
      final reply = await fromNative('utterance', {'text': 'submit'});
      expect(reply, {'stop': true});
      await fromNative('utterance', {'text': 'exit'});
      await fromNative('utterance', {'text': 'hello world'});
      expect(terminal.calls, isEmpty);
      expect(session.controller.draft, isEmpty);
      expect(methods().where((m) => m == 'start'), isEmpty);
    });

    test(
      'switching off stops the service; later transcripts are refused',
      () async {
        expect(await session.setEnabled(true), isTrue);
        expect(methods().last, 'start');
        expect(native.last.arguments['quietBeeps'], isTrue);
        final on = await fromNative('utterance', {'text': 'fix the tests'});
        expect(on, {'tone': 'dictation', 'speak': null});
        await session.setEnabled(false);
        expect(methods().last, 'stop');
        final off = await fromNative('utterance', {'text': 'submit'});
        expect(off, {'stop': true});
        await Future<void>.delayed(Duration.zero);
        expect(terminal.calls, isEmpty);
        expect(methods().where((m) => m == 'start').length, 1);
      },
    );

    test('a refused start leaves the switch off', () async {
      startRefusal = 'Open DevOTA to start listening';
      expect(await session.setEnabled(true), isFalse);
      expect(session.enabled, isFalse);
      expect(session.message, 'Open DevOTA to start listening');
      expect(await fromNative('utterance', {'text': 'hi'}), {'stop': true});
    });

    test(
      'no microphone permission or no bound window: nothing starts',
      () async {
        micGranted = false;
        expect(await session.setEnabled(true), isFalse);
        terminal.windows = const [];
        micGranted = true;
        expect(await session.setEnabled(true), isFalse);
        expect(session.message, 'Bind a window first');
        expect(methods().where((m) => m == 'start'), isEmpty);
      },
    );

    test(
      '"stop listening" turns the switch off and stops the service',
      () async {
        await session.setEnabled(true);
        final reply = await fromNative('utterance', {'text': 'stop listening'});
        expect(reply, {'tone': 'command', 'speak': null});
        await Future<void>.delayed(Duration.zero);
        expect(session.enabled, isFalse);
        expect(methods().last, 'stop');
      },
    );

    test('the service stopping on its own turns the switch off', () async {
      await session.setEnabled(true);
      await fromNative('stopped', {'reason': 'DevOTA was closed'});
      expect(session.enabled, isFalse);
      expect(session.message, 'DevOTA was closed');
      expect(await fromNative('utterance', {'text': 'hi'}), {'stop': true});
    });

    test('dispose while on stops the service', () async {
      await session.setEnabled(true);
      session.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(methods().last, 'stop');
      session = PassiveVoiceSession(terminal: terminal, channel: channel);
    });
  });

  test('a notification start request switches listening on', () async {
    expect(await fromNative('startRequested'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(session.enabled, isTrue);
    expect(methods(), contains('start'));
  });

  test(
    'submit over the channel sends the draft and publishes status',
    () async {
      await session.setEnabled(true);
      await fromNative('utterance', {'text': 'run the tests'});
      expect(native.last.method, 'update');
      expect(native.last.arguments['status'], contains('draft 3 words'));
      await fromNative('utterance', {'text': 'submit'});
      await Future<void>.delayed(Duration.zero);
      expect(terminal.calls, ['submit run the tests']);
    },
  );
}
