import 'dart:async';

import 'package:flutter/services.dart';

import 'car_buttons.dart';
import 'car_controller.dart';

/// Receives native car events. Implemented by the car session owner.
abstract class CarEventSink {
  void onSignal(CarSignal signal, String source);
  void onDictationStopped(String reason);
  void onInterrupted(String reason);
  void onResumed();
  void onCarDevice(bool connected, String address, String name);
  void onCarModeStopped(String reason);
}

CarSignal? carSignalFromWire(String? name) => switch (name) {
  'next' => CarSignal.next,
  'previous' => CarSignal.previous,
  'play' => CarSignal.play,
  'pause' => CarSignal.pause,
  'playPause' => CarSignal.playPause,
  'playPauseDouble' => CarSignal.playPauseDouble,
  'playPauseLong' => CarSignal.playPauseLong,
  'voice' => CarSignal.voice,
  'voiceDouble' => CarSignal.voiceDouble,
  'answer' => CarSignal.answer,
  'hangUp' => CarSignal.hangUp,
  'redial' => CarSignal.redial,
  _ => null,
};

/// `devota/car` MethodChannel. Nothing calls it while the master switch is
/// off, so an app with car control disabled makes no native car calls.
class CarChannel implements CarPlatform {
  CarChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('devota/car');

  final MethodChannel _channel;
  CarEventSink? _sink;
  int _speechId = 0;
  final _speech = <String, Completer<bool>>{};

  void attach(CarEventSink sink) {
    _sink = sink;
    _channel.setMethodCallHandler(_onCall);
  }

