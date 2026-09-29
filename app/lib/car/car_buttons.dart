import 'dart:convert';

import 'car_settings.dart';

/// A normalized car signal (proposal §3 `CarSignal`). Native code has already
/// classified timing where the owner enabled it (§8.5, S9).
///
/// [play] and [pause] are the separate KEYCODE_MEDIA_PLAY / KEYCODE_MEDIA_PAUSE
/// keys (the 2020s Corolla sends PAUSE on "+" and a PLAY of its own ~0.5 s
/// after every NEXT, which native code swallows). [playPause] is the toggle
/// key (and HEADSETHOOK), the only one timing-classified. [redial] is the car
/// redialling DevOTA's stand-in call number, cancelled natively before any
/// carrier call is made.
enum CarSignal {
  next,
  previous,
  play,
  pause,
  playPause,
  playPauseDouble,
  playPauseLong,
  voice,
  voiceDouble,
  answer,
  hangUp,
  redial,
}

/// Button-map columns (§5.2). Idle and Menu share a column: in car mode a
/// menu focus always exists.
enum CarMode { idle, dictating, transcribing, staged, command, confirming, reading }

/// The fixed action list each button-map cell chooses from (§5.2).
enum CarAction {
  nothing,
  focusNext,
  focusPrevious,
  activate,
  dictate,
  commandMode,
  stopTranscribe,
  cancelRecording,
  submit,
  enter,
  readAgain,
  redictate,
  discard,
  cancel,
  cancelAll,
  confirm,
  endCommand,
  earlier,
  nextChunk,
  stopReading,
  scrollUp,
  scrollDown,
  arrowUp,
  arrowDown,
  status,
  repeat,
}

String carSignalLabel(CarSignal s) => switch (s) {
  CarSignal.next => 'Next ▶▶|',
  CarSignal.previous => 'Previous |◀◀',
  CarSignal.play => 'Play',
  CarSignal.pause => 'Pause (Corolla "+")',
  CarSignal.playPause => 'Play/pause toggle',
  CarSignal.playPauseDouble => 'Play/pause double',
  CarSignal.playPauseLong => 'Play/pause long',
  CarSignal.voice => 'Voice/call',
  CarSignal.voiceDouble => 'Voice/call double',
  CarSignal.answer => 'Answer',
  CarSignal.hangUp => 'Hang up',
  CarSignal.redial => 'Pick-up (car redial)',
};

/// How a spoken prompt names a button ("Next to send."), lower case.
String carSignalSpoken(CarSignal s) => switch (s) {
  CarSignal.next => 'next',
  CarSignal.previous => 'previous',
  CarSignal.play || CarSignal.playPause => 'play',
  CarSignal.pause => 'pause',
  CarSignal.playPauseDouble => 'double play',
  CarSignal.playPauseLong => 'hold play',
  CarSignal.voice => 'call',
  CarSignal.voiceDouble => 'double call',
  CarSignal.answer => 'answer',
  CarSignal.hangUp => 'hang up',
  CarSignal.redial => 'pick up',
};

String carModeLabel(CarMode m) => switch (m) {
  CarMode.idle => 'Idle / menu',
  CarMode.dictating => 'Dictating',
  CarMode.transcribing => 'Transcribing',
  CarMode.staged => 'Staged',
  CarMode.command => 'Command',
  CarMode.confirming => 'Confirming',
  CarMode.reading => 'Reading',
};

