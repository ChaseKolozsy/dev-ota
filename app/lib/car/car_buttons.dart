import 'dart:convert';

import 'car_settings.dart';

/// A normalized car signal (proposal §3 `CarSignal`). Native code has already
/// classified timing where the owner enabled it (§8.5, S9).
enum CarSignal {
  next,
  previous,
  playPause,
  playPauseDouble,
  playPauseLong,
  voice,
  voiceDouble,
  answer,
  hangUp,
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
  CarSignal.next => 'Next',
  CarSignal.previous => 'Previous',
  CarSignal.playPause => 'Play/pause',
  CarSignal.playPauseDouble => 'Play/pause double',
  CarSignal.playPauseLong => 'Play/pause long',
  CarSignal.voice => 'Voice/call',
  CarSignal.voiceDouble => 'Voice/call double',
  CarSignal.answer => 'Answer',
  CarSignal.hangUp => 'Hang up',
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

/// Modes whose cells the owner edits. Transcribing ignores every button
/// except that the controller still honours a real-call interruption.
const editableCarModes = [
  CarMode.idle,
  CarMode.dictating,
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
  CarButtonMap withNextPrevMode(CarNextPrevMode mode) {
    final (prev, next) = switch (mode) {
      CarNextPrevMode.menuFocus => (
        CarAction.focusPrevious,
        CarAction.focusNext,
      ),
      CarNextPrevMode.scrollPane => (CarAction.scrollUp, CarAction.scrollDown),
      CarNextPrevMode.arrowKeys => (CarAction.arrowUp, CarAction.arrowDown),
    };
    return withCell(
      CarMode.idle,
      CarSignal.previous,
      prev,
    ).withCell(CarMode.idle, CarSignal.next, next);
  }

  /// The default table of proposal §5.2.
  factory CarButtonMap.defaults([
    CarNextPrevMode nextPrev = CarNextPrevMode.menuFocus,
  ]) {
    const n = CarAction.nothing;
    final map = CarButtonMap({
      CarMode.idle: {
        CarSignal.next: CarAction.focusNext,
        CarSignal.previous: CarAction.focusPrevious,
        CarSignal.playPause: CarAction.activate,
        CarSignal.playPauseDouble: CarAction.commandMode,
        CarSignal.playPauseLong: CarAction.repeat,
        CarSignal.voice: CarAction.dictate,
        CarSignal.voiceDouble: CarAction.commandMode,
        CarSignal.answer: n,
        CarSignal.hangUp: n,
      },
      CarMode.dictating: {
        CarSignal.playPause: CarAction.stopTranscribe,
        CarSignal.playPauseLong: CarAction.cancelRecording,
        CarSignal.hangUp: CarAction.stopTranscribe,
      },
      CarMode.transcribing: const {},
      CarMode.staged: {
        CarSignal.next: CarAction.readAgain,
        CarSignal.previous: CarAction.readAgain,
        CarSignal.playPause: CarAction.submit,
        CarSignal.playPauseDouble: CarAction.discard,
        CarSignal.voice: CarAction.redictate,
      },
      CarMode.command: {
        CarSignal.playPause: CarAction.endCommand,
        CarSignal.hangUp: CarAction.endCommand,
      },
      CarMode.confirming: {
        CarSignal.next: CarAction.cancel,
        CarSignal.previous: CarAction.cancel,
        CarSignal.playPause: CarAction.confirm,
        CarSignal.voice: CarAction.confirm,
        CarSignal.answer: CarAction.confirm,
        CarSignal.hangUp: CarAction.cancel,
      },
      CarMode.reading: {
        CarSignal.next: CarAction.nextChunk,
        CarSignal.previous: CarAction.earlier,
        CarSignal.playPause: CarAction.stopReading,
        CarSignal.voice: CarAction.dictate,
        CarSignal.hangUp: CarAction.stopReading,
      },
    });
    return nextPrev == CarNextPrevMode.menuFocus
        ? map
        : map.withNextPrevMode(nextPrev);
  }

  String encode() => jsonEncode({
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
