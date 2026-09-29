
import 'package:devota/car/car_buttons.dart';
import 'package:devota/car/car_channel.dart';
import 'package:devota/car/car_controller.dart';
import 'package:devota/car/car_grammar.dart';
import 'package:devota/car/car_session.dart';
import 'package:devota/car/car_settings.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NullTarget implements CarTarget {
  final sent = <String>[];
  @override
  List<CarPane> panes() => const [CarPane('%1', 'Settled')];
  @override
  List<TerminalMacro> macros() => const [];
  @override
  Future<CarSendResult> sendKeys(String paneId, String bytes) async {
    sent.add('keys:$bytes');
    return const CarSendResult.ok();
  }

  @override
  Future<CarSendResult> submitText(String paneId, String text) async =>
      const CarSendResult.ok();
  @override
  Future<CarSendResult> backspace(String paneId, int count) async =>
      const CarSendResult.ok();
  @override
  Future<CarSendResult> runMacro(String paneId, TerminalMacro macro) async =>
      const CarSendResult.ok();
  @override
  Future<CarSendResult> scroll(String paneId, int lines, {required bool up}) async =>
      const CarSendResult.ok();
  @override
  Future<CarSendResult> scrollBottom(String paneId) async => const CarSendResult.ok();
  @override
  Future<String?> readConclusion(String paneId) async => null;
  @override
  Future<String?> transcribeHome(Uint8List wav) async => null;
  @override
  Future<String?> transcribeOpenAi(Uint8List wav) async => null;
  @override
  Future<bool> ui(CarUiCommand command) async => false;
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> restartZeroTier() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('devota/car');
  late List<MethodCall> calls;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'startCarMode':
        case 'probeStart':
          return true;
        case 'speak':
          // Finish speech immediately, as the native side would.
          final id = (call.arguments as Map)['id'];
          Future<void>.delayed(Duration.zero, () {
            messenger.handlePlatformMessage(
              'devota/car',
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('speechDone', {'id': id, 'ok': true}),
              ),
              (_) {},
            );
          });
          return null;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> nativeSends(String method, Map<String, Object?> args) async {
    await messenger.handlePlatformMessage(
      'devota/car',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('with the master switch off, DevOTA makes no car calls at all', () async {
    SharedPreferences.setMockInitialValues({});
    final session = CarSession(target: NullTarget());
    addTearDown(session.dispose);
    await session.init();
    expect(session.settings.enabled, isFalse);
    expect(await session.startCarMode(), isFalse);
    expect(await session.startProbe(), isFalse);
    // Native events are not even listened to.
    await nativeSends('signal', {'button': 'playPause', 'source': 'media_session'});
    expect(calls, isEmpty);
    expect(session.running, isFalse);
  });

  test('turning it on starts car mode; turning it off stops everything', () async {
    SharedPreferences.setMockInitialValues({});
    final target = NullTarget();
    final session = CarSession(target: target);
    addTearDown(session.dispose);
    await session.init();
    await session.update(session.settings.copyWith(enabled: true));
    expect(calls, isEmpty, reason: 'enabling alone registers nothing native');
    expect(await session.startCarMode(), isTrue);
    expect(calls.map((c) => c.method), containsAllInOrder(['setPressTiming', 'startCarMode', 'speak']));
    expect(session.running, isTrue);
    expect(session.controller!.mode, CarMode.idle);

    // A native signal reaches the state machine.
    await nativeSends('signal', {'button': 'next', 'source': 'media_session'});
    expect(
      calls.where((c) => c.method == 'speak').last.arguments['text'],
      'Listen, window 1',
    );

    calls.clear();
    await session.update(session.settings.copyWith(enabled: false));
    expect(calls.map((c) => c.method), containsAll(['stopCarMode', 'setAutoDevice']));
    expect(session.running, isFalse);
    calls.clear();
    await nativeSends('signal', {'button': 'next', 'source': 'media_session'});
    expect(calls, isEmpty);
  });

  test('car mode refuses to start silently (S4)', () async {
    SharedPreferences.setMockInitialValues({
      CarSettings.kEnabled: true,
      CarSettings.kSpeech: false,
    });
    final session = CarSession(target: NullTarget());
    addTearDown(session.dispose);
    await session.init();
    expect(await session.startCarMode(), isFalse);
    expect(calls.where((c) => c.method == 'startCarMode'), isEmpty);
  });

  test('the car device connecting starts car mode without the mic', () async {
    SharedPreferences.setMockInitialValues({
      CarSettings.kEnabled: true,
      CarSettings.kAutoDevice: 'AA:BB',
    });
    final session = CarSession(target: NullTarget());
    addTearDown(session.dispose);
    await session.init();
    expect(calls.single.method, 'setAutoDevice');
    expect(calls.single.arguments['address'], 'AA:BB');
    await nativeSends('carDevice', {'connected': true, 'address': 'OTHER', 'name': 'x'});
    expect(session.running, isFalse);
    await nativeSends('carDevice', {'connected': true, 'address': 'AA:BB', 'name': 'Car'});
    expect(session.running, isTrue);
    final start = calls.firstWhere((c) => c.method == 'startCarMode');
    expect(start.arguments['withMic'], isFalse);
    await nativeSends('carDevice', {'connected': false, 'address': 'AA:BB', 'name': 'Car'});
    expect(session.running, isFalse);
  });

  test('the notification action stopping car mode is honoured', () async {
    SharedPreferences.setMockInitialValues({CarSettings.kEnabled: true});
    final session = CarSession(target: NullTarget());
    addTearDown(session.dispose);
    await session.init();
    await session.startCarMode();
    await nativeSends('carModeStopped', {'reason': 'notification'});
    expect(session.running, isFalse);
  });

  test('wire names map to signals', () {
    for (final s in CarSignal.values) {
      expect(carSignalFromWire(s.name), s);
    }
    expect(carSignalFromWire('bogus'), isNull);
  });
}
