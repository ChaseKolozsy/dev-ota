import 'dart:async';

import 'package:devota/terminal_macro.dart';
import 'package:devota/voice/voice_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTerminal implements VoiceTerminal {
  @override
  List<VoiceWindow> windows = const [
    VoiceWindow('%1', 'main:1.0'),
    VoiceWindow('%2', 'main:2.0'),
  ];
  @override
  List<TerminalMacro> macros = [
    const TerminalMacro(id: 'a', name: 'Run tests', steps: []),
    const TerminalMacro(
      id: 'b',
      name: 'Phone check',
      steps: [
        TerminalMacroStep(
          id: 's',
          type: TerminalMacroStepType.device,
          value: '{}',
          delaySeconds: 0,
        ),
      ],
    ),
    const TerminalMacro(id: 'c', name: 'Cebuano middle', steps: []),
  ];
  final calls = <String>[];
  String? failure;
  Completer<String?>? gate;

  Future<String?> _record(String call) async {
    calls.add(call);
    if (gate != null) return gate!.future;
    return failure;
  }

  @override
  Future<String?> submitText(String paneId, String text) =>
      _record('submit $paneId $text');
  @override
  Future<String?> sendBytes(String paneId, String bytes) =>
      _record('bytes $paneId ${bytes.codeUnits}');
  @override
  Future<String?> backspace(String paneId, int count) =>
      _record('backspace $paneId $count');
  @override
  Future<String?> scroll(String paneId, int lines, {required bool up}) =>
      _record('scroll $paneId ${up ? 'up' : 'down'} $lines');
  @override
  Future<String?> scrollBottom(String paneId) => _record('bottom $paneId');
  @override
  Future<String?> runMacro(String paneId, TerminalMacro macro) =>
      _record('macro $paneId ${macro.name}');
}

class FakeHost implements VoiceHost {
  final spoken = <String>[];
  final events = <String>[];
  @override
  bool appVisible = true;
  @override
  void speak(String text) => spoken.add(text);
  @override
  void openKeyboard() => events.add('open keyboard');
  @override
  void closeKeyboard() => events.add('close keyboard');
  @override
  void stopListening() => events.add('stop listening');
}

