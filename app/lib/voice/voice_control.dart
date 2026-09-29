/// Voice control for the Terminal tab: what each utterance does, and the
/// devota/voice_control channel to the Android recognizer service.
///
/// Everything acts on the Terminal tab's current session through the same
/// handlers its own buttons use ([VoiceSurface] is the tab). There is no
/// separate target, no pane binding and no notification watch.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_reader.dart';
import 'voice_commands.dart';

/// The Terminal tab, as voice control sees it.
abstract class VoiceSurface {
  /// The tab's SSH session is connected.
  bool get voiceConnected;

  /// A macro is running and the tab's controls are locked.
  bool get voiceBusy;

  /// Every button that can be named, built from what the tab shows now.
  List<VoiceTarget> get voiceTargets;

  /// The Type command box.
  String get composerText;

  /// The existing _appendComposerText.
  void appendDictation(String text);

  /// Exactly what the composer's send arrow does. False when the arrow is
  /// disabled right now (a recording or transcription is in progress).
  bool submitComposer();

  void clearComposer();
  void composerBackspace(int count);
  void composerDeleteWords(int count);

  /// The rows the terminal is showing right now, top to bottom, read from
  /// the tab's own terminal buffer.
  List<String> get terminalScreenLines;
}

/// What the Android service does after an utterance.
class VoiceReply {
  const VoiceReply({
    this.tone,
    this.speak,
    this.stop = false,
    this.read,
    this.stopReading = false,
  });

  /// command | dictation | error
  final String? tone;
  final String? speak;
  final bool stop;

  /// Text to read aloud, in chunks; the recognizer listens between them.
  final List<String>? read;

  /// Stop reading aloud before doing anything else.
  final bool stopReading;

  VoiceReply _stoppingReading() => VoiceReply(
    tone: tone,
    speak: speak,
    stop: stop,
    read: read,
    stopReading: true,
  );

  Map<String, Object?> toJson() => {
    if (tone != null) 'tone': tone,
    if (speak != null) 'speak': speak,
    if (stop) 'stop': true,
    if (read != null) 'read': read,
    if (stopReading) 'stopReading': true,
  };
}

typedef VoiceTimerFactory = Timer Function(Duration, void Function());

/// Turns each utterance into one action on [surface].
class VoiceControl extends ChangeNotifier {
  VoiceControl({
    required this.surface,
    this.matcher = const VoiceCommandMatcher(),
    VoiceTimerFactory? timer,
    this.speak,
  }) : _timer = timer ?? Timer.new;

  static const confirmTimeout = Duration(seconds: 10);

  final VoiceSurface surface;
  final VoiceCommandMatcher matcher;
  final VoiceTimerFactory _timer;

  /// Speech outside a reply (the confirmation timing out).
  final void Function(String text)? speak;

  VoiceTarget? _pending;
  Timer? _pendingTimer;

  /// The last outcome, shown after "Voice:" in the Terminal tab.
  String statusLine = 'listening';

  /// The command waiting for "yes".
  VoiceTarget? get pending => _pending;

  VoiceReply handle(String utterance) {
    final heard = utterance.trim();
    if (heard.isEmpty) return const VoiceReply();
    final match = matcher.match(heard, surface.voiceTargets);
    final reply = _decide(heard, match);
    // Any command stops a reading first; dictation lets it carry on.
    final dictation = match is DictationMatch || reply.tone == 'dictation';
    return dictation ? reply : reply._stoppingReading();
  }

