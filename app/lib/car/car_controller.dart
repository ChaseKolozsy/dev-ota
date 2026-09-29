import 'dart:async';

import 'package:flutter/foundation.dart';

import '../terminal_macro.dart';
import '../terminal_watch.dart';
import 'car_buttons.dart';
import 'car_grammar.dart';
import 'car_settings.dart';
import 'car_speech_text.dart';

/// Native side of car mode (implemented over the `devota/car` channel).
abstract class CarPlatform {
  /// Speaks through DevOTA's own player. Completes when playback ends; the
  /// result is false when it failed or was interrupted.
  Future<bool> speak(String text, {bool interrupt = true});
  Future<void> stopSpeaking();
  Future<void> earcon(String kind);
  Future<CarStartResult> startDictation(String label, {int maxSeconds = 180});
  Future<int> stopDictation(String reason);
  Future<Uint8List?> takeRecording();
  Future<void> discardRecording();

  /// Whether [recognizeRecording] can work at all on this phone.
  Future<bool> canRecognizeRecording();
  Future<String?> recognizeRecording();
  Future<CarStartResult> startCommandSession(String label);
  Future<void> endCommandSession();
  Future<CarListenResult> listenCommand(List<String> biasing, {int timeoutMs});
  Future<void> cancelListening();
  Future<void> claimButtons();
}

class CarStartResult {
  const CarStartResult(this.ok, {this.call = false, this.error});
  final bool ok;
  final bool call;
  final String? error;
}

class CarListenResult {
  const CarListenResult({this.text, this.error});
  final String? text;

  /// no_match, speech_timeout, busy, unavailable, cancelled, other:<code>.
  final String? error;
  bool get silent => error == 'speech_timeout' || error == 'no_match';
}

class CarPane {
  const CarPane(this.id, this.status, {this.canEnter = false});
  final String id;
  final String status;
  final bool canEnter;
}

class CarSendResult {
  const CarSendResult.ok([this.deleted]) : ok = true, message = null;
  const CarSendResult.failed(String this.message) : ok = false, deleted = null;
  final bool ok;
  final String? message;

  /// For backspace: the text that disappeared, when it is known exactly.
  final String? deleted;
}

/// The terminal side: bound tmux panes reached over SSH exec channels
/// (TerminalWatchController), plus the visible app for UI commands.
abstract class CarTarget {
  List<CarPane> panes();

  /// Ranked like the Macros tab (`rankTerminalMacros`).
  List<TerminalMacro> macros();
  Future<CarSendResult> sendKeys(String paneId, String bytes);
  Future<CarSendResult> submitText(String paneId, String text);
  Future<CarSendResult> backspace(String paneId, int count);
  Future<CarSendResult> runMacro(String paneId, TerminalMacro macro);
  Future<CarSendResult> scroll(String paneId, int lines, {required bool up});
  Future<CarSendResult> scrollBottom(String paneId);

  /// Cleaned conclusion text of the pane, or null when unavailable.
  Future<String?> readConclusion(String paneId);
  Future<String?> transcribeHome(Uint8List wav);
  Future<String?> transcribeOpenAi(Uint8List wav);
  Future<bool> ui(CarUiCommand command);
  Future<void> reconnect();
  Future<void> restartZeroTier();
}

class CarMenuItem {
  const CarMenuItem(this.id, this.label, {this.macro, this.paneId});
  final String id;
  final String label;
  final TerminalMacro? macro;
  final String? paneId;
}

/// The car-mode state machine (proposal §3 CarStateMachine, §5.2, §7–§9).
class CarController extends ChangeNotifier {
  CarController({
    required this.platform,
    required this.target,
    required CarSettings settings,
    this.onCarModeOff,
    this.onSettingsChanged,
    DateTime Function()? now,
    this.confirmTimeout = const Duration(seconds: 6),
    this.silenceLimit = const Duration(seconds: 10),
    this.autoSendDelay = const Duration(seconds: 3),
    this.idleRefocus = const Duration(seconds: 15),
    this.homeTimeout = const Duration(seconds: 60),
  }) : _settings = settings,
       now = now ?? DateTime.now;

  final CarPlatform platform;
  final CarTarget target;
  final VoidCallback? onCarModeOff;
  final ValueChanged<CarSettings>? onSettingsChanged;
  final DateTime Function() now;
  final Duration confirmTimeout;
  final Duration silenceLimit;
  final Duration autoSendDelay;
  final Duration idleRefocus;
  final Duration homeTimeout;

  CarSettings _settings;
  CarSettings get settings => _settings;
  set settings(CarSettings value) {
    _settings = value;
    _notify();
  }

  CarMode _mode = CarMode.idle;
  CarMode get mode => _mode;
  bool _active = false;
  bool get active => _active;

  /// True while a real call owns the car's buttons (§11).
  bool _yielded = false;
  bool get yielded => _yielded;

  String? _targetPaneId;
  String? get stagedText => _staged;
  String? _staged;
  bool _stagedNeedsTranscription = false;
  int _recordedMs = 0;
  bool _enterWarned = false;
  String _lastAnnouncement = '';
  DateTime? _lastSignalAt;
  int _focus = 0;
  final _menuStack = <String>[];
  Completer<bool>? _confirm;
  Timer? _confirmTimer;
  Timer? _autoSend;
  int _epoch = 0;
  List<String> _readingChunks = const [];
  int _readingIndex = 0;
  (bool, int)? _lastScroll;
  bool _commandLoop = false;
  bool _commandCall = false;
  bool _pausedByCall = false;

