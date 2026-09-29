import 'dart:async';
import 'dart:typed_data';

import 'package:devota/car/car_buttons.dart';
import 'package:devota/car/car_controller.dart';
import 'package:devota/car/car_grammar.dart';
import 'package:devota/car/car_settings.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePlatform implements CarPlatform {
  final spoken = <String>[];
  final calls = <String>[];
  final heard = <CarListenResult>[];
  Completer<CarListenResult>? _pendingListen;
  bool dictationOk = true;
  int recordedMs = 5000;
  String? onDevice = 'phone words';
  bool hasRecording = false;

  @override
  Future<bool> speak(String text, {bool interrupt = true}) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<void> stopSpeaking() async => calls.add('stopSpeaking');

  @override
  Future<void> earcon(String kind) async => calls.add('earcon:$kind');

  @override
  Future<CarStartResult> startDictation(String label, {int maxSeconds = 180}) async {
    calls.add('startDictation:$label');
    hasRecording = dictationOk;
    return CarStartResult(dictationOk, call: true, error: dictationOk ? null : 'no mic');
  }

  @override
  Future<int> stopDictation(String reason) async {
    calls.add('stopDictation:$reason');
    return recordedMs;
  }

  @override
  Future<Uint8List?> takeRecording() async =>
      hasRecording ? Uint8List.fromList([1, 2, 3]) : null;

  @override
  Future<void> discardRecording() async {
    calls.add('discard');
    hasRecording = false;
  }

  @override
  Future<String?> recognizeRecording() async {
    calls.add('recognizeRecording');
    return onDevice;
  }

  @override
  Future<CarStartResult> startCommandSession(String label) async {
    calls.add('startCommandSession');
    return const CarStartResult(true, call: true);
  }

  @override
  Future<void> endCommandSession() async => calls.add('endCommandSession');

  @override
  Future<CarListenResult> listenCommand(List<String> biasing, {int timeoutMs = 10000}) {
    calls.add('listen');
    if (heard.isNotEmpty) return Future.value(heard.removeAt(0));
    _pendingListen = Completer<CarListenResult>();
    return _pendingListen!.future;
  }

  @override
  Future<void> cancelListening() async {
    calls.add('cancelListening');
    final pending = _pendingListen;
    _pendingListen = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(const CarListenResult(error: 'cancelled'));
    }
  }

  /// Delivers an utterance to a listen that is already waiting.
  void say(String text) {
    final pending = _pendingListen;
    _pendingListen = null;
    if (pending != null) {
      pending.complete(CarListenResult(text: text));
    } else {
      heard.add(CarListenResult(text: text));
    }
  }

  @override
  Future<void> claimButtons() async => calls.add('claimButtons');
}

class FakeTarget implements CarTarget {
  List<CarPane> paneList = [const CarPane('%1', 'Settled · no content changes')];
  List<TerminalMacro> macroList = [];
  final sent = <String>[];
  String? failure;
  String? home = 'hello from the car';
  bool visible = true;
  String? deleted;

  CarSendResult _r(String what) {
    sent.add(what);
    return failure == null ? CarSendResult.ok(deleted) : CarSendResult.failed(failure!);
  }

  @override
  List<CarPane> panes() => paneList;
  @override
  List<TerminalMacro> macros() => macroList;
  @override
  Future<CarSendResult> sendKeys(String paneId, String bytes) async =>
      _r('keys:$paneId:${bytes.codeUnits.join(',')}');
  @override
  Future<CarSendResult> submitText(String paneId, String text) async =>
      _r('submit:$paneId:$text');
  @override
  Future<CarSendResult> backspace(String paneId, int count) async =>
      _r('backspace:$paneId:$count');
  @override
  Future<CarSendResult> runMacro(String paneId, TerminalMacro macro) async =>
      _r('macro:$paneId:${macro.name}');
  @override
  Future<CarSendResult> scroll(String paneId, int lines, {required bool up}) async =>
      _r('scroll:$paneId:${up ? 'up' : 'down'}:$lines');
  @override
  Future<CarSendResult> scrollBottom(String paneId) async => _r('bottom:$paneId');
  @override
  Future<String?> readConclusion(String paneId) async => 'The build passed. All done.';
  @override
  Future<String?> transcribeHome(Uint8List wav) async {
    sent.add('home:${wav.length}');
    return home;
  }