String carActionLabel(CarAction a) => switch (a) {
  CarAction.nothing => '—',
  CarAction.focusNext => 'Focus next',
  CarAction.focusPrevious => 'Focus previous',
  CarAction.activate => 'Activate',
  CarAction.dictate => 'Dictate',
  CarAction.commandMode => 'Command mode',
  CarAction.stopTranscribe => 'Stop + transcribe',
  CarAction.cancelRecording => 'Cancel recording',
  CarAction.submit => 'Submit',
  CarAction.enter => 'Enter',
  CarAction.readAgain => 'Read again',
  CarAction.redictate => 'Re-dictate',
  CarAction.discard => 'Discard',
  CarAction.cancel => 'Cancel',
  CarAction.cancelAll => 'Cancel: stop speech, discard',
  CarAction.confirm => 'Confirm',
  CarAction.endCommand => 'End command mode',
  CarAction.earlier => 'Earlier',
  CarAction.nextChunk => 'Skip to next chunk',
  CarAction.stopReading => 'Stop reading',
  CarAction.scrollUp => 'Scroll up',
  CarAction.scrollDown => 'Scroll down',
  CarAction.arrowUp => 'Arrow up',
  CarAction.arrowDown => 'Arrow down',
  CarAction.status => 'Status',
  CarAction.repeat => 'Repeat',
};

/// Modes whose cells the owner edits. Transcribing is editable so a cancel
/// can drop a transcription in flight; by default every other button is
/// ignored there.
const editableCarModes = [
  CarMode.idle,
  CarMode.dictating,
  CarMode.transcribing,
  CarMode.staged,
  CarMode.command,
  CarMode.confirming,
  CarMode.reading,
];

class CarButtonMap {
  CarButtonMap(Map<CarMode, Map<CarSignal, CarAction>> cells)
    : cells = {
        for (final mode in CarMode.values)
          mode: {
            for (final signal in CarSignal.values)
              signal: cells[mode]?[signal] ?? CarAction.nothing,
          },
      };

  final Map<CarMode, Map<CarSignal, CarAction>> cells;

  CarAction action(CarMode mode, CarSignal signal) =>
      cells[mode]?[signal] ?? CarAction.nothing;

  CarButtonMap withCell(CarMode mode, CarSignal signal, CarAction action) {
    final copy = {
      for (final e in cells.entries) e.key: Map<CarSignal, CarAction>.of(e.value),
    };
    copy[mode]![signal] = action;
    return CarButtonMap(copy);
  }

  /// "Next/previous function" rewrites the Idle column in one step (§5.2).
  /// Menu focus: next moves through the spoken menu and previous activates
  /// the focused item, which is "Dictate" after any pause.
  CarButtonMap withNextPrevMode(CarNextPrevMode mode) {
    final (prev, next) = switch (mode) {
      CarNextPrevMode.menuFocus => (CarAction.activate, CarAction.focusNext),
      CarNextPrevMode.scrollPane => (CarAction.scrollUp, CarAction.scrollDown),
      CarNextPrevMode.arrowKeys => (CarAction.arrowUp, CarAction.arrowDown),
    };
    return withCell(
      CarMode.idle,
      CarSignal.previous,
      prev,
    ).withCell(CarMode.idle, CarSignal.next, next);
  }