  VoiceReply _decide(String heard, VoiceMatch match) {
    final waiting = _pending;
    if (waiting != null) {
      if (match is YesMatch) {
        cancelPending();
        return _runTarget(heard, waiting, confirmed: true);
      }
      if (match is NoMatch) {
        cancelPending();
        return _status(
          "heard '$heard' — cancelled ${waiting.label}",
          const VoiceReply(tone: 'error', speak: 'Cancelled'),
        );
      }
      // Anything else cancels the question and is handled as itself.
      cancelPending();
    }

    if (match is StopListeningMatch) {
      return _status('stopped', const VoiceReply(tone: 'command', stop: true));
    }
    // Reading only looks at the tab's own screen: it needs no connection and
    // sends nothing, so it works while a macro runs too.
    if (match is StopReadingMatch) {
      return _status('stopped reading', const VoiceReply(tone: 'command'));
    }
    if (match is ReadMatch) return _read(match.target);
    if (!surface.voiceConnected) {
      return _status(
        "heard '$heard' — not connected",
        const VoiceReply(tone: 'error', speak: 'Not connected'),
      );
    }
    if (surface.voiceBusy) {
      return _status(
        "heard '$heard' — a macro is running",
        const VoiceReply(tone: 'error', speak: 'Macro running'),
      );
    }

    switch (match) {
      case TargetMatch(:final target):
        return _runTarget(heard, target);
      case SendMatch():
        if (surface.composerText.trim().isEmpty) {
          return _status(
            "heard '$heard' — nothing to send",
            const VoiceReply(tone: 'error', speak: 'Nothing to send'),
          );
        }
        if (!surface.submitComposer()) {
          return _status(
            "heard '$heard' — send is not available now",
            const VoiceReply(tone: 'error', speak: 'Cannot send now'),
          );
        }
        return _status(
          "heard '$heard' — sent",
          const VoiceReply(tone: 'command'),
        );
      case ComposerEditMatch(:final edit, :final count):
        switch (edit) {
          case ComposerEdit.clear:
            surface.clearComposer();
          case ComposerEdit.backspace:
            surface.composerBackspace(count);
          case ComposerEdit.deleteWords:
            surface.composerDeleteWords(count);
        }
        return _status(
          "heard '$heard' — Type command edited",
          const VoiceReply(tone: 'command'),
        );
      case YesMatch():
      case NoMatch():
      case DictationMatch():
        surface.appendDictation(heard);
        return _status(
          "heard '$heard' — added to Type command",
          const VoiceReply(tone: 'dictation'),
        );
      case StopListeningMatch():
      case StopReadingMatch():
      case ReadMatch():
        return const VoiceReply();
    }
  }

  static const _readingScreen = 'reading screen…';
  static const _readingReply = 'reading reply…';

  VoiceReply _read(ReadTarget target) {
    final lines = surface.terminalScreenLines;
    final reading = switch (target) {
      ReadTarget.screen => readScreen(lines),
      ReadTarget.reply => readReply(lines),
    };
    final chunks = speechChunks(reading.text);
    if (chunks.isEmpty) {
      return _status(
        'nothing to read',
        const VoiceReply(tone: 'error', speak: 'Nothing to read'),
      );
    }
    return _status(
      target == ReadTarget.screen ? _readingScreen : _readingReply,
      VoiceReply(tone: 'command', read: chunks),
    );
  }

  /// The phone finished (or gave up) reading aloud: finished | stopped |
  /// failed.
  void readingEnded(String reason) {
    if (statusLine != _readingScreen && statusLine != _readingReply) return;
    statusLine = switch (reason) {
      'finished' => 'finished reading',
      'failed' => 'could not read aloud',
      _ => 'stopped reading',
    };
    notifyListeners();
  }

  VoiceReply _runTarget(
    String heard,
    VoiceTarget target, {
    bool confirmed = false,
  }) {
    if (!surface.voiceConnected) {
      return _status(
        "heard '$heard' — not connected",
        const VoiceReply(tone: 'error', speak: 'Not connected'),
      );
    }
    if (!target.enabled) {
      return _status(
        "heard '$heard' — ${target.label} is switched off",
        VoiceReply(tone: 'error', speak: '${target.label} is off'),
      );
    }
    if (target.confirm && !confirmed) {
      _pending = target;
      _pendingTimer = _timer(confirmTimeout, _confirmTimedOut);
      return _status(
        "heard '$heard' — say yes to run ${target.label}",
        const VoiceReply(tone: 'command', speak: 'Say yes to confirm'),
      );
    }
    target.run();
    return _status(
      "heard '$heard' — ${target.label}",
      const VoiceReply(tone: 'command'),
    );
  }