  /// Why the last transcription failed, for the spoken failure.
  String? _transcribeFailure;
  final _log = <String>[];

  /// Recent controller decisions (no transcript or terminal text), for the
  /// settings screen and tests.
  List<String> get log => List.unmodifiable(_log);

  void _trace(String line) {
    _log.add(line);
    if (_log.length > 200) _log.removeAt(0);
  }

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _setMode(CarMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _trace('mode ${mode.name}');
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _commandLoop = false;
    _epoch++;
    _cancelTimers();
    final pending = _confirm;
    _confirm = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    super.dispose();
  }

  // ---------------------------------------------------------------- start/stop

  Future<void> start() async {
    _active = true;
    _yielded = false;
    _setMode(CarMode.idle);
    await _say('DevOTA car mode on.');
  }

  Future<void> stop() async {
    _active = false;
    _epoch++;
    _commandLoop = false;
    _cancelTimers();
    _confirm?.complete(false);
    _confirm = null;
    _staged = null;
    _stagedNeedsTranscription = false;
    _setMode(CarMode.idle);
  }

  void _cancelTimers() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _autoSend?.cancel();
    _autoSend = null;
  }

  // ------------------------------------------------------------------ panes

  List<CarPane> get _panes => target.panes().take(3).toList();

  CarPane? get _pane {
    final panes = _panes;
    if (panes.isEmpty) return null;
    final wanted = _targetPaneId ?? _settings.targetPane;
    for (final p in panes) {
      if (p.id == wanted) return p;
    }
    return panes.first;
  }

  String _label(CarPane? pane) {
    if (pane == null) return 'no window';
    final index = _panes.indexWhere((p) => p.id == pane.id);
    return 'window ${index + 1}';
  }

  String get _targetLabel => _label(_pane);

  // ----------------------------------------------------------------- speech

  Future<bool> _say(String text, {bool interrupt = true}) async {
    if (_disposed) return false;
    final spoken = carRedact(text);
    _lastAnnouncement = spoken;
    _trace('say');
    if (!_settings.speechEnabled) {
      await platform.earcon('tick');
      return true;
    }
    return platform.speak(spoken, interrupt: interrupt);
  }

  /// Button order for spoken hints: the Corolla's wheel buttons first.
  static const _hintOrder = [
    CarSignal.next,
    CarSignal.previous,
    CarSignal.pause,
    CarSignal.hangUp,
    CarSignal.play,
    CarSignal.playPause,
    CarSignal.redial,
    CarSignal.voice,
    CarSignal.answer,
  ];

  /// The spoken name of the button that does [action] in [mode], so every
  /// prompt stays true to the (editable) button map.
  String? _button(CarMode mode, CarAction action) {
    final map = _settings.effectiveButtonMap;
    for (final signal in _hintOrder) {
      if (map.action(mode, signal) == action) return carSignalSpoken(signal);
    }
    return null;
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// "Next to try again, previous to redo." for the staged choices.
  String _stagedChoices(String retry) {
    final parts = [
      if (_button(CarMode.staged, CarAction.submit) case final b?) '$b to $retry',
      if (_button(CarMode.staged, CarAction.redictate) case final b?)
        '$b to record again',
      if (_button(CarMode.staged, CarAction.cancelAll) case final b?)
        '$b to discard',
    ];
    return parts.isEmpty ? '' : '${_cap(parts.join(', '))}.';
  }

  // ---------------------------------------------------------------- signals

  /// A car button arrived (already timing-classified natively).
  Future<void> handleSignal(CarSignal signal) async {
    if (!_active) return;
    if (_yielded) {
      // A real call owns the car's buttons; DevOTA never consumes them.
      _trace('ignored ${signal.name} during real call');
      return;
    }
    final idleFor = _lastSignalAt == null
        ? null
        : now().difference(_lastSignalAt!);
    _lastSignalAt = now();
    final action = _settings.effectiveButtonMap.action(_mode, signal);
    if (_autoSend != null) {
      // Any button cancels an auto-send countdown (§7, Q5 option b); cancel
      // itself goes on to discard the text.
      _autoSend?.cancel();
      _autoSend = null;
      if (action != CarAction.cancelAll) {
        unawaited(platform.stopSpeaking());
        final send = _button(CarMode.staged, CarAction.submit);
        await _say(send == null ? 'Not sent.' : 'Not sent. ${_cap(send)} to send.');
        return;
      }
    }
    _trace('${signal.name} in ${_mode.name} -> ${action.name}');
    if (action == CarAction.nothing) return;
    if (action != CarAction.repeat) unawaited(platform.stopSpeaking());
    await perform(action, idleFor: idleFor);
  }

  Future<void> perform(CarAction action, {Duration? idleFor}) async {
    switch (action) {
      case CarAction.nothing:
        return;
      case CarAction.focusNext:
      case CarAction.focusPrevious:
        await _moveFocus(action == CarAction.focusNext ? 1 : -1, idleFor);
      case CarAction.activate:
        await _activate(idleFor: idleFor);
      case CarAction.dictate:
      case CarAction.redictate:
        await _dictate();
      case CarAction.commandMode:
        await enterCommandMode();
      case CarAction.stopTranscribe:
        await stopAndTranscribe('button');
      case CarAction.cancelRecording:
        await _cancelRecording();
      case CarAction.submit:
        await _submit();
      case CarAction.enter:
        await _enter();
      case CarAction.readAgain:
        await _readBack();
      case CarAction.discard:
        await _runCommand(
          const CarCommand(CarCommandKind.scratch, 'Scratch that', destructive: true),
        );
      case CarAction.cancel:
        _resolveConfirm(false);
      case CarAction.cancelAll:
        await _cancelAll();
      case CarAction.confirm:
        _resolveConfirm(true);
      case CarAction.endCommand:
        await endCommandMode();
      case CarAction.earlier:
        await _readStep(-1);
      case CarAction.nextChunk:
        await _readStep(1);
      case CarAction.stopReading:
        _epoch++;
        await platform.stopSpeaking();
        _setMode(CarMode.idle);
      case CarAction.scrollUp:
      case CarAction.scrollDown:
        await _runCommand(
          CarCommand(
            action == CarAction.scrollUp
                ? CarCommandKind.scrollUp
                : CarCommandKind.scrollDown,
            action == CarAction.scrollUp ? 'Scroll up' : 'Scroll down',
            count: 15,
          ),
        );
      case CarAction.arrowUp:
        await _runCommand(parseCarCommand('up').command!);
      case CarAction.arrowDown:
        await _runCommand(parseCarCommand('down').command!);
      case CarAction.status:
        await _status();
      case CarAction.repeat:
        await platform.speak(
          _lastAnnouncement.isEmpty ? 'Nothing to repeat.' : _lastAnnouncement,
        );
    }
  }

  // ------------------------------------------------------------------- menu

  List<CarMenuItem> menuItems() {
    final pane = _pane;
    final label = _targetLabel;
    if (_menuStack.isNotEmpty && _menuStack.last == 'macros') {
      final items = <CarMenuItem>[];
      final macros = target.macros();
      for (var i = 0; i < macros.length; i++) {
        final m = macros[i];
        if (m.isDeviceMacro || notificationMacroError(m) != null) continue;
        items.add(CarMenuItem('macro', 'Macro ${i + 1}, ${m.name}', macro: m));
      }
      items.add(const CarMenuItem('back', 'Back'));
      return items;
    }
    if (_menuStack.isNotEmpty && _menuStack.last == 'windows') {
      final panes = _panes;
      return [
        for (var i = 0; i < panes.length; i++)
          CarMenuItem('window', 'Window ${i + 1}', paneId: panes[i].id),
        const CarMenuItem('back', 'Back'),
      ];
    }
    return [
      if (_settings.dictationEnabled && pane != null)
        CarMenuItem('dictate', 'Dictate to $label'),
      if (pane != null) CarMenuItem('listen', 'Listen, $label'),
      const CarMenuItem('status', 'Status'),
      if (pane != null && pane.canEnter)
        CarMenuItem('sendEnter', 'Send Enter, $label'),
      if (pane != null) const CarMenuItem('macros', 'Macros'),
      if (_panes.length > 1) const CarMenuItem('windows', 'Select window'),
      if (_settings.commandsEnabled) const CarMenuItem('commands', 'Commands'),
      const CarMenuItem('reconnect', 'Reconnect SSH'),
      const CarMenuItem('zerotier', 'Restart ZeroTier'),
      const CarMenuItem('carOff', 'Car mode off'),
    ];
  }

  CarMenuItem get focusedItem {
    final items = menuItems();
    _focus = _focus.clamp(0, items.length - 1);
    return items[_focus];
  }

  /// Back to the top menu's first item ("Dictate" whenever dictation is on
  /// and a window is bound).
  void _toTop() {
    _menuStack.clear();
    _focus = 0;
  }

  bool _afterPause(Duration? idleFor) =>
      idleFor != null && idleFor >= idleRefocus;

  Future<void> _moveFocus(int delta, Duration? idleFor) async {
    if (_afterPause(idleFor)) {
      // The first press after a pause says where you are instead of moving,
      // and after a pause that is always the top of the menu.
      _toTop();
    } else {
      final items = menuItems();
      _focus = (_focus + delta) % items.length;
      if (_focus < 0) _focus += items.length;
    }
    _notify();
    await _say(focusedItem.label);
  }

  Future<void> _activate({Duration? idleFor}) async {
    // After a pause (or as the very first press) the focus is back on
    // "Dictate", so a first activate always starts dictation.
    if (idleFor == null || _afterPause(idleFor)) _toTop();
    final item = focusedItem;
    _trace('activate ${item.id}');
    switch (item.id) {
      case 'dictate':
        await _dictate();
      case 'listen':
        await _runCommand(parseCarCommand('read').command!);
      case 'status':
        await _status();
      case 'sendEnter':
        await _runCommand(parseCarCommand('enter').command!);
      case 'macros':
        _menuStack.add('macros');
        _focus = 0;
        await _say('Macros. ${focusedItem.label}');
      case 'windows':
        _menuStack.add('windows');
        _focus = 0;
        await _say('Select window. ${focusedItem.label}');
      case 'back':
        _menuStack.removeLast();
        _focus = 0;
        await _say(focusedItem.label);
      case 'macro':
        await _runMacro(item.macro!, byPosition: true);
      case 'window':
        _selectPane(item.paneId!);
        _menuStack.clear();
        _focus = 0;
        await _say('Target $_targetLabel.');
      case 'commands':
        await enterCommandMode();
      case 'reconnect':
        await _say('Reconnecting.');
        await target.reconnect();
      case 'zerotier':
        await _say('Restarting ZeroTier.');
        await target.restartZeroTier();
      case 'carOff':
        await _say('Car mode off.');
        onCarModeOff?.call();
    }
  }

  void _selectPane(String paneId) {
    _targetPaneId = paneId;
    _settings = _settings.copyWith(targetPane: paneId);
    onSettingsChanged?.call(_settings);
    _notify();
  }

  // -------------------------------------------------------------- dictation

  Future<void> _dictate() async {
    if (!_settings.dictationEnabled) {
      await _say('Dictation is off.');
      return;
    }
    final pane = _pane;
    if (pane == null) {
      await _say('No window bound. Bind one when parked.');
      return;
    }
    _epoch++;
    _commandLoop = false;
    _cancelTimers();
    _toTop();
    await platform.discardRecording();
    _staged = null;
    _stagedNeedsTranscription = false;
    _pausedByCall = false;
    _transcribeFailure = null;
    _setMode(CarMode.dictating);
    await _say('Recording, ${_label(pane)}.');
    if (_mode != CarMode.dictating) return;
    final started = await platform.startDictation(_label(pane));
    if (!started.ok) {
      _setMode(CarMode.idle);
      await _say('Recording failed. ${started.error ?? ''}');
    }
  }

  Future<void> _cancelRecording() async {
    await platform.stopDictation('cancel');
    await platform.discardRecording();
    _setMode(CarMode.idle);
    await platform.earcon('stop');
    await _say('Recording discarded.');
  }

  /// Cancel (the Corolla's "+"): stop speaking and throw away whatever is
  /// pending — a recording, a transcription in flight, staged text, a
  /// reading, a confirmation — without sending anything. Discarding one's own
  /// unsent dictation is the safe direction, so it is not confirmed.
  Future<void> _cancelAll() async {
    _epoch++;
    _cancelTimers();
    await platform.stopSpeaking();
    if (_confirm != null) {
      _resolveConfirm(false);
      return;
    }
    switch (_mode) {
      case CarMode.dictating:
        await platform.stopDictation('cancel');
        await _discardPending();
        await platform.earcon('stop');
        await _say('Recording discarded.');
      case CarMode.transcribing:
      case CarMode.staged:
        if (_mode == CarMode.transcribing) {
          await platform.cancelListening();
        }
        await _discardPending();
        await _say('Discarded.');
      case CarMode.reading:
        _setMode(CarMode.idle);
        await platform.earcon('stop');
      case CarMode.command:
        await endCommandMode();
      case CarMode.idle:
      case CarMode.confirming:
        _toTop();
        _notify();
        await platform.earcon('stop');
    }
  }

  Future<void> _discardPending() async {
    await platform.discardRecording();
    _staged = null;
    _stagedNeedsTranscription = false;
    _pausedByCall = false;
    _transcribeFailure = null;
    _toTop();
    _setMode(_commandLoop ? CarMode.command : CarMode.idle);
  }

  /// Hang-up, play/pause, the cap, or a lost link stopped the recording.
  Future<void> stopAndTranscribe(String reason) async {
    if (_mode != CarMode.dictating) return;
    _recordedMs = await platform.stopDictation(reason);
    await platform.earcon('stop');
    await _transcribeHeld();
  }

  Future<void> _transcribeHeld() async {
    final epoch = ++_epoch;
    _setMode(CarMode.transcribing);
    unawaited(_say('Transcribing.'));
    String? text;
    var failed = false;
    try {
      text = await _transcribe();
    } catch (_) {
      failed = true;
    }
    if (epoch != _epoch || !_active) return;
    if (failed || text == null) {
      _staged = null;
      _stagedNeedsTranscription = true;
      _setMode(CarMode.staged);
      await _say(_transcribeFailedText());
      return;
    }
    await _handleTranscript(text.trim());
  }

  String _transcribeFailedText() {
    final lead = switch (_transcribeFailure) {
      'home' => 'Home transcription failed. Recording kept.',
      'phone' => "This phone can't transcribe a recording. Recording kept.",
      _ => "Couldn't transcribe.",
    };
    final choices = _stagedChoices('try again');
    return choices.isEmpty ? lead : '$lead $choices';
  }

  Future<String?> _transcribe() async {
    _transcribeFailure = null;
    switch (_settings.dictationRecognizer) {
      case CarDictationRecognizer.onDevice:
        if (!await platform.canRecognizeRecording()) {
          _transcribeFailure = 'phone';
          return null;
        }
        return platform.recognizeRecording();
      case CarDictationRecognizer.openAi:
        final wav = await platform.takeRecording();
        if (wav == null) return null;
        return target.transcribeOpenAi(wav);
      case CarDictationRecognizer.homeWhisper:
        final wav = await platform.takeRecording();
        if (wav == null) return null;
        String? text;
        try {
          text = await target.transcribeHome(wav).timeout(homeTimeout);
        } catch (_) {
          text = null;
        }
        if (text != null) return text;
        // Android 12 cannot feed a held recording to the phone recognizer,
        // and the car's mic left with the call: say so plainly and keep the
        // audio for a retry rather than pretend to fall back.
        if (!await platform.canRecognizeRecording()) {
          _transcribeFailure = 'home';
          return null;
        }
        await _say('Using phone recognizer.');
        return platform.recognizeRecording();
    }
  }

  Future<void> _handleTranscript(String text) async {
    if (carLooksLikeSilenceHallucination(text, _recordedMs)) {
      await platform.discardRecording();
      _setMode(CarMode.idle);
      await _say('Heard nothing.');
      return;
    }
    final remainder = carCommandPrefixRemainder(text);
    if (remainder != null && _settings.commandsEnabled) {
      await platform.discardRecording();
      _setMode(CarMode.idle);
      if (remainder.isNotEmpty) {
        await _runTranscriptCommand(remainder);
      }
      await enterCommandMode();
      return;
    }
    await platform.discardRecording();
    _staged = text;
    _stagedNeedsTranscription = false;
    _enterWarned = false;
    _setMode(CarMode.staged);
    await _readBack(fresh: true);
  }

  Future<void> _readBack({bool fresh = false}) async {
    if (_mode != CarMode.staged) return;
    final staged = _staged;
    if (staged == null) {
      await _say(
        _pausedByCall
            ? 'Dictation paused by a call. ${_stagedChoices('transcribe what I have')}'
            : _transcribeFailedText(),
      );
      return;
    }
    final readback = carReadback(staged, maxWords: _settings.readbackMaxWords);
    final where = _settings.verbosity == CarVerbosity.terse
        ? 'Staged'
        : 'Staged for $_targetLabel';
    final send = _button(CarMode.staged, CarAction.submit);
    switch (_settings.dictationSend) {
      case CarDictationSend.stageOnly:
        await _say(fresh ? '$where.' : '$where: $readback.');
      case CarDictationSend.stageReadConfirm:
        await _say(
          _settings.verbosity == CarVerbosity.terse
              ? (send == null ? '$where: $readback.' : '$where: $readback. ${_cap(send)} to send.')
              : '$where: $readback. ${_stagedChoices('send')}',
        );
      case CarDictationSend.autoSendCountdown:
        final ok = await _say('$where: $readback. Sending in 3.');
        if (!ok || _mode != CarMode.staged || _staged != staged) return;
        final epoch = _epoch;
        _autoSend = Timer(autoSendDelay, () {
          _autoSend = null;
          if (epoch == _epoch && _mode == CarMode.staged) {
            unawaited(_submit());
          }
        });
    }
  }

  Future<void> _submit() async {
    if (_mode == CarMode.staged && _staged == null) {
      if (_stagedNeedsTranscription) await _transcribeHeld();
      return;
    }
    final staged = _staged;
    final pane = _pane;
    if (pane == null) {
      await _say('Not sent: no window bound.');
      return;
    }
    if (staged == null) {
      // Nothing staged: submit behaves exactly like enter (§8.4).
      await _sendKeys(pane, '\r', 'Enter');
      return;
    }
    final result = await target.submitText(pane.id, staged);
    if (result.ok) {
      _staged = null;
      _setMode(_commandLoop ? CarMode.command : CarMode.idle);
      await _say('Sent to ${_label(pane)}.');
    } else {
      await _say('Not sent: ${result.message ?? '${_label(pane)} changed'}. Say submit to try again.');
    }
  }

  Future<void> _enter() async {
    final pane = _pane;
    if (pane == null) {
      await _say('Not sent: no window bound.');
      return;
    }
    if (_staged != null && !_enterWarned) {
      _enterWarned = true;
      await _say(
        'You have staged text. Say submit to send it, or enter again to press Enter only.',
      );
      return;
    }
    await _sendKeys(pane, '\r', 'Enter');
  }

  // ----------------------------------------------------------- command mode

  Future<void> enterCommandMode() async {
    if (!_settings.commandsEnabled) {
      await _say('Commands are off.');
      return;
    }
    if (_commandLoop) return;
    _commandLoop = true;
    _setMode(CarMode.command);
    final epoch = ++_epoch;
    _commandCall = false;
    if (_settings.commandEndOnHangUp) {
      final session = await platform.startCommandSession(_targetLabel);
      _commandCall = session.ok && session.call;
    }
    await platform.earcon('command');
    await _say('Commands, $_targetLabel.');
    var silence = Duration.zero;
    while (_commandLoop && epoch == _epoch && _active && !_yielded) {
      final started = now();
      final heard = await platform.listenCommand(
        carBiasingPhrases(),
        timeoutMs: silenceLimit.inMilliseconds,
      );
      if (!_commandLoop || epoch != _epoch || !_active || _yielded) break;
      if (heard.error == 'cancelled') break;
      if (heard.text == null || heard.text!.trim().isEmpty) {
        if (heard.silent) {
          // A silent result means the recognizer waited out its own
          // no-speech timeout, so count at least half the limit even when
          // the clock barely moved: two silent listens end the mode.
          final waited = now().difference(started);
          final half = silenceLimit ~/ 2;
          silence += waited > half ? waited : half;
          if (_settings.commandEndOnSilence && silence >= silenceLimit) {
            await endCommandMode();
            break;
          }
          continue;
        }
        await _say('Recognizer unavailable.');
        await endCommandMode();
        break;
      }
      silence = Duration.zero;
      await _runTranscriptCommand(heard.text!);
      if (_mode == CarMode.idle && !_commandLoop) break;
      if (_commandLoop && _mode != CarMode.command && _mode != CarMode.staged) {
        _setMode(CarMode.command);
      }
    }
  }

  Future<void> endCommandMode() async {
    if (!_commandLoop && _mode != CarMode.command) return;
    _commandLoop = false;
    _epoch++;
    await platform.cancelListening();
    if (_commandCall) {
      _commandCall = false;
      await platform.endCommandSession();
    }
    _setMode(_staged != null ? CarMode.staged : CarMode.idle);
    await platform.earcon('stop');
    await _say('Commands off.');
  }

  Future<void> _runTranscriptCommand(String transcript) async {
    final parsed = parseCarCommand(transcript);
    if (!parsed.ok) {
      _trace('unmatched');
      await _say(carDidntCatch);
      return;
    }
    await _runCommand(parsed.command!);
  }

  // --------------------------------------------------------------- commands

  bool _needsConfirm(CarCommand c) {
    // "exit" ends the Claude session; it is always confirmed (§8.3).
    if (c.kind == CarCommandKind.slash && c.text == 'exit') return true;
    if (!_settings.confirmDestructive) return false;
    return switch (c.kind) {
      CarCommandKind.slash => _settings.slashConfirm[c.text] ?? false,
      CarCommandKind.macroNumber =>
        _settings.macroConfirm != CarMacroConfirm.never,
      CarCommandKind.macroName =>
        _settings.macroConfirm == CarMacroConfirm.always,
      _ => c.destructive,
    };
  }

  Future<bool> _askConfirm(String prompt) async {
    final previous = _mode;
    _confirm?.complete(false);
    final completer = Completer<bool>();
    _confirm = completer;
    _setMode(CarMode.confirming);
    _confirmTimer?.cancel();
    _confirmTimer = Timer(confirmTimeout, () => _resolveConfirm(false));
    final yes = _button(CarMode.confirming, CarAction.confirm);
    await _say(yes == null ? '$prompt Say yes to confirm.' : '$prompt Press $yes to confirm.');
    if (_commandLoop && !completer.isCompleted) {
      // In command mode "yes" / "no" also answer (§8.6).
      unawaited(() async {
        while (!completer.isCompleted) {
          final heard = await platform.listenCommand(const [
            'yes',
            'no',
            'confirm',
            'cancel',
          ], timeoutMs: confirmTimeout.inMilliseconds);
          if (completer.isCompleted) return;
          final kind = heard.text == null
              ? null
              : parseCarCommand(heard.text!).command?.kind;
          if (kind == CarCommandKind.confirmYes) {
            _resolveConfirm(true);
          } else if (kind == CarCommandKind.confirmNo ||
              kind == CarCommandKind.cancel) {
            _resolveConfirm(false);
          } else if (heard.error == 'cancelled' || heard.error == 'unavailable') {
            return;
          }
        }
      }());
    }
    final confirmed = await completer.future;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    if (_mode == CarMode.confirming) {
      _setMode(previous == CarMode.confirming ? CarMode.idle : previous);
    }
    if (!confirmed) await _say('Cancelled.');
    return confirmed;
  }

  void _resolveConfirm(bool value) {
    final c = _confirm;
    if (c == null || c.isCompleted) return;
    _confirm = null;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    if (_commandLoop) unawaited(platform.cancelListening());
    c.complete(value);
  }

  Future<void> _sendKeys(CarPane pane, String bytes, String echo) async {
    final result = await target.sendKeys(pane.id, bytes);
    await _say(
      result.ok
          ? (_settings.verbosity == CarVerbosity.terse
                ? '$echo.'
                : '$echo, ${_label(pane)}.')
          : 'Not sent: ${result.message ?? '${_label(pane)} changed'}.',
    );
    if (result.ok && bytes.endsWith('\r')) _enterWarned = false;
  }

  Future<void> _runCommand(CarCommand c) async {
    _trace('command ${c.kind.name}');
    final pane = _pane;
    final needsPane = switch (c.kind) {
      CarCommandKind.keys ||
      CarCommandKind.enter ||
      CarCommandKind.slash ||
      CarCommandKind.macroNumber ||
      CarCommandKind.macroName ||
      CarCommandKind.read ||
      CarCommandKind.earlier ||
      CarCommandKind.scrollUp ||
      CarCommandKind.scrollDown ||
      CarCommandKind.scrollMore ||
      CarCommandKind.scrollBottom => true,
      CarCommandKind.backspace => _staged == null,
      _ => false,
    };
    if (needsPane && pane == null) {
      await _say('No window bound.');
      return;
    }
    if (c.kind != CarCommandKind.macroNumber &&
        c.kind != CarCommandKind.macroName &&
        _needsConfirm(c)) {
      final what = c.kind == CarCommandKind.scratch
          ? 'Discard the staged text?'
          : '${c.echo} in ${_label(pane)}?';
      if (!await _askConfirm(what)) return;
    }
    switch (c.kind) {
      case CarCommandKind.keys:
        await _sendKeys(pane!, c.bytes!, c.echo);
      case CarCommandKind.enter:
        await _enter();
      case CarCommandKind.submit:
        await _submit();
      case CarCommandKind.slash:
        final word = c.text!;
        final result = await target.submitText(pane!.id, '/$word');
        await _say(
          result.ok
              ? '${c.echo} sent.'
              : 'Not sent: ${result.message ?? '${_label(pane)} changed'}.',
        );
      case CarCommandKind.backspace:
        await _backspace(pane, c.count ?? 1);
      case CarCommandKind.macroNumber:
        final macros = target.macros();
        final n = c.count!;
        if (n > macros.length) {
          await _say('No macro $n.');
          return;
        }
        await _runMacro(macros[n - 1], byPosition: true, number: n);
      case CarCommandKind.macroName:
        final macro = carMatchMacro(target.macros(), c.text!);
        if (macro == null) {
          await _say('No single macro called ${c.text}.');
          return;
        }
        await _runMacro(macro, byPosition: false);
      case CarCommandKind.listMacros:
        final macros = target.macros().take(9).toList();
        await _say(
          macros.isEmpty
              ? 'No macros.'
              : [
                  for (var i = 0; i < macros.length; i++)
                    '${i + 1}, ${macros[i].name}',
                ].join('; '),
        );
      case CarCommandKind.read:
        await _startReading(pane!);
      case CarCommandKind.earlier:
        if (_mode == CarMode.reading) {
          await _readStep(-1);
        } else {
          await _startReading(pane!, fromEarlier: true);
        }
      case CarCommandKind.stopReading:
        _epoch++;
        await platform.stopSpeaking();
        if (_mode == CarMode.reading) _setMode(CarMode.idle);
      case CarCommandKind.status:
        await _status();
      case CarCommandKind.window:
        final panes = _panes;
        final n = c.count!;
        if (n > panes.length) {
          await _say('No window $n.');
          return;
        }
        _selectPane(panes[n - 1].id);
        await _say('Target window $n.');
      case CarCommandKind.scrollUp:
      case CarCommandKind.scrollDown:
        final up = c.kind == CarCommandKind.scrollUp;
        final lines = c.count ?? 15;
        _lastScroll = (up, lines);
        final result = await target.scroll(pane!.id, lines, up: up);
        await _say(result.ok ? c.echo : 'Not scrolled: ${result.message}.');
      case CarCommandKind.scrollMore:
        final last = _lastScroll;
        if (last == null) {
          await _say('Scroll first.');
          return;
        }
        final result = await target.scroll(pane!.id, last.$2, up: last.$1);
        await _say(result.ok ? 'More.' : 'Not scrolled: ${result.message}.');
      case CarCommandKind.scrollBottom:
        _lastScroll = null;
        final result = await target.scrollBottom(pane!.id);
        await _say(result.ok ? 'Bottom.' : 'Not scrolled: ${result.message}.');
      case CarCommandKind.ui:
        final done = await target.ui(c.ui!);
        await _say(done ? '${c.echo}.' : "DevOTA isn't open.");
      case CarCommandKind.done:
        await endCommandMode();
      case CarCommandKind.repeat:
        await platform.speak(
          _lastAnnouncement.isEmpty ? 'Nothing to repeat.' : _lastAnnouncement,
        );
      case CarCommandKind.cancel:
      case CarCommandKind.confirmNo:
        _resolveConfirm(false);
        await platform.stopSpeaking();
      case CarCommandKind.confirmYes:
        _resolveConfirm(true);
      case CarCommandKind.scratch:
        if (_staged == null && !_stagedNeedsTranscription) {
          await _say('Nothing staged.');
          return;
        }
        _staged = null;
        _stagedNeedsTranscription = false;
        await platform.discardRecording();
        _setMode(_commandLoop ? CarMode.command : CarMode.idle);
        await _say('Discarded.');
      case CarCommandKind.privacyOn:
      case CarCommandKind.privacyOff:
        _settings = _settings.copyWith(
          privacyMode: c.kind == CarCommandKind.privacyOn,
        );
        onSettingsChanged?.call(_settings);
        await _say('${c.echo}.');
      case CarCommandKind.carModeOff:
        await _say('Car mode off.');
        onCarModeOff?.call();
      case CarCommandKind.takeButtons:
        await platform.claimButtons();
        await _say('Buttons back.');
      case CarCommandKind.help:
        await _say(carHelpText);
    }
  }

  Future<void> _runMacro(
    TerminalMacro macro, {
    required bool byPosition,
    int? number,
  }) async {
    final pane = _pane;
    if (pane == null) {
      await _say('No window bound.');
      return;
    }
    if (macro.isDeviceMacro) {
      await _say('Device macro. Run it when parked.');
      return;
    }
    final error = notificationMacroError(macro);
    if (error != null) {
      await _say('Macro ${macro.name} cannot run by voice.');
      return;
    }
    final confirm = _settings.confirmDestructive &&
        switch (_settings.macroConfirm) {
          CarMacroConfirm.always => true,
          CarMacroConfirm.byPositionOnly => byPosition,
          CarMacroConfirm.never => false,
        };
    final name = number == null
        ? 'Macro ${macro.name}'
        : 'Macro $number, ${macro.name}';
    if (confirm) {
      if (!await _askConfirm('Run $name in ${_label(pane)}?')) return;
    } else {
      await _say('$name.');
    }
    final result = await target.runMacro(pane.id, macro);
    await _say(
      result.ok
          ? (_settings.verbosity == CarVerbosity.terse
                ? 'Macro sent.'
                : '$name sent to ${_label(pane)}, waiting for output.')
          : 'Not sent: ${result.message ?? '${_label(pane)} changed'}.',
    );
  }

  Future<void> _backspace(CarPane? pane, int count) async {
    final staged = _staged;
    if (staged != null) {
      // Staged text is DevOTA's own buffer: the read-back is exact (§8.7).
      final n = count > staged.length ? staged.length : count;
      final deleted = staged.substring(staged.length - n);
      _staged = staged.substring(0, staged.length - n);
      if (_staged!.isEmpty) _staged = null;
      await _say(
        n == 0
            ? 'Nothing to delete.'
            : 'Deleted $n ${n == 1 ? 'character' : 'characters'}: ${deleted.trim().isEmpty ? 'space' : deleted.trim()}.',
      );
      return;
    }
    final result = await target.backspace(pane!.id, count);
    if (!result.ok) {
      await _say('Not sent: ${result.message ?? '${_label(pane)} changed'}.');
      return;
    }
    final deleted = result.deleted;
    final what = '$count ${count == 1 ? 'character' : 'characters'}';
    await _say(
      deleted != null && deleted.trim().isNotEmpty && !_settings.privacyMode
          ? 'Deleted $what: $deleted.'
          : 'Deleted $what.',
    );
  }

  // ----------------------------------------------------------------- reading

  Future<void> _startReading(CarPane pane, {bool fromEarlier = false}) async {
    if (_settings.privacyMode) {
      await _say('${_label(pane)}: ${carSpeakableStatus(pane.status)}.');
      return;
    }
    final text = await target.readConclusion(pane.id);
    if (text == null || text.trim().isEmpty) {
      await _say('Nothing to read in ${_label(pane)}.');
      return;
    }
    _readingChunks = carReadingChunks(text);
    _readingIndex = _readingChunks.length > 2 ? _readingChunks.length - 2 : 0;
    if (fromEarlier && _readingIndex > 0) _readingIndex--;
    _setMode(CarMode.reading);
    await _readLoop();
  }

  Future<void> _readStep(int delta) async {
    if (_mode != CarMode.reading || _readingChunks.isEmpty) return;
    final next = _readingIndex + delta;
    if (next < 0) {
      _readingIndex = 0;
      await _say('Start.');
      return;
    }
    if (next >= _readingChunks.length) {
      _epoch++;
      _setMode(CarMode.idle);
      await _say('End.');
      return;
    }
    _readingIndex = next;
    await _readLoop();
  }

  Future<void> _readLoop() async {
    final epoch = ++_epoch;
    while (epoch == _epoch &&
        _mode == CarMode.reading &&
        _readingIndex < _readingChunks.length) {
      final ok = await _say(_readingChunks[_readingIndex]);
      if (!ok || epoch != _epoch) return;
      _readingIndex++;
    }
    if (epoch == _epoch && _mode == CarMode.reading) {
      _setMode(CarMode.idle);
    }
  }

  Future<void> _status() async {
    final panes = _panes;
    if (panes.isEmpty) {
      await _say('No windows bound.');
      return;
    }
    await _say([
      for (var i = 0; i < panes.length; i++)
        'Window ${i + 1}: ${carSpeakableStatus(panes[i].status)}',
    ].join('. '));
  }

  // ------------------------------------------------------- interruptions §11

  /// A real call, emergency call or audio-focus loss took over.
  Future<void> interrupted(String reason) async {
    if (!_active) return;
    _trace('interrupted $reason');
    await platform.stopSpeaking();
    if (reason != 'real_call' && reason != 'emergency') {
      if (_mode == CarMode.reading) {
        _epoch++;
        _setMode(CarMode.idle);
      }
      return;
    }
    _yielded = true;
    _epoch++;
    _resolveConfirm(false);
    _cancelTimers();
    if (_commandLoop) {
      _commandLoop = false;
      await platform.cancelListening();
      if (_commandCall) {
        _commandCall = false;
        await platform.endCommandSession();
      }
    }
    if (_mode == CarMode.dictating) {
      _recordedMs = await platform.stopDictation('real_call');
      _staged = null;
      _stagedNeedsTranscription = true;
      _pausedByCall = true;
      _setMode(CarMode.staged);
    } else if (_mode != CarMode.staged) {
      _setMode(CarMode.idle);
    }
  }

  Future<void> resumed() async {
    if (!_active || !_yielded) return;
    _yielded = false;
    if (_pausedByCall) {
      await _say(
        'Back. Dictation paused. ${_stagedChoices('transcribe what I have')}',
      );
      _pausedByCall = false;
    } else {
      await _say('Back.');
    }
  }

  /// Native stopped the recording (cap, link lost, a real call, an error).
  Future<void> nativeDictationStopped(String reason) async {
    if (_mode != CarMode.dictating) return;
    switch (reason) {
      case 'interrupted':
        // A real call: the `interrupted` event that follows owns this. Never
        // start transcribing (or speaking) while a real call is arriving.
        return;
      case 'error':
        await platform.discardRecording();
        _setMode(CarMode.idle);
        await _say('Recording failed.');
        return;
      case 'cap':
        await _say('Recording limit reached.');
      case 'link_lost':
        await _say('Car audio lost.');
    }
    await _transcribeHeld();
  }
}