  void detach() {
    _sink = null;
    _channel.setMethodCallHandler(null);
    for (final c in _speech.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _speech.clear();
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final args = call.arguments is Map
        ? Map<String, dynamic>.from(call.arguments as Map)
        : const <String, dynamic>{};
    final sink = _sink;
    switch (call.method) {
      case 'speechDone':
        _speech.remove(args['id']?.toString())?.complete(args['ok'] == true);
      case 'signal':
        final signal = carSignalFromWire(args['button']?.toString());
        if (signal != null) {
          sink?.onSignal(signal, args['source']?.toString() ?? '');
        }
      case 'dictationStopped':
        sink?.onDictationStopped(args['reason']?.toString() ?? '');
      case 'interrupted':
        sink?.onInterrupted(args['reason']?.toString() ?? '');
      case 'resumed':
        sink?.onResumed();
      case 'carDevice':
        sink?.onCarDevice(
          args['connected'] == true,
          args['address']?.toString() ?? '',
          args['name']?.toString() ?? '',
        );
      case 'carModeStopped':
        sink?.onCarModeStopped(args['reason']?.toString() ?? '');
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  // ---------------------------------------------------------- session control

  Future<Map<String, dynamic>> status() async {
    final raw = await _invoke<Map<Object?, Object?>>('status');
    return raw == null ? const {} : Map<String, dynamic>.from(raw);
  }

  Future<bool> startCarMode(String label, {bool withMic = true}) async =>
      await _invoke<bool>('startCarMode', {
        'label': label,
        'withMic': withMic,
      }) ??
      false;

  Future<void> stopCarMode() => _invoke<void>('stopCarMode');

  Future<void> setPressTiming({
    required bool playPauseDouble,
    required bool playPauseLong,
    required int doubleMs,
    required int longMs,
  }) => _invoke<void>('setPressTiming', {
    'playPauseDouble': playPauseDouble,
    'playPauseLong': playPauseLong,
    'doubleMs': doubleMs,
    'longMs': longMs,
  });

  Future<List<Map<String, String>>> bondedDevices() async {
    final raw = await _invoke<List<Object?>>('bondedDevices') ?? const [];
    return [
      for (final e in raw.whereType<Map>())
        {
          'address': e['address']?.toString() ?? '',
          'name': e['name']?.toString() ?? '',
        },
    ];
  }

  Future<void> setAutoDevice(String? address) =>
      _invoke<void>('setAutoDevice', {'address': address});

  /// The redial guard: whether Android lets DevOTA see outgoing calls, and
  /// the car redials of the stand-in number it cancelled (newest first).
  Future<CarRedialGuardStatus> redialGuardStatus() async {
    final raw = await _invoke<Map<Object?, Object?>>('redialGuardStatus');
    if (raw == null) return const CarRedialGuardStatus();
    return CarRedialGuardStatus(
      granted: raw['granted'] == true,
      number: raw['number']?.toString() ?? '',
      cancelled: (raw['cancelled'] as num?)?.toInt() ?? 0,
      recent: [
        for (final e in (raw['recent'] as List<Object?>? ?? const []))
          if (e is Map)
            (
              at: DateTime.fromMillisecondsSinceEpoch(
                (e['t'] as num?)?.toInt() ?? 0,
              ),
              number: e['number']?.toString() ?? '',
            ),
      ],
    );
  }

  /// Asks Android for the outgoing-call permission the redial guard needs.
  Future<void> requestRedialGuard() => _invoke<void>('requestRedialGuard');

  // --------------------------------------------------------------------- probe

  Future<bool> probeStart({String bvraOrder = 'none', bool speak = true}) async =>
      await _invoke<bool>('probeStart', {
        'bvraOrder': bvraOrder,
        'speak': speak,
      }) ??
      false;

  Future<void> probeStop() => _invoke<void>('probeStop');

  Future<Map<String, dynamic>> probePlaceTestCall() async {
    final raw = await _invoke<Map<Object?, Object?>>('probePlaceTestCall');
    return raw == null
        ? const {'ok': false, 'error': 'unavailable'}
        : Map<String, dynamic>.from(raw);
  }

  Future<void> probeEndTestCall() => _invoke<void>('probeEndTestCall');

  Future<List<Map<String, dynamic>>> probeLog({int limit = 500}) async {
    final raw =
        await _invoke<List<Object?>>('probeLog', {'limit': limit}) ?? const [];
    return [
      for (final e in raw.whereType<Map>()) Map<String, dynamic>.from(e),
    ];
  }

  Future<String?> probeExport() => _invoke<String>('probeExport');

  Future<void> probeClear() => _invoke<void>('probeClear');

  Future<bool> shareFile(String path, String mime) async =>
      await _invoke<bool>('shareFile', {'path': path, 'mime': mime}) ?? false;

  // --------------------------------------------------------------- CarPlatform

  @override
  Future<bool> speak(String text, {bool interrupt = true}) async {
    final id = 's${++_speechId}';
    final done = Completer<bool>();
    _speech[id] = done;
    final queued = await _invokeOk('speak', {
      'text': text,
      'id': id,
      'interrupt': interrupt,
    });
    if (!queued) {
      _speech.remove(id);
      return false;
    }
    // Never hang the state machine on a lost callback: allow ~0.5 s per word
    // plus synthesis time.
    final words = text.split(RegExp(r'\s+')).length;
    return done.future.timeout(
      Duration(seconds: 8 + words ~/ 2),
      onTimeout: () {
        _speech.remove(id);
        return false;
      },
    );
  }

  Future<bool> _invokeOk(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> stopSpeaking() => _invoke<void>('stopSpeaking');

  @override
  Future<void> earcon(String kind) => _invoke<void>('earcon', {'kind': kind});

  @override
  Future<CarStartResult> startDictation(
    String label, {
    int maxSeconds = 180,
  }) async {
    final raw = await _invoke<Map<Object?, Object?>>('startDictation', {
      'label': label,
      'maxSeconds': maxSeconds,
      'useCall': true,
    });
    if (raw == null) return const CarStartResult(false, error: 'unavailable');
    return CarStartResult(
      raw['ok'] == true,
      call: raw['call'] == true,
      error: raw['error']?.toString(),
    );
  }

  @override
  Future<int> stopDictation(String reason) async {
    final raw = await _invoke<Map<Object?, Object?>>('stopDictation', {
      'reason': reason,
    });
    return (raw?['durationMs'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Uint8List?> takeRecording() => _invoke<Uint8List>('takeRecording');

  @override
  Future<void> discardRecording() => _invoke<void>('discardRecording');

  bool? _canRecognizeRecording;

  /// Android 13+ only: earlier versions cannot feed a held recording to the
  /// phone's recognizer (the Corolla phone is Android 12).
  @override
  Future<bool> canRecognizeRecording() async {
    final known = _canRecognizeRecording;
    if (known != null) return known;
    final status = await this.status();
    final sdk = (status['sdk'] as num?)?.toInt() ?? 0;
    final can = sdk >= 33 && status['recognizerAvailable'] == true;
    if (status.isNotEmpty) _canRecognizeRecording = can;
    return can;
  }

  @override
  Future<String?> recognizeRecording() async {
    final raw = await _invoke<Map<Object?, Object?>>('recognizeRecording', {
      'language': 'en-US',
    });
    final text = raw?['text']?.toString();
    return text == null || text.trim().isEmpty ? null : text;
  }

  @override
  Future<CarStartResult> startCommandSession(String label) async {
    final raw = await _invoke<Map<Object?, Object?>>('startCommandSession', {
      'label': label,
    });
    if (raw == null) return const CarStartResult(false, error: 'unavailable');
    return CarStartResult(raw['ok'] == true, call: raw['call'] == true);
  }

  @override
  Future<void> endCommandSession() => _invoke<void>('endCommandSession');

  @override
  Future<CarListenResult> listenCommand(
    List<String> biasing, {
    int timeoutMs = 10000,
  }) async {
    final raw = await _invoke<Map<Object?, Object?>>('listenCommand', {
      'biasing': biasing,
      'timeoutMs': timeoutMs,
      'language': 'en-US',
    });
    if (raw == null) return const CarListenResult(error: 'unavailable');
    return CarListenResult(
      text: raw['text']?.toString(),
      error: raw['error']?.toString(),
    );
  }

  @override
  Future<void> cancelListening() => _invoke<void>('cancelListening');

  @override
  Future<void> claimButtons() => _invoke<void>('claimButtons');
}

class CarRedialGuardStatus {
  const CarRedialGuardStatus({
    this.granted = false,
    this.number = '',
    this.cancelled = 0,
    this.recent = const [],
  });
  final bool granted;

  /// The stand-in call's number, which the car stores and redials.
  final String number;
  final int cancelled;
  final List<({DateTime at, String number})> recent;
}
