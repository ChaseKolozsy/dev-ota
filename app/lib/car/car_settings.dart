import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'car_buttons.dart';

/// Every car-control setting from the steering-wheel proposal §4.1.
///
/// The master switch [enabled] defaults to OFF. While it is off DevOTA makes
/// no car-channel calls at all, so the app behaves exactly as it did before
/// car control existed.
class CarSettings {
  const CarSettings({
    this.enabled = false,
    this.autoDevice = '',
    this.dictationEnabled = true,
    this.commandsEnabled = true,
    this.nextPrevMode = CarNextPrevMode.menuFocus,
    this.speechEnabled = true,
    this.verbosity = CarVerbosity.terse,
    this.confirmDestructive = true,
    this.a11yNavEnabled = false,
    this.commandRecognizer = CarCommandRecognizer.onDevice,
    this.dictationRecognizer = CarDictationRecognizer.homeWhisper,
    this.dictationSend = CarDictationSend.stageReadConfirm,
    this.commandEndOnDone = true,
    this.commandEndOnHangUp = true,
    this.commandEndOnSilence = true,
    this.privacyMode = false,
    this.readbackMaxWords = 40,
    this.targetPane = '',
    this.buttonMap,
    this.macroConfirm = CarMacroConfirm.byPositionOnly,
    this.playPauseDouble = false,
    this.playPauseLong = false,
    this.voiceDouble = false,
    this.doublePressMs = 400,
    this.longPressMs = 700,
    this.slashConfirm = defaultSlashConfirm,
  });

  // Pref keys (§4.1). Every key is in BackupService's allowlists.
  static const kEnabled = 'car_control_enabled';
  static const kAutoDevice = 'car_auto_device';
  static const kDictation = 'car_dictation_enabled';
  static const kCommands = 'car_commands_enabled';
  static const kNextPrev = 'car_nextprev_mode';
  static const kSpeech = 'car_speech_enabled';
  static const kVerbosity = 'car_speech_verbosity';
  static const kConfirmDestructive = 'car_confirm_destructive';
  static const kA11yNav = 'car_a11y_nav_enabled';
  static const kCommandRecognizer = 'car_command_recognizer';
  static const kDictationRecognizer = 'car_dictation_recognizer';
  static const kDictationSend = 'car_dictation_send';
  static const kCommandEnd = 'car_command_end';
  static const kPrivacy = 'car_privacy_mode';
  static const kReadbackMax = 'car_readback_max_words';
  static const kTargetPane = 'car_target_pane';
  static const kButtonMap = 'car_button_map_json';
  static const kMacroConfirm = 'car_macro_confirm';
  static const kPressTiming = 'car_press_timing_json';
  static const kSlashConfirm = 'car_slash_confirm_json';

  static const boolKeys = [
    kEnabled,
    kDictation,
    kCommands,
    kSpeech,
    kConfirmDestructive,
    kA11yNav,
    kPrivacy,
  ];
  static const stringKeys = [
    kAutoDevice,
    kNextPrev,
    kVerbosity,
    kCommandRecognizer,
    kDictationRecognizer,
    kDictationSend,
    kCommandEnd,
    kReadbackMax,
    kTargetPane,
    kButtonMap,
    kMacroConfirm,
    kPressTiming,
    kSlashConfirm,
  ];

  /// Slash commands and whether each needs confirmation (§8.2). Editable,
  /// because Claude Code's command list changes between versions.
  static const defaultSlashConfirm = <String, bool>{
    'compact': true,
    'exit': true,
    'clear': true,
    'plan': false,
  };

  final bool enabled;

  /// Bluetooth address of the car, or '' for "start by hand".
  final String autoDevice;
  final bool dictationEnabled;
  final bool commandsEnabled;
  final CarNextPrevMode nextPrevMode;
  final bool speechEnabled;
  final CarVerbosity verbosity;
  final bool confirmDestructive;
  final bool a11yNavEnabled;
  final CarCommandRecognizer commandRecognizer;
  final CarDictationRecognizer dictationRecognizer;
  final CarDictationSend dictationSend;
  final bool commandEndOnDone;
  final bool commandEndOnHangUp;
  final bool commandEndOnSilence;
  final bool privacyMode;
  final int readbackMaxWords;

  /// Pane id (for example `%3`) of the bound window car actions go to; ''
  /// means the first bound pane.
  final String targetPane;

  /// null means the defaults of §5.2, adjusted by [nextPrevMode].
  final CarButtonMap? buttonMap;
  final CarMacroConfirm macroConfirm;

  /// Timing-based press classes stay off until Button learning shows the car
  /// delivers them reliably (§12 S9).
  final bool playPauseDouble;
  final bool playPauseLong;
  final bool voiceDouble;
  final int doublePressMs;
  final int longPressMs;
  final Map<String, bool> slashConfirm;

  CarButtonMap get effectiveButtonMap =>
      buttonMap ?? CarButtonMap.defaults(nextPrevMode);