  @override
  Future<String?> transcribeOpenAi(Uint8List wav) async => 'openai words';
  @override
  Future<bool> ui(CarUiCommand command) async {
    sent.add('ui:${command.name}');
    return visible;
  }

  @override
  Future<void> reconnect() async => sent.add('reconnect');
  @override
  Future<void> restartZeroTier() async => sent.add('zerotier');
}

TerminalMacroStep shell(String value) => TerminalMacroStep(
  id: value,
  type: TerminalMacroStepType.shell,
  value: value,
  delaySeconds: 0,
);

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakePlatform platform;
  late FakeTarget target;
  late CarController car;
  var time = DateTime(2026, 9, 28, 12);
  var carOff = 0;

  CarController make([CarSettings settings = const CarSettings(enabled: true)]) {
    final c = CarController(
      platform: platform,
      target: target,
      settings: settings,
      now: () => time,
      onCarModeOff: () => carOff++,
      confirmTimeout: const Duration(milliseconds: 80),
      silenceLimit: const Duration(milliseconds: 1),
      autoSendDelay: const Duration(milliseconds: 60),
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() async {
    platform = FakePlatform();
    target = FakeTarget();
    time = DateTime(2026, 9, 28, 12);
    carOff = 0;
    car = make();
    await car.start();
  });

  test('start announces car mode', () {
    expect(platform.spoken, ['DevOTA car mode on.']);
    expect(car.mode, CarMode.idle);
  });

  group('spoken menu', () {
    test('next and previous move focus, speak the label and wrap', () async {
      await car.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Listen, window 1');
      await car.handleSignal(CarSignal.previous);
      expect(platform.spoken.last, 'Dictate to window 1');
      await car.handleSignal(CarSignal.previous);
      expect(platform.spoken.last, 'Car mode off');
      // Any button stops current speech first (§6).
      expect(platform.calls, contains('stopSpeaking'));
    });

    test('the first press after a pause repeats the item instead of moving', () async {
      await car.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Listen, window 1');
      time = time.add(const Duration(seconds: 30));
      await car.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Listen, window 1');
      await car.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Status');
    });

    test('items that need a disabled feature are absent', () async {
      final c = make(const CarSettings(enabled: true, dictationEnabled: false, commandsEnabled: false));
      await c.start();
      final labels = c.menuItems().map((i) => i.label).toList();
      expect(labels.any((l) => l.startsWith('Dictate')), isFalse);
      expect(labels, isNot(contains('Commands')));
    });

    test('activate runs the focused item: status', () async {
      target.paneList = [
        const CarPane('%1', '✓ Reported success · Tests pass'),
        const CarPane('%2', 'Working · output changing'),
      ];
      await car.handleSignal(CarSignal.next);
      await car.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Status');
      await car.handleSignal(CarSignal.playPause);
      expect(
        platform.spoken.last,
        'Window 1: Reported success, Tests pass. Window 2: Working, output changing',
      );
    });

    test('macros submenu confirms before running', () async {
      target.macroList = [
        TerminalMacro(id: 'a', name: 'Cebuano middle', steps: [shell('go')]),
      ];
      // Dictate, Listen, Status, Macros
      for (var i = 0; i < 3; i++) {
        await car.handleSignal(CarSignal.next);
      }
      expect(platform.spoken.last, 'Macros');
      await car.handleSignal(CarSignal.playPause);
      expect(platform.spoken.last, 'Macros. Macro 1, Cebuano middle');
      unawaited(car.handleSignal(CarSignal.playPause));
      await settle();
      expect(car.mode, CarMode.confirming);
      expect(platform.spoken.last, 'Run Macro Cebuano middle in window 1? Press play to confirm.');
      await car.handleSignal(CarSignal.playPause);
      await settle();
      expect(target.sent, ['macro:%1:Cebuano middle']);
    });

    test('car mode off item calls back', () async {
      await car.handleSignal(CarSignal.previous);
      await car.handleSignal(CarSignal.playPause);
      expect(carOff, 1);
    });
  });

  group('dictation (§7)', () {
    test('call starts, hang-up stops, text is staged and only sent on play', () async {
      await car.handleSignal(CarSignal.voice);
      expect(car.mode, CarMode.dictating);
      expect(platform.spoken.last, 'Recording, window 1.');
      expect(platform.calls, contains('startDictation:window 1'));
      await car.handleSignal(CarSignal.hangUp);
      expect(platform.calls, contains('stopDictation:button'));
      expect(target.sent, ['home:3']);
      expect(car.mode, CarMode.staged);
      expect(car.stagedText, 'hello from the car');
      expect(platform.spoken.last, 'Staged: hello from the car. Play to send.');
      // Hang-up never sends: nothing reached the pane yet.
      expect(target.sent.where((s) => s.startsWith('submit')), isEmpty);
      await car.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Staged: hello from the car. Play to send.');
      await car.handleSignal(CarSignal.playPause);
      expect(target.sent.last, 'submit:%1:hello from the car');
      expect(platform.spoken.last, 'Sent to window 1.');
      expect(car.mode, CarMode.idle);
      expect(car.stagedText, isNull);
    });

    test('home Whisper unavailable falls back to the phone recognizer', () async {
      target.home = null;
      await car.handleSignal(CarSignal.voice);
      await car.handleSignal(CarSignal.hangUp);
      expect(platform.spoken, contains('Using phone recognizer.'));
      expect(platform.calls, contains('recognizeRecording'));
      expect(car.stagedText, 'phone words');
    });

    test('a silence hallucination is dropped', () async {
      target.home = 'Thank you.';
      platform.recordedMs = 800;
      await car.handleSignal(CarSignal.voice);
      await car.handleSignal(CarSignal.hangUp);
      expect(platform.spoken.last, 'Heard nothing.');
      expect(car.mode, CarMode.idle);
      expect(car.stagedText, isNull);
    });

    test('a failed submit keeps the text staged', () async {
      await car.handleSignal(CarSignal.voice);
      await car.handleSignal(CarSignal.hangUp);
      target.failure = 'window changed';
      await car.handleSignal(CarSignal.playPause);
      expect(platform.spoken.last, 'Not sent: window changed. Say submit to try again.');
      expect(car.mode, CarMode.staged);
      expect(car.stagedText, 'hello from the car');
    });

    test('failed transcription keeps the audio for a retry', () async {
      target.home = null;
      platform.onDevice = null;
      await car.handleSignal(CarSignal.voice);
      await car.handleSignal(CarSignal.hangUp);
      expect(platform.spoken.last, "Couldn't transcribe. Play to try again, call to redo.");
      expect(car.mode, CarMode.staged);
      target.home = 'second try';
      await car.handleSignal(CarSignal.playPause);
      expect(car.stagedText, 'second try');
    });

    test('dictation off is announced and nothing records', () async {
      final c = make(const CarSettings(enabled: true, dictationEnabled: false));
      await c.start();
      await c.handleSignal(CarSignal.voice);
      expect(platform.spoken.last, 'Dictation is off.');
      expect(platform.calls.where((c) => c.startsWith('startDictation')), isEmpty);
    });

    test('long press cancels a recording', () async {
      await car.handleSignal(CarSignal.voice);
      await car.handleSignal(CarSignal.playPauseLong);
      expect(platform.spoken.last, 'Recording discarded.');
      expect(car.mode, CarMode.idle);
    });

    test('auto-send countdown is cancelled by any button', () async {
      final c = make(const CarSettings(enabled: true, dictationSend: CarDictationSend.autoSendCountdown));
      await c.start();
      await c.handleSignal(CarSignal.voice);
      await c.handleSignal(CarSignal.hangUp);
      expect(platform.spoken.last, 'Staged: hello from the car. Sending in 3.');
      await c.handleSignal(CarSignal.next);
      expect(platform.spoken.last, 'Not sent. Play to send.');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(target.sent.where((s) => s.startsWith('submit')), isEmpty);
    });

    test('auto-send sends after the countdown', () async {
      final c = make(const CarSettings(enabled: true, dictationSend: CarDictationSend.autoSendCountdown));
      await c.start();
      await c.handleSignal(CarSignal.voice);
      await c.handleSignal(CarSignal.hangUp);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();
      expect(target.sent.last, 'submit:%1:hello from the car');
    });

    test('the spoken "command" prefix runs a command instead of staging', () async {
      target.home = 'Command, escape.';
      await car.handleSignal(CarSignal.voice);
      unawaited(car.handleSignal(CarSignal.hangUp));
      await settle();
      expect(target.sent.last, 'keys:%1:27');
      expect(car.mode, CarMode.command);
      expect(car.stagedText, isNull);
      platform.say('done');
      await settle();
      expect(car.mode, CarMode.idle);
    });

    test('with commands off the prefix is just dictation', () async {
      final c = make(const CarSettings(enabled: true, commandsEnabled: false));
      await c.start();
      target.home = 'command escape';
      await c.handleSignal(CarSignal.voice);
      await c.handleSignal(CarSignal.hangUp);
      expect(c.stagedText, 'command escape');
      expect(target.sent.where((s) => s.startsWith('keys')), isEmpty);
    });
  });

  group('command mode (§8)', () {
    Future<void> enter() async {
      unawaited(car.handleSignal(CarSignal.playPauseDouble));
      await settle();
      expect(car.mode, CarMode.command);
    }

    test('keys run, exit is confirmed, done leaves', () async {
      await enter();
      expect(platform.calls, contains('startCommandSession'));
      expect(platform.spoken.last, 'Commands, window 1.');
      platform.say('tab');
      await settle();
      expect(target.sent.last, 'keys:%1:9');
      platform.say('exit');
      await settle();
      expect(car.mode, CarMode.confirming);
      expect(platform.spoken.last, 'Exit Claude in window 1? Press play to confirm.');
      expect(target.sent.where((s) => s.contains('/exit')), isEmpty);
      await car.handleSignal(CarSignal.playPause);
      await settle();
      expect(target.sent.last, 'submit:%1:/exit');
      expect(car.mode, CarMode.command);
      platform.say('done');
      await settle();
      expect(car.mode, CarMode.idle);
      expect(platform.spoken.last, 'Commands off.');
      expect(platform.calls, contains('endCommandSession'));
    });

    test('saying yes confirms; a timeout cancels', () async {
      await enter();
      platform.say('control c');
      await settle();
      expect(car.mode, CarMode.confirming);
      platform.say('yes');
      await settle();
      expect(target.sent.last, 'keys:%1:3');
      platform.say('slash compact');
      await settle();
      expect(car.mode, CarMode.confirming);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();
      expect(platform.spoken, contains('Cancelled.'));
      expect(target.sent.where((s) => s.contains('/compact')), isEmpty);
    });

    test('next or hang-up cancels a pending confirmation', () async {
      await enter();
      platform.say('clear line');
      await settle();
      await car.handleSignal(CarSignal.next);
      await settle();
      expect(platform.spoken, contains('Cancelled.'));
      expect(target.sent.where((s) => s.contains('21')), isEmpty);
    });

    test('unmatched speech does nothing', () async {
      await enter();
      platform.say('please refactor everything');
      await settle();
      expect(platform.spoken.last, carDidntCatch);
      expect(target.sent, isEmpty);
    });

    test('hang-up ends command mode', () async {
      await enter();
      await car.handleSignal(CarSignal.hangUp);
      await settle();
      expect(car.mode, CarMode.idle);
      expect(platform.calls, contains('cancelListening'));
    });

    test('silence ends command mode', () async {
      platform.heard.add(const CarListenResult(error: 'speech_timeout'));
      platform.heard.add(const CarListenResult(error: 'no_match'));
      unawaited(car.handleSignal(CarSignal.playPauseDouble));
      await settle();
      expect(car.mode, CarMode.idle);
      expect(platform.spoken.last, 'Commands off.');
    });

    test('macros by number confirm, by name do not, device macros refused', () async {
      target.macroList = [
        TerminalMacro(id: 'a', name: 'Cebuano middle', steps: [shell('go')]),
        const TerminalMacro(
          id: 'b',
          name: 'Install build',
          steps: [
            TerminalMacroStep(
              id: 'd',
              type: TerminalMacroStepType.device,
              value: '{}',
              delaySeconds: 0,
            ),
          ],
        ),
      ];
      await enter();
      platform.say('macro 1');
      await settle();
      expect(platform.spoken.last, 'Run Macro 1, Cebuano middle in window 1? Press play to confirm.');
      platform.say('yes');
      await settle();
      expect(target.sent.last, 'macro:%1:Cebuano middle');
      platform.say('macro cebuano midle');
      await settle();
      expect(target.sent.length, 2);
      expect(target.sent.last, 'macro:%1:Cebuano middle');
      platform.say('macro 2');
      await settle();
      platform.say('yes');
      await settle();
      expect(platform.spoken.last, 'Device macro. Run it when parked.');
      expect(target.sent.length, 2);
    });

    test('backspace over 30 is confirmed and read back', () async {
      target.deleted = 'the tests';
      await enter();
      platform.say('backspace 12');
      await settle();
      expect(target.sent.last, 'backspace:%1:12');
      expect(platform.spoken.last, 'Deleted 12 characters: the tests.');
      platform.say('backspace 31');
      await settle();
      expect(car.mode, CarMode.confirming);
    });

    test('UI commands need DevOTA in front', () async {
      await enter();
      platform.say('maximize');
      await settle();
      expect(platform.spoken.last, 'Full screen.');
      target.visible = false;
      platform.say('open tools');
      await settle();
      expect(platform.spoken.last, "DevOTA isn't open.");
    });

    test('scroll and more', () async {
      await enter();
      platform.say('scroll up 30 lines');
      await settle();
      platform.say('more');
      await settle();
      platform.say('bottom');
      await settle();
      expect(target.sent, ['scroll:%1:up:30', 'scroll:%1:up:30', 'bottom:%1']);
    });

    test('window N selects the target', () async {
      final saved = <CarSettings>[];
      final c = CarController(
        platform: platform,
        target: target
          ..paneList = [
            const CarPane('%1', 'Settled'),
            const CarPane('%2', 'Settled'),
          ],
        settings: const CarSettings(enabled: true),
        onSettingsChanged: saved.add,
      );
      addTearDown(c.dispose);
      await c.start();
      unawaited(c.enterCommandMode());
      await settle();
      platform.say('window 2');
      await settle();
      platform.say('tab');
      await settle();
      expect(target.sent.last, 'keys:%2:9');
      expect(saved.last.targetPane, '%2');
    });
  });

  group('staged text and enter (§8.4, §8.7)', () {
    test('enter with staged text warns once, backspace edits the buffer', () async {
      await car.handleSignal(CarSignal.voice);
      await car.handleSignal(CarSignal.hangUp);
      unawaited(car.enterCommandMode());
      await settle();
      platform.say('enter');
      await settle();
      expect(platform.spoken.last, startsWith('You have staged text.'));
      expect(target.sent.where((s) => s.startsWith('keys')), isEmpty);
      platform.say('backspace 8');
      await settle();
      expect(platform.spoken.last, 'Deleted 8 characters: the car.');
      expect(car.stagedText, 'hello from');
      platform.say('enter');
      await settle();
      expect(target.sent.last, 'keys:%1:13');
      platform.say('submit');
      await settle();
      expect(target.sent.last, 'submit:%1:hello from');
    });
  });

  group('real calls (§11)', () {
    test('a real call pauses dictation, yields buttons, and keeps the audio', () async {
      await car.handleSignal(CarSignal.voice);
      await car.interrupted('real_call');
      expect(platform.calls, contains('stopDictation:real_call'));
      expect(car.yielded, isTrue);
      final before = target.sent.length;
      await car.handleSignal(CarSignal.playPause);
      await car.handleSignal(CarSignal.hangUp);
      expect(target.sent.length, before);
      await car.resumed();
      expect(platform.spoken.last, contains('Dictation paused'));
      await car.handleSignal(CarSignal.playPause);
      expect(car.stagedText, 'hello from the car');
    });

    test('native reports the call before the interruption: no transcription', () async {
      await car.handleSignal(CarSignal.voice);
      await car.nativeDictationStopped('interrupted');
      expect(car.mode, CarMode.dictating);
      expect(target.sent, isEmpty);
      await car.interrupted('real_call');
      expect(car.mode, CarMode.staged);
      expect(car.yielded, isTrue);
      expect(target.sent, isEmpty);
    });

    test('recording cap transcribes, a recorder error does not', () async {
      await car.handleSignal(CarSignal.voice);
      await car.nativeDictationStopped('cap');
      expect(platform.spoken, contains('Recording limit reached.'));
      expect(car.stagedText, 'hello from the car');
      await car.handleSignal(CarSignal.voice);
      await car.nativeDictationStopped('error');
      expect(platform.spoken.last, 'Recording failed.');
      expect(car.mode, CarMode.idle);
    });

    test('a real call ends command mode', () async {
      unawaited(car.enterCommandMode());
      await settle();
      await car.interrupted('real_call');
      await settle();
      expect(platform.calls, contains('endCommandSession'));
      expect(car.mode, CarMode.idle);
    });
  });

  test('with spoken feedback off only earcons play', () async {
    final c = make(const CarSettings(enabled: true, speechEnabled: false));
    final before = platform.spoken.length;
    await c.start();
    expect(platform.spoken.length, before);
    expect(platform.calls, contains('earcon:tick'));
  });

  test('privacy mode reads status, not terminal text', () async {
    final c = make(const CarSettings(enabled: true, privacyMode: true));
    await c.start();
    unawaited(c.enterCommandMode());
    await settle();
    platform.say('read');
    await settle();
    expect(platform.spoken.last, 'window 1: Settled, no content changes.');
  });

  test('reading speaks the conclusion and stop ends it', () async {
    unawaited(car.enterCommandMode());
    await settle();
    platform.say('read');
    await settle();
    expect(platform.spoken, contains('The build passed. All done.'));
  });

  test('stopped car mode ignores buttons', () async {
    await car.stop();
    final spoken = platform.spoken.length;
    await car.handleSignal(CarSignal.next);
    expect(platform.spoken.length, spoken);
  });

  test('fuzzy macro names need exactly one close match', () {
    final macros = [
      const TerminalMacro(id: 'a', name: 'Cebuano middle', steps: []),
      const TerminalMacro(id: 'b', name: 'Cebuano muddle', steps: []),
      const TerminalMacro(id: 'c', name: 'Deploy', steps: []),
    ];
    expect(carMatchMacro(macros, 'deploy')?.id, 'c');
    expect(carMatchMacro(macros, 'cebuano middle')?.id, 'a');
    expect(carMatchMacro(macros, 'cebuano midle'), isNull);
    expect(carMatchMacro(macros, 'something else'), isNull);
  });
}