class FakeTimer implements Timer {
  FakeTimer(this.callback);
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  void fire() {
    if (!cancelled) callback();
  }

  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

void main() {
  late FakeTerminal terminal;
  late FakeHost host;
  late VoiceController voice;
  late List<FakeTimer> timers;

  setUp(() {
    terminal = FakeTerminal();
    host = FakeHost();
    timers = [];
    voice = VoiceController(
      terminal: terminal,
      host: host,
      timer: (duration, callback) {
        final t = FakeTimer(callback);
        timers.add(t);
        return t;
      },
    );
    addTearDown(voice.dispose);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  group('dictation and the draft', () {
    test('anything that is not a whole command is appended to the draft', () {
      final r1 = voice.handle('please submit the form');
      final r2 = voice.handle('and then run the tests');
      expect(r1.tone, VoiceTone.dictation);
      expect(r2.tone, VoiceTone.dictation);
      expect(voice.draft, 'please submit the form and then run the tests');
      expect(terminal.calls, isEmpty, reason: 'dictation never sends');
      expect(r1.speech, isNull, reason: 'no automatic read-back');
    });

    test('drafts are per window; "window N" switches the target', () {
      voice.handle('first window text');
      final r = voice.handle('window two');
      expect(r.tone, VoiceTone.command);
      expect(r.speech, 'Window 2.');
      voice.handle('second window text');
      expect(voice.draftFor('%1'), 'first window text');
      expect(voice.draftFor('%2'), 'second window text');
      expect(voice.handle('window 3').tone, VoiceTone.error);
      expect(voice.targetNumber, 2);
    });

    test(
      'submit sends the draft plus Enter to the target, then clears it',
      () async {
        voice.handle('fix the failing test');
        final r = voice.handle('submit');
        expect(r.tone, VoiceTone.command);
        expect(r.speech, isNull);
        await flush();
        expect(terminal.calls, ['submit %1 fix the failing test']);
        expect(voice.draft, isEmpty);
      },
    );

    test('a failed submit keeps the draft and says why', () async {
      terminal.failure = 'window still changing';
      voice.handle('fix the failing test');
      voice.handle('submit');
      await flush();
      expect(voice.draft, 'fix the failing test');
      expect(host.spoken.single, contains('Not sent: window still changing'));
    });

    test('dictation during a submit in flight survives the send', () async {
      terminal.gate = Completer<String?>();
      voice.handle('first part');
      voice.handle('submit');
      voice.handle('second part');
      expect(voice.handle('submit').speech, 'Still sending.');
      terminal.gate!.complete(null);
      await flush();
      expect(voice.draft, 'second part');
      expect(terminal.calls, ['submit %1 first part']);
    });

    test('submit with an empty draft presses Enter', () async {
      voice.handle('submit');
      await flush();
      expect(terminal.calls, ['bytes %1 [13]']);
    });

    test('enter with a draft warns once, then sends Enter only', () async {
      voice.handle('some text');
      final warn = voice.handle('enter');
      expect(warn.speech, contains('Say submit'));
      expect(terminal.calls, isEmpty);
      voice.handle('enter');
      await flush();
      expect(terminal.calls, ['bytes %1 [13]']);
      expect(voice.draft, 'some text');
    });

    test('read it back speaks the draft only on request', () {
      expect(voice.handle('read it back').speech, 'The draft is empty.');
      voice.handle('hello there');
      expect(voice.handle('read it back').speech, 'hello there');
    });

    test('backspace edits a non-empty draft instead of the pane', () async {
      voice.handle('hello there');
      voice.handle('backspace six');
      expect(voice.draft, 'hello');
      voice.handle('backspace twenty');
      expect(voice.draft, isEmpty);
      await flush();
      expect(terminal.calls, isEmpty);
    });

    test(
      'backspace with no draft goes to the pane; over 30 asks first',
      () async {
        voice.handle('backspace twenty');
        await flush();
        expect(terminal.calls, ['backspace %1 20']);
        final r = voice.handle('backspace forty');
        expect(r.speech, 'Backspace 40 in window 1? Say yes to confirm.');
        await flush();
        expect(terminal.calls.length, 1);
        voice.handle('yes');
        await flush();
        expect(terminal.calls.last, 'backspace %1 40');
      },
    );
  });

  group('confirmations', () {
    test('exit asks, and yes sends /exit', () async {
      final r = voice.handle('exit');
      expect(r.speech, 'Exit Claude in window 1? Say yes to confirm.');
      expect(voice.confirming, isTrue);
      await flush();
      expect(terminal.calls, isEmpty);
      voice.handle('yes');
      await flush();
      expect(terminal.calls, ['submit %1 /exit']);
      expect(voice.confirming, isFalse);
    });

    test('no cancels; nothing is sent', () async {
      voice.handle('control C');
      final r = voice.handle('no');
      expect(r.speech, 'Cancelled');
      await flush();
      expect(terminal.calls, isEmpty);
    });

    test('the confirmation times out', () async {
      voice.handle('slash exit');
      expect(timers.single.isActive, isTrue);
      timers.single.fire();
      expect(voice.confirming, isFalse);
      expect(host.spoken, ['Cancelled.']);
      voice.handle('yes');
      await flush();
      expect(terminal.calls, isEmpty, reason: 'a late yes is dictation');
      expect(voice.draft, 'yes');
    });

    test('any other utterance cancels and is handled normally', () async {
      voice.handle('clear draft');
      expect(voice.confirming, isFalse, reason: 'empty draft: nothing to ask');
      voice.handle('keep this');
      voice.handle('clear draft');
      expect(voice.confirming, isTrue);
      final r = voice.handle('and this too');
      expect(r.tone, VoiceTone.dictation);
      expect(r.speech, 'Cancelled.');
      expect(voice.draft, 'keep this and this too');
      expect(timers.last.cancelled, isTrue);
    });

    test('clear draft clears after yes', () async {
      voice.handle('some words');
      voice.handle('clear draft');
      voice.handle('yeah');
      await flush();
      expect(voice.draft, isEmpty);
    });

    test(
      'control C and unknown slash commands confirm; known ones do not',
      () async {
        voice.handle('control C');
        voice.handle('yes');
        await flush();
        expect(terminal.calls, ['bytes %1 [3]']);
        voice.handle('slash plan');
        await flush();
        expect(terminal.calls.last, 'submit %1 /plan');
        expect(
          voice.handle('slash deploy staging').speech,
          'Slash deploy staging in window 1? Say yes to confirm.',
        );
        voice.handle('yes');
        await flush();
        expect(terminal.calls.last, 'submit %1 /deploy-staging');
      },
    );

    test('a window unbound during the confirmation is never sent to', () async {
      voice.handle('window 2');
      voice.handle('exit');
      terminal.windows = const [VoiceWindow('%1', 'main:1.0')];
      voice.handle('yes');
      await flush();
      expect(terminal.calls, isEmpty);
      expect(host.spoken.last, 'Not sent: window changed.');
    });
  });

  group('keys, macros, scrolling and the app', () {
    test('keys go straight to the target window', () async {
      for (final said in [
        'escape',
        'tab',
        'page up',
        'control end',
        'scroll up',
        'scroll down 5',
        'scroll to bottom',
      ]) {
        expect(voice.handle(said).tone, VoiceTone.command, reason: said);
      }
      await flush();
      expect(terminal.calls, [
        'bytes %1 [27]',
        'bytes %1 [9]',
        'bytes %1 [27, 91, 53, 126]',
        'bytes %1 [27, 91, 49, 59, 53, 70]',
        'scroll %1 up 15',
        'scroll %1 down 5',
        'bottom %1',
      ]);
    });

    test('a failed key is spoken after the tone', () async {
      terminal.failure = 'SSH disconnected';
      voice.handle('escape');
      await flush();
      expect(host.spoken, ['Not sent: SSH disconnected.']);
    });

    test(
      'macro N asks first and names the macro; device macros refuse',
      () async {
        final r = voice.handle('macro three');
        expect(
          r.speech,
          'Macro 3, Cebuano middle in window 1? Say yes to confirm.',
        );
        voice.handle('yes');
        await flush();
        expect(terminal.calls, ['macro %1 Cebuano middle']);
        expect(voice.handle('macro two').tone, VoiceTone.error);
        expect(voice.handle('macro nine').tone, VoiceTone.error);
      },
    );

    test(
      'macro by name runs without a confirm; unknown names are dictation',
      () async {
        expect(voice.handle('macro run tests').tone, VoiceTone.command);
        await flush();
        expect(terminal.calls, ['macro %1 Run tests']);
        final r = voice.handle('macro economics is hard');
        expect(r.tone, VoiceTone.dictation);
        expect(voice.draft, 'macro economics is hard');
      },
    );

    test('stop listening and the keyboard go to the host', () {
      voice.handle('open keyboard');
      voice.handle('close keyboard');
      voice.handle('stop listening');
      expect(host.events, [
        'open keyboard',
        'close keyboard',
        'stop listening',
      ]);
      host.appVisible = false;
      expect(voice.handle('open keyboard').speech, "DevOTA isn't open.");
    });

    test('no bound window: dictation is refused with an error tone', () {
      terminal.windows = const [];
      final r = voice.handle('hello');
      expect(r.tone, VoiceTone.error);
      expect(voice.draft, isEmpty);
      expect(voice.handle('submit').tone, VoiceTone.error);
    });
  });
}