  CarSettings copyWith({
    bool? enabled,
    String? autoDevice,
    bool? dictationEnabled,
    bool? commandsEnabled,
    CarNextPrevMode? nextPrevMode,
    bool? speechEnabled,
    CarVerbosity? verbosity,
    bool? confirmDestructive,
    bool? a11yNavEnabled,
    CarCommandRecognizer? commandRecognizer,
    CarDictationRecognizer? dictationRecognizer,
    CarDictationSend? dictationSend,
    bool? commandEndOnDone,
    bool? commandEndOnHangUp,
    bool? commandEndOnSilence,
    bool? privacyMode,
    int? readbackMaxWords,
    String? targetPane,
    CarButtonMap? buttonMap,
    bool resetButtonMap = false,
    CarMacroConfirm? macroConfirm,
    bool? playPauseDouble,
    bool? playPauseLong,
    bool? voiceDouble,
    int? doublePressMs,
    int? longPressMs,
    Map<String, bool>? slashConfirm,
  }) {
    return CarSettings(
      enabled: enabled ?? this.enabled,
      autoDevice: autoDevice ?? this.autoDevice,
      dictationEnabled: dictationEnabled ?? this.dictationEnabled,
      commandsEnabled: commandsEnabled ?? this.commandsEnabled,
      nextPrevMode: nextPrevMode ?? this.nextPrevMode,
      speechEnabled: speechEnabled ?? this.speechEnabled,
      verbosity: verbosity ?? this.verbosity,
      confirmDestructive: confirmDestructive ?? this.confirmDestructive,
      a11yNavEnabled: a11yNavEnabled ?? this.a11yNavEnabled,
      commandRecognizer: commandRecognizer ?? this.commandRecognizer,
      dictationRecognizer: dictationRecognizer ?? this.dictationRecognizer,
      dictationSend: dictationSend ?? this.dictationSend,
      commandEndOnDone: commandEndOnDone ?? this.commandEndOnDone,
      commandEndOnHangUp: commandEndOnHangUp ?? this.commandEndOnHangUp,
      commandEndOnSilence: commandEndOnSilence ?? this.commandEndOnSilence,
      privacyMode: privacyMode ?? this.privacyMode,
      readbackMaxWords: (readbackMaxWords ?? this.readbackMaxWords).clamp(
        20,
        200,
      ),
      targetPane: targetPane ?? this.targetPane,
      buttonMap: resetButtonMap ? null : (buttonMap ?? this.buttonMap),
      macroConfirm: macroConfirm ?? this.macroConfirm,
      playPauseDouble: playPauseDouble ?? this.playPauseDouble,
      playPauseLong: playPauseLong ?? this.playPauseLong,
      voiceDouble: voiceDouble ?? this.voiceDouble,
      doublePressMs: (doublePressMs ?? this.doublePressMs).clamp(250, 700),
      longPressMs: (longPressMs ?? this.longPressMs).clamp(400, 3000),
      slashConfirm: slashConfirm ?? this.slashConfirm,
    );
  }

