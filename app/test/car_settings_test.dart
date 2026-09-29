import 'package:devota/backup_service.dart';
import 'package:devota/car/car_buttons.dart';
import 'package:devota/car/car_settings.dart';
import 'package:devota/car/car_speech_text.dart';
import 'package:devota/terminal_watch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the master switch defaults to OFF', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await CarSettings.load();
    expect(settings.enabled, isFalse);
    // Recommended defaults for everything else (§4.1).
    expect(settings.dictationEnabled, isTrue);
    expect(settings.commandsEnabled, isTrue);
    expect(settings.speechEnabled, isTrue);
    expect(settings.confirmDestructive, isTrue);
    expect(settings.a11yNavEnabled, isFalse);
    expect(settings.verbosity, CarVerbosity.terse);
    expect(settings.dictationRecognizer, CarDictationRecognizer.homeWhisper);
    expect(settings.commandRecognizer, CarCommandRecognizer.onDevice);
    expect(settings.dictationSend, CarDictationSend.stageReadConfirm);
    expect(settings.readbackMaxWords, 40);
    expect(settings.macroConfirm, CarMacroConfirm.byPositionOnly);
    expect(settings.playPauseDouble, isFalse);
    expect(settings.playPauseLong, isFalse);
    expect(settings.voiceDouble, isFalse);
    expect(
      settings.commandEndOnDone &&
          settings.commandEndOnHangUp &&
          settings.commandEndOnSilence,
      isTrue,
    );
  });

  test('settings round-trip through SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final custom = const CarSettings().copyWith(
      enabled: true,
      autoDevice: 'AA:BB:CC:DD:EE:FF',
      dictationEnabled: false,
      nextPrevMode: CarNextPrevMode.arrowKeys,
      verbosity: CarVerbosity.normal,
      dictationSend: CarDictationSend.stageOnly,
      commandEndOnSilence: false,
      privacyMode: true,
      readbackMaxWords: 80,
      targetPane: '%7',
      macroConfirm: CarMacroConfirm.always,
      playPauseDouble: true,
      doublePressMs: 500,
      buttonMap: CarButtonMap.defaults().withCell(
        CarMode.idle,
        CarSignal.hangUp,
        CarAction.status,
      ),
      slashConfirm: {'compact': false, 'exit': true},
    );
    await custom.save();
    final loaded = await CarSettings.load();
    expect(loaded.enabled, isTrue);
    expect(loaded.autoDevice, 'AA:BB:CC:DD:EE:FF');
    expect(loaded.dictationEnabled, isFalse);
    expect(loaded.nextPrevMode, CarNextPrevMode.arrowKeys);
    expect(loaded.verbosity, CarVerbosity.normal);
    expect(loaded.dictationSend, CarDictationSend.stageOnly);
    expect(loaded.commandEndOnSilence, isFalse);
    expect(loaded.commandEndOnDone, isTrue);
    expect(loaded.privacyMode, isTrue);
    expect(loaded.readbackMaxWords, 80);
    expect(loaded.targetPane, '%7');
    expect(loaded.macroConfirm, CarMacroConfirm.always);
    expect(loaded.playPauseDouble, isTrue);
    expect(loaded.doublePressMs, 500);
    expect(
      loaded.effectiveButtonMap.action(CarMode.idle, CarSignal.hangUp),
      CarAction.status,
    );
    expect(loaded.slashConfirm, {'compact': false, 'exit': true});
  });

  test('every car pref key is carried by Backup', () {
    for (final key in CarSettings.boolKeys) {
      expect(BackupService.boolPreferenceKeys, contains(key));
    }
    for (final key in CarSettings.stringKeys) {
      expect(BackupService.stringPreferenceKeys, contains(key));
    }
  });

  group('button map', () {
    test('defaults follow the proposal table (§5.2)', () {
      final map = CarButtonMap.defaults();
      expect(map.action(CarMode.idle, CarSignal.next), CarAction.focusNext);
      expect(map.action(CarMode.idle, CarSignal.playPause), CarAction.activate);
      expect(map.action(CarMode.idle, CarSignal.voice), CarAction.dictate);
      expect(
        map.action(CarMode.idle, CarSignal.playPauseDouble),
        CarAction.commandMode,
      );
      expect(
        map.action(CarMode.dictating, CarSignal.hangUp),
        CarAction.stopTranscribe,
      );
      expect(
        map.action(CarMode.dictating, CarSignal.playPause),
        CarAction.stopTranscribe,
      );
      expect(map.action(CarMode.staged, CarSignal.playPause), CarAction.submit);
      expect(map.action(CarMode.staged, CarSignal.next), CarAction.readAgain);
      expect(map.action(CarMode.staged, CarSignal.voice), CarAction.redictate);
      expect(
        map.action(CarMode.command, CarSignal.hangUp),
        CarAction.endCommand,
      );
      expect(
        map.action(CarMode.confirming, CarSignal.playPause),
        CarAction.confirm,
      );
      expect(map.action(CarMode.confirming, CarSignal.next), CarAction.cancel);
      expect(
        map.action(CarMode.confirming, CarSignal.hangUp),
        CarAction.cancel,
      );
      expect(map.action(CarMode.reading, CarSignal.previous), CarAction.earlier);
      // Transcribing ignores every button.
      for (final s in CarSignal.values) {
        expect(map.action(CarMode.transcribing, s), CarAction.nothing);
      }
    });

    test('next/previous function rewrites only the idle column', () {
      final scroll = CarButtonMap.defaults(CarNextPrevMode.scrollPane);
      expect(scroll.action(CarMode.idle, CarSignal.next), CarAction.scrollDown);
      expect(scroll.action(CarMode.idle, CarSignal.previous), CarAction.scrollUp);
      expect(scroll.action(CarMode.staged, CarSignal.next), CarAction.readAgain);
      final arrows = CarButtonMap.defaults(CarNextPrevMode.arrowKeys);
      expect(arrows.action(CarMode.idle, CarSignal.next), CarAction.arrowDown);
    });

    test('encode/decode keeps edits and ignores junk', () {
      final edited = CarButtonMap.defaults().withCell(
        CarMode.reading,
        CarSignal.next,
        CarAction.stopReading,
      );
      final decoded = CarButtonMap.tryDecode(edited.encode())!;
      expect(
        decoded.action(CarMode.reading, CarSignal.next),
        CarAction.stopReading,
      );
      expect(decoded.action(CarMode.idle, CarSignal.voice), CarAction.dictate);
      final junk = CarButtonMap.tryDecode(
        '{"idle":{"next":"explode","warp":"activate"}}',
      )!;
      expect(junk.action(CarMode.idle, CarSignal.next), CarAction.nothing);
      expect(CarButtonMap.tryDecode('not json'), isNull);
    });
  });

  group('speech text', () {
    test('secrets are redacted before speech', () {
      final spoken = carRedact(
        'key sk-abcdefghijklmnopqrstuv and password=hunter2 and '
        'ghp_ABCDEFGHIJKLMNOPQRSTUVWX and ${'a1' * 20}',
      );
      expect(spoken, isNot(contains('abcdefghijklmnop')));
      expect(spoken, isNot(contains('hunter2')));
      expect(spoken, isNot(contains('ghp_')));
      expect(spoken, contains('redacted'));
      expect(carRedact('Tests passed in window 2.'), 'Tests passed in window 2.');
    });

    test('read-back is capped at the word limit', () {
      final long = List.generate(85, (i) => 'w$i').join(' ');
      final spoken = carReadback(long, maxWords: 40);
      expect(spoken, startsWith('w0 w1'));
      expect(spoken, contains('w24'));
      expect(spoken, isNot(contains('w25 ')));
      expect(spoken, endsWith('and 60 more words'));
      expect(carReadback('short text', maxWords: 40), 'short text');
    });

    test('silence hallucinations and the command prefix', () {
      expect(carLooksLikeSilenceHallucination('Thank you.', 900), isTrue);
      expect(carLooksLikeSilenceHallucination('', 9000), isTrue);
      expect(carLooksLikeSilenceHallucination('Thank you.', 9000), isFalse);
      expect(carLooksLikeSilenceHallucination('Run the tests', 900), isFalse);
      expect(carCommandPrefixRemainder('Command, escape.'), 'escape.');
      expect(carCommandPrefixRemainder('computer slash compact'), 'slash compact');
      expect(carCommandPrefixRemainder('Command'), '');
      expect(carCommandPrefixRemainder('commander keen is great'), isNull);
      expect(carCommandPrefixRemainder('Fix the command parser'), isNull);
    });

    test('backspace read-back diff', () {
      expect(carDeletedText('> fix the tests\nfoo', '> fix \nfoo'), 'the tests');
      expect(carDeletedText('a\nb', 'a\nb'), isNull);
      expect(carDeletedText('abc\nxyz', 'ab\nxy'), isNull);
      expect(carDeletedText('abc', 'abd'), isNull);
    });
  });
}