/// Splits a conclusion into speakable chunks (same shape as the terminal
/// reader's ConclusionReading, but the car keeps its own cursor).
List<String> carReadingChunks(String text) {
  final chunks = <String>[];
  var remaining = text.trim();
  while (remaining.isNotEmpty) {
    var end = remaining.length > 600 ? 600 : remaining.length;
    if (end < remaining.length) {
      final sentence = remaining
          .substring(0, end)
          .lastIndexOf(RegExp(r'[.!?]\s|\n\n'));
      if (sentence > 200) {
        end = sentence + 1;
      } else {
        final space = remaining.lastIndexOf(' ', end);
        if (space > 200) end = space;
      }
    }
    chunks.add(remaining.substring(0, end).trim());
    remaining = remaining.substring(end).trim();
  }
  return chunks;
}

/// Turns a notification card status into a short spoken phrase.
String carSpeakableStatus(String status) {
  final clean = status
      .replaceAll(RegExp(r'[✓⚠↻?]'), '')
      .split('·')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (clean.isEmpty) return 'unknown';
  return clean.take(2).join(', ');
}

/// Fuzzy macro-name match (§8.2, Q7): exactly one name at ≥ 0.8 similarity.
TerminalMacro? carMatchMacro(List<TerminalMacro> macros, String spoken) {
  String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  final want = norm(spoken);
  if (want.isEmpty) return null;
  final hits = <TerminalMacro>[];
  for (final m in macros) {
    final name = norm(m.name);
    if (name == want) return m;
    if (_similarity(name, want) >= 0.8) hits.add(m);
  }
  return hits.length == 1 ? hits.first : null;
}

double _similarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final d = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var v = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < v) v = d[i][j - 1] + 1;
      if (d[i - 1][j - 1] + cost < v) v = d[i - 1][j - 1] + cost;
      d[i][j] = v;
    }
  }
  final longest = a.length > b.length ? a.length : b.length;
  return 1 - d[a.length][b.length] / longest;
}