  static T _enum<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  static CarSettings fromPrefs(SharedPreferences prefs) {
    const d = CarSettings();
    CarButtonMap? map;
    final rawMap = prefs.getString(kButtonMap);
    if (rawMap != null && rawMap.isNotEmpty) {
      map = CarButtonMap.tryDecode(rawMap);
    }
    final end = (prefs.getString(kCommandEnd) ?? 'done,hangup,silence')
        .split(',')
        .map((s) => s.trim())
        .toSet();
    Map<String, dynamic> timing = const {};
    try {
      final raw = prefs.getString(kPressTiming);
      if (raw != null && raw.isNotEmpty) {
        timing = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {}
    var slash = defaultSlashConfirm;
    try {
      final raw = prefs.getString(kSlashConfirm);
      if (raw != null && raw.isNotEmpty) {
        final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        slash = {
          for (final e in decoded.entries)
            if (RegExp(r'^[a-z][a-z0-9-]{0,30}$').hasMatch(e.key))
              e.key: e.value == true,
        };
      }
    } catch (_) {}
    return CarSettings(
      enabled: prefs.getBool(kEnabled) ?? d.enabled,
      autoDevice: prefs.getString(kAutoDevice) ?? d.autoDevice,
      dictationEnabled: prefs.getBool(kDictation) ?? d.dictationEnabled,
      commandsEnabled: prefs.getBool(kCommands) ?? d.commandsEnabled,
      nextPrevMode: _enum(
        CarNextPrevMode.values,
        prefs.getString(kNextPrev),
        d.nextPrevMode,
      ),
      speechEnabled: prefs.getBool(kSpeech) ?? d.speechEnabled,
      verbosity: _enum(
        CarVerbosity.values,
        prefs.getString(kVerbosity),
        d.verbosity,
      ),
      confirmDestructive:
          prefs.getBool(kConfirmDestructive) ?? d.confirmDestructive,
      a11yNavEnabled: prefs.getBool(kA11yNav) ?? d.a11yNavEnabled,
      commandRecognizer: _enum(
        CarCommandRecognizer.values,
        prefs.getString(kCommandRecognizer),
        d.commandRecognizer,
      ),
      dictationRecognizer: _enum(
        CarDictationRecognizer.values,
        prefs.getString(kDictationRecognizer),
        d.dictationRecognizer,
      ),
      dictationSend: _enum(
        CarDictationSend.values,
        prefs.getString(kDictationSend),
        d.dictationSend,
      ),
      commandEndOnDone: end.contains('done'),
      commandEndOnHangUp: end.contains('hangup'),
      commandEndOnSilence: end.contains('silence'),
      privacyMode: prefs.getBool(kPrivacy) ?? d.privacyMode,
      readbackMaxWords: (int.tryParse(prefs.getString(kReadbackMax) ?? '') ??
              d.readbackMaxWords)
          .clamp(20, 200),
      targetPane: prefs.getString(kTargetPane) ?? d.targetPane,
      buttonMap: map,
      macroConfirm: _enum(
        CarMacroConfirm.values,
        prefs.getString(kMacroConfirm),
        d.macroConfirm,
      ),
      playPauseDouble: timing['playPauseDouble'] == true,
      playPauseLong: timing['playPauseLong'] == true,
      voiceDouble: timing['voiceDouble'] == true,
      doublePressMs: ((timing['doubleMs'] as num?)?.toInt() ?? d.doublePressMs)
          .clamp(250, 700),
      longPressMs: ((timing['longMs'] as num?)?.toInt() ?? d.longPressMs)
          .clamp(400, 3000),
      slashConfirm: slash,
    );
  }

  static Future<CarSettings> load() async =>
      fromPrefs(await SharedPreferences.getInstance());

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kEnabled, enabled);
    await prefs.setString(kAutoDevice, autoDevice);
    await prefs.setBool(kDictation, dictationEnabled);
    await prefs.setBool(kCommands, commandsEnabled);
    await prefs.setString(kNextPrev, nextPrevMode.name);
    await prefs.setBool(kSpeech, speechEnabled);
    await prefs.setString(kVerbosity, verbosity.name);
    await prefs.setBool(kConfirmDestructive, confirmDestructive);
    await prefs.setBool(kA11yNav, a11yNavEnabled);
    await prefs.setString(kCommandRecognizer, commandRecognizer.name);
    await prefs.setString(kDictationRecognizer, dictationRecognizer.name);
    await prefs.setString(kDictationSend, dictationSend.name);
    await prefs.setString(
      kCommandEnd,
      [
        if (commandEndOnDone) 'done',
        if (commandEndOnHangUp) 'hangup',
        if (commandEndOnSilence) 'silence',
      ].join(','),
    );
    await prefs.setBool(kPrivacy, privacyMode);
    await prefs.setString(kReadbackMax, '$readbackMaxWords');
    await prefs.setString(kTargetPane, targetPane);
    if (buttonMap == null) {
      await prefs.remove(kButtonMap);
    } else {
      await prefs.setString(kButtonMap, buttonMap!.encode());
    }
    await prefs.setString(kMacroConfirm, macroConfirm.name);
    await prefs.setString(
      kPressTiming,
      jsonEncode({
        'playPauseDouble': playPauseDouble,
        'playPauseLong': playPauseLong,
        'voiceDouble': voiceDouble,
        'doubleMs': doublePressMs,
        'longMs': longPressMs,
      }),
    );
    await prefs.setString(kSlashConfirm, jsonEncode(slashConfirm));
  }
}

enum CarNextPrevMode { menuFocus, scrollPane, arrowKeys }

enum CarVerbosity { terse, normal, verbose }

enum CarCommandRecognizer { onDevice, homeWhisper }

enum CarDictationRecognizer { homeWhisper, onDevice, openAi }

enum CarDictationSend { stageReadConfirm, autoSendCountdown, stageOnly }

enum CarMacroConfirm { always, byPositionOnly, never }

String carNextPrevLabel(CarNextPrevMode m) => switch (m) {
  CarNextPrevMode.menuFocus => 'Menu focus',
  CarNextPrevMode.scrollPane => 'Scroll pane',
  CarNextPrevMode.arrowKeys => 'Arrow keys',
};

String carDictationRecognizerLabel(CarDictationRecognizer r) => switch (r) {
  CarDictationRecognizer.homeWhisper => 'Home Whisper, phone fallback',
  CarDictationRecognizer.onDevice => 'Phone (on-device)',
  CarDictationRecognizer.openAi => 'OpenAI whisper-1 (paid)',
};

String carDictationSendLabel(CarDictationSend s) => switch (s) {
  CarDictationSend.stageReadConfirm => 'Stage, read back, confirm',
  CarDictationSend.autoSendCountdown => 'Read back, auto-send after 3 s',
  CarDictationSend.stageOnly => 'Stage only',
};

String carMacroConfirmLabel(CarMacroConfirm c) => switch (c) {
  CarMacroConfirm.always => 'Always',
  CarMacroConfirm.byPositionOnly => 'By position only',
  CarMacroConfirm.never => 'Never',
};