  /// The default map (proposal §5.2 as revised by the Corolla probe,
  /// 2026-09-28): the wheel sends only instant NEXT, PREVIOUS and PAUSE (+),
  /// hang-up ends DevOTA's own call, and pick-up redials the stand-in call.
  ///
  /// * |◀◀ previous: activate the focused menu item; the menu returns to
  ///   "Dictate" after a pause, so a first |◀◀ always starts dictation.
  ///   After a read-back it records again.
  /// * hang-up: stop recording and transcribe; the text is read back.
  /// * ▶▶| next: after the read-back, send; while idle, move through the menu.
  ///   Also the confirm button, since the car has no lone play.
  /// * + pause: cancel. Stop speaking and discard pending text unsent.
  /// * pick-up (redial): dictate, like |◀◀ from idle.
  ///
  /// Play and the play/pause toggle keep their earlier meanings for cars
  /// that send them.
  factory CarButtonMap.defaults([
    CarNextPrevMode nextPrev = CarNextPrevMode.menuFocus,
  ]) {
    final map = CarButtonMap({
      CarMode.idle: {
        CarSignal.next: CarAction.focusNext,
        CarSignal.previous: CarAction.activate,
        CarSignal.play: CarAction.activate,
        CarSignal.pause: CarAction.cancelAll,
        CarSignal.playPause: CarAction.activate,
        CarSignal.playPauseDouble: CarAction.commandMode,
        CarSignal.playPauseLong: CarAction.repeat,
        CarSignal.voice: CarAction.dictate,
        CarSignal.voiceDouble: CarAction.commandMode,
        CarSignal.redial: CarAction.dictate,
      },
      CarMode.dictating: {
        CarSignal.next: CarAction.stopTranscribe,
        CarSignal.play: CarAction.stopTranscribe,
        CarSignal.pause: CarAction.cancelAll,
        CarSignal.playPause: CarAction.stopTranscribe,
        CarSignal.playPauseLong: CarAction.cancelRecording,
        CarSignal.hangUp: CarAction.stopTranscribe,
      },
      CarMode.transcribing: {CarSignal.pause: CarAction.cancelAll},
      CarMode.staged: {
        CarSignal.next: CarAction.submit,
        CarSignal.previous: CarAction.redictate,
        CarSignal.play: CarAction.submit,
        CarSignal.pause: CarAction.cancelAll,
        CarSignal.playPause: CarAction.submit,
        CarSignal.playPauseDouble: CarAction.discard,
        CarSignal.voice: CarAction.redictate,
        CarSignal.redial: CarAction.redictate,
      },
      CarMode.command: {
        CarSignal.play: CarAction.endCommand,
        CarSignal.pause: CarAction.cancelAll,
        CarSignal.playPause: CarAction.endCommand,
        CarSignal.hangUp: CarAction.endCommand,
      },
      CarMode.confirming: {
        CarSignal.next: CarAction.confirm,
        CarSignal.previous: CarAction.cancel,
        CarSignal.play: CarAction.confirm,
        CarSignal.pause: CarAction.cancel,
        CarSignal.playPause: CarAction.confirm,
        CarSignal.voice: CarAction.confirm,
        CarSignal.answer: CarAction.confirm,
        CarSignal.hangUp: CarAction.cancel,
      },
      CarMode.reading: {
        CarSignal.next: CarAction.nextChunk,
        CarSignal.previous: CarAction.earlier,
        CarSignal.play: CarAction.stopReading,
        CarSignal.pause: CarAction.cancelAll,
        CarSignal.playPause: CarAction.stopReading,
        CarSignal.voice: CarAction.dictate,
        CarSignal.hangUp: CarAction.stopReading,
        CarSignal.redial: CarAction.dictate,
      },
    });
    return nextPrev == CarNextPrevMode.menuFocus
        ? map
        : map.withNextPrevMode(nextPrev);
  }

  /// Saved maps carry this version. A map saved before separate play/pause
  /// signals existed (no version) described every play and pause as the
  /// toggle, which is wrong for the Corolla, so it is dropped in favour of
  /// the current defaults.
  static const encodingVersion = 2;

  String encode() => jsonEncode({
    'version': encodingVersion,
    for (final mode in editableCarModes)
      mode.name: {
        for (final signal in CarSignal.values)
          if (action(mode, signal) != CarAction.nothing)
            signal.name: action(mode, signal).name,
      },
  });

  static CarButtonMap? tryDecode(String raw) {
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (decoded['version'] != encodingVersion) return null;
      final cells = <CarMode, Map<CarSignal, CarAction>>{};
      for (final mode in editableCarModes) {
        final row = decoded[mode.name];
        if (row is! Map) continue;
        final decodedRow = <CarSignal, CarAction>{};
        for (final e in row.entries) {
          final signal = _byName(CarSignal.values, e.key);
          final action = _byName(CarAction.values, e.value);
          if (signal != null && action != null) decodedRow[signal] = action;
        }
        cells[mode] = decodedRow;
      }
      return CarButtonMap(cells);
    } catch (_) {
      return null;
    }
  }

  static T? _byName<T extends Enum>(List<T> values, Object? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}
