/// Passive listening, Dart side of the devota/passive_voice channel
/// (docs/passive-voice-control.md). Owns the switch: while it is off this
/// class never asks for the service or the recognizer, and it answers any
/// transcript that still arrives with "stop".
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../terminal_macro.dart';
import '../terminal_watch.dart';
import 'voice_controller.dart';

class PassiveVoiceSession extends ChangeNotifier implements VoiceHost {
  PassiveVoiceSession({
    required VoiceTerminal terminal,
    MethodChannel? channel,
    this.canStart,
    this.requestMicrophone,
    this.isAppVisible,
    this.onOpenKeyboard,
    this.onCloseKeyboard,
    VoiceTimerFactory? timer,
  }) : _channel = channel ?? defaultChannel {
    controller = VoiceController(terminal: terminal, host: this, timer: timer)
      ..addListener(_controllerChanged);
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const defaultChannel = MethodChannel('devota/passive_voice');

  final MethodChannel _channel;
  late final VoiceController controller;

  /// Null when listening may start, otherwise why not (shown to the owner).
  final String? Function()? canStart;
  final Future<bool> Function()? requestMicrophone;
  final bool Function()? isAppVisible;
  final VoidCallback? onOpenKeyboard;
  final VoidCallback? onCloseKeyboard;

  bool _enabled = false;
  bool _disposed = false;
  bool _starting = false;
  String? _publishedStatus;

  /// "Quiet restart beeps" (the media stream is muted while a session
  /// starts, only when nothing else is playing).
  bool quietBeeps = true;

  /// The native loop's state: Listening, Paused · call, Speaking, ...
  String? nativeState;

  /// Why listening stopped or could not start.
  String? message;

  bool get enabled => _enabled;
  bool get starting => _starting;

  /// Asks the service for a start request made from the notification while
  /// Dart was not yet listening.
  Future<void> init() async {
    try {
      final requested = await _channel.invokeMethod<bool>(
        'consumeStartRequest',
      );
      if (requested == true) await setEnabled(true);
    } on MissingPluginException {
      // No Android side (tests, desktop).
    } on PlatformException {
      // Ignore; the switch stays off.
    }
  }

  /// The switch. Turning it on starts the service (only while the app is
  /// visible); turning it off stops the service and the recognizer.
  Future<bool> setEnabled(bool on) async {
    if (_disposed) return false;
    if (!on) {
      final wasOn = _enabled;
      _enabled = false;
      _starting = false;
      nativeState = null;
      controller.cancelPending();
      _changed();
      if (wasOn) await _invoke('stop');
      return true;
    }
    if (_enabled || _starting) return _enabled;
    final refusal = canStart?.call();
    if (refusal != null) {
      message = refusal;
      _changed();
      return false;
    }
    _starting = true;
    message = null;
    _changed();
    try {
      final mic = await (requestMicrophone?.call() ?? Future.value(true));
      if (!mic) {
        message = 'Microphone permission is needed for passive listening.';
        return false;
      }
      if (_disposed || !_starting) return false;
      // On before the call so the first transcript is not refused.
      _enabled = true;
      _publishedStatus = controller.statusLine;
      final args = {'quietBeeps': quietBeeps, 'status': _publishedStatus};
      try {
        await _channel.invokeMethod<bool>('start', args);
      } on PlatformException catch (error) {
        // A permission dialog just closed: Android may resume the activity a
        // moment after the grant arrives. Ask once more before giving up.
        if (error.code != 'refused' ||
            !(error.message ?? '').startsWith('Open DevOTA')) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (_disposed || !_enabled) return false;
        await _channel.invokeMethod<bool>('start', args);
      }
      nativeState = 'Starting';
      return true;
    } on PlatformException catch (error) {
      _enabled = false;
      message = error.message ?? error.code;
      return false;
    } on MissingPluginException {
      _enabled = false;
      message = 'Passive listening needs the Android app.';
      return false;
    } finally {
      _starting = false;
      _changed();
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    final args = call.arguments is Map
        ? Map<String, dynamic>.from(call.arguments as Map)
        : const <String, dynamic>{};
    switch (call.method) {
      case 'utterance':
        // Switch off: nothing is interpreted, and the service is told to stop.
        if (!_enabled || _disposed) return {'stop': true};
        final reply = controller.handle(args['text']?.toString() ?? '');
        return reply.toJson();
      case 'state':
        nativeState = args['state']?.toString();
        _changed();
        return null;
      case 'stopped':
        if (_enabled) {
          _enabled = false;
          nativeState = null;
          message = args['reason']?.toString();
          controller.cancelPending();
          _changed();
        }
        return null;
      case 'startRequested':
        unawaited(setEnabled(true));
        return true;
    }
    throw MissingPluginException(call.method);
  }

  void _controllerChanged() {
    _changed();
    final status = controller.statusLine;
    if (_enabled && status != _publishedStatus) {
      _publishedStatus = status;
      unawaited(_invoke('update', {'status': status}));
    }
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No Android side.
    } on PlatformException {
      // Best effort; the service reports its own state.
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // VoiceHost.
  @override
  void speak(String text) {
    if (_enabled) unawaited(_invoke('speak', {'text': text}));
  }

  @override
  bool get appVisible => isAppVisible?.call() ?? false;

  @override
  void openKeyboard() => onOpenKeyboard?.call();

  @override
  void closeKeyboard() => onCloseKeyboard?.call();

  @override
  void stopListening() {
    message = 'Stopped by voice.';
    unawaited(setEnabled(false));
  }

  @override
  void dispose() {
    if (_enabled) unawaited(_invoke('stop'));
    _enabled = false;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    controller.removeListener(_controllerChanged);
    controller.dispose();
    super.dispose();
  }
}

/// [VoiceTerminal] over the notification-bound panes of a
/// [TerminalWatchController], using its guarded voice entry points.
class WatchVoiceTerminal implements VoiceTerminal {
  WatchVoiceTerminal(this.watch, this.rankedMacros);
  final TerminalWatchController watch;

  /// All macros in Macros-tab order, device macros included, so "macro 3"
  /// is the third macro the owner sees there.
  final List<TerminalMacro> Function() rankedMacros;

  @override
  List<VoiceWindow> get windows => [
    for (final b in watch.bindings) VoiceWindow(b.pane.id, b.pane.label),
  ];

  @override
  List<TerminalMacro> get macros => rankedMacros();

  @override
  Future<String?> submitText(String paneId, String text) =>
      watch.voiceSubmitText(paneId, text);

  @override
  Future<String?> sendBytes(String paneId, String bytes) =>
      watch.voiceSendBytes(paneId, bytes);

  @override
  Future<String?> backspace(String paneId, int count) =>
      watch.voiceBackspace(paneId, count);

  @override
  Future<String?> scroll(String paneId, int lines, {required bool up}) =>
      watch.voiceScroll(paneId, lines, up: up);

  @override
  Future<String?> scrollBottom(String paneId) =>
      watch.voiceScrollBottom(paneId);

  @override
  Future<String?> runMacro(String paneId, TerminalMacro macro) =>
      watch.voiceRunMacro(paneId, macro);
}