  void _confirmTimedOut() {
    final waiting = _pending;
    _pending = null;
    _pendingTimer = null;
    if (waiting == null) return;
    statusLine = 'no answer — cancelled ${waiting.label}';
    notifyListeners();
    speak?.call('Cancelled');
  }

  void cancelPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  VoiceReply _status(String line, VoiceReply reply) {
    statusLine = line;
    notifyListeners();
    return reply;
  }

  void reset() {
    cancelPending();
    statusLine = 'listening';
    notifyListeners();
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }
}

/// The Terminal tab's "Voice control" toggle and the devota/voice_control
/// channel. While the toggle is off nothing asks for the service or the
/// recognizer, and any transcript that still arrives is answered with stop.
class VoiceControlSession extends ChangeNotifier {
  VoiceControlSession({
    required VoiceSurface surface,
    MethodChannel? channel,
    this.requestMicrophone,
    VoiceTimerFactory? timer,
  }) : _channel = channel ?? defaultChannel {
    control = VoiceControl(surface: surface, timer: timer, speak: _speak)
      ..addListener(_controlChanged);
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const defaultChannel = MethodChannel('devota/voice_control');

  final MethodChannel _channel;
  late final VoiceControl control;
  final Future<bool> Function()? requestMicrophone;

  bool _enabled = false;
  bool _starting = false;
  bool _disposed = false;
  String? _publishedStatus;

  /// Mutes the media stream while the recognizer restarts (its beep), only
  /// when nothing else is playing.
  bool quietBeeps = true;

  /// The native loop's state: Listening, Paused · call, Speaking, ...
  String? nativeState;

  /// Why voice control stopped or could not start.
  String? message;

  bool get enabled => _enabled;
  bool get starting => _starting;

  /// "Voice: heard 'page up' — Page Up", or why it stopped.
  String? get statusLine {
    if (_enabled) return 'Voice: ${control.statusLine}';
    if (message != null) return 'Voice: $message';
    return null;
  }

  Future<bool> setEnabled(bool on) async {
    if (_disposed) return false;
    if (!on) {
      final wasOn = _enabled;
      _enabled = false;
      _starting = false;
      nativeState = null;
      control.cancelPending();
      _changed();
      if (wasOn) await _invoke('stop');
      return true;
    }
    if (_enabled || _starting) return _enabled;
    _starting = true;
    message = null;
    _changed();
    try {
      final mic = await (requestMicrophone?.call() ?? Future.value(true));
      if (!mic) {
        message = 'microphone permission is needed';
        return false;
      }
      if (_disposed || !_starting) return false;
      control.reset();
      // On before the call so the first transcript is not refused.
      _enabled = true;
      _publishedStatus = control.statusLine;
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
      message = 'needs the Android app';
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
        // Toggle off: nothing is interpreted, and the service is told to stop.
        if (!_enabled || _disposed) return {'stop': true};
        final reply = control.handle(args['text']?.toString() ?? '');
        if (reply.stop) {
          _enabled = false;
          nativeState = null;
          message = 'stopped by voice';
          control.cancelPending();
          _changed();
        }
        return reply.toJson();
      case 'state':
        nativeState = args['state']?.toString();
        _changed();
        return null;
      case 'reading':
        if (args['active'] != true) {
          control.readingEnded(args['reason']?.toString() ?? 'stopped');
        }
        return null;
      case 'stopped':
        if (_enabled) {
          _enabled = false;
          nativeState = null;
          message = args['reason']?.toString();
          control.cancelPending();
          _changed();
        }
        return null;
    }
    throw MissingPluginException(call.method);
  }

  void _speak(String text) {
    if (_enabled) unawaited(_invoke('speak', {'text': text}));
  }

  void _controlChanged() {
    _changed();
    final status = control.statusLine;
    if (_enabled && status != _publishedStatus) {
      _publishedStatus = status;
      unawaited(_invoke('update', {'status': status}));
    }
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No Android side (tests, desktop).
    } on PlatformException {
      // Best effort; the service reports its own state.
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_enabled) unawaited(_invoke('stop'));
    _enabled = false;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    control.removeListener(_controlChanged);
    control.dispose();
    super.dispose();
  }
}
