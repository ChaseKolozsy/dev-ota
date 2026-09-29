import 'dart:async';

import 'package:flutter/foundation.dart';

import 'car_buttons.dart';
import 'car_channel.dart';
import 'car_controller.dart';
import 'car_settings.dart';

/// Owns car mode for the running app: settings, the native channel and the
/// state machine. While the master switch is off it makes no native car
/// calls at all (proposal §4.1: "behaves exactly as today").
class CarSession extends ChangeNotifier implements CarEventSink {
  CarSession({required this.target, CarChannel? channel, CarSettings? initial})
    : channel = channel ?? CarChannel(),
      _settings = initial ?? const CarSettings();

  final CarTarget target;
  final CarChannel channel;
  CarSettings _settings;
  CarSettings get settings => _settings;
  CarController? _controller;
  CarController? get controller => _controller;
  bool _running = false;
  bool get running => _running;
  bool _probing = false;
  bool get probing => _probing;
  String? message;

  /// Sends an exported probe log to the build host over SSH; returns the
  /// remote path. Set by the terminal tab (null when unavailable).
  Future<String> Function(String localPath)? sendProbeToHost;
  bool _loaded = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> init() async {
    _settings = await CarSettings.load();
    _loaded = true;
    if (_disposed) return;
    if (_settings.enabled) {
      channel.attach(this);
      if (_settings.autoDevice.isNotEmpty) {
        await channel.setAutoDevice(_settings.autoDevice);
      }
    }
    _notify();
  }

  /// Saves settings and applies what changed. Turning the master switch off
  /// stops car mode and the probe, forgets the auto-on device registration,
  /// and detaches the channel.
  Future<void> update(CarSettings next) async {
    final before = _settings;
    _settings = next;
    await next.save();
    _controller?.settings = next;
    if (before.enabled && !next.enabled) {
      await stopCarMode(reason: 'switch');
      await stopProbe();
      await channel.setAutoDevice(null);
      channel.detach();
    } else if (!before.enabled && next.enabled) {
      channel.attach(this);
    }
    if (next.enabled && before.autoDevice != next.autoDevice) {
      await channel.setAutoDevice(
        next.autoDevice.isEmpty ? null : next.autoDevice,
      );
    }
    if (_running &&
        (before.playPauseDouble != next.playPauseDouble ||
            before.playPauseLong != next.playPauseLong ||
            before.doublePressMs != next.doublePressMs ||
            before.longPressMs != next.longPressMs)) {
      await _applyTiming();
    }
    _notify();
  }

  Future<void> _applyTiming() => channel.setPressTiming(
    playPauseDouble: _settings.playPauseDouble,
    playPauseLong: _settings.playPauseLong,
    doubleMs: _settings.doublePressMs,
    longMs: _settings.longPressMs,
  );

  /// Starts car mode. [withMic] only when DevOTA is visible (a tap while
  /// parked, or the voice-button trampoline), per Android's background
  /// foreground-service rules.
  Future<bool> startCarMode({bool withMic = true}) async {
    if (!_loaded) await init();
    if (!_settings.enabled) {
      message = 'Turn on Car button control first.';
      _notify();
      return false;
    }
    if (!_settings.speechEnabled) {
      // Silence is never success (§12 S4).
      message = 'Car mode needs spoken feedback. Turn it on first.';
      _notify();
      return false;
    }
    if (_running) return true;
    if (_probing) await stopProbe();
    channel.attach(this);
    await _applyTiming();
    final started = await channel.startCarMode('DevOTA car mode', withMic: withMic);
    if (!started) {
      message = 'Android did not start car mode.';
      _notify();
      return false;
    }
    _running = true;
    message = null;
    final controller = CarController(
      platform: channel,
      target: target,
      settings: _settings,
      onCarModeOff: () => unawaited(stopCarMode(reason: 'voice')),
      onSettingsChanged: (next) {
        _settings = next;
        unawaited(next.save());
        _notify();
      },
    );
    _controller = controller;
    _notify();
    await controller.start();
    return true;
  }

  Future<void> stopCarMode({String reason = 'user'}) async {
    if (!_running) return;
    _running = false;
    final controller = _controller;
    _controller = null;
    await controller?.stop();
    controller?.dispose();
    await channel.stopCarMode();
    _notify();
  }

  Future<bool> startProbe({String bvraOrder = 'none'}) async {
    if (!_settings.enabled) {
      message = 'Turn on Car button control first.';
      _notify();
      return false;
    }
    if (_running) await stopCarMode(reason: 'probe');
    channel.attach(this);
    _probing = await channel.probeStart(bvraOrder: bvraOrder);
    message = _probing ? null : 'Android did not start the probe.';
    _notify();
    return _probing;
  }

  Future<void> stopProbe() async {
    if (!_probing) return;
    _probing = false;
    await channel.probeStop();
    _notify();
  }

  // ------------------------------------------------------------ CarEventSink

  @override
  void onSignal(CarSignal signal, String source) {
    final controller = _controller;
    if (!_running || controller == null) return;
    unawaited(controller.handleSignal(signal));
  }

  @override
  void onDictationStopped(String reason) {
    unawaited(_controller?.nativeDictationStopped(reason));
  }

  @override
  void onInterrupted(String reason) {
    unawaited(_controller?.interrupted(reason));
  }

  @override
  void onResumed() {
    unawaited(_controller?.resumed());
  }

  @override
  void onCarDevice(bool connected, String address, String name) {
    if (!_settings.enabled || address != _settings.autoDevice) return;
    if (connected) {
      // Started from the background: media session and speech only. The mic
      // part is upgraded by the first voice-button press (§3, F22).
      unawaited(startCarMode(withMic: false));
    } else {
      unawaited(stopCarMode(reason: 'car_disconnected'));
    }
  }

  @override
  void onCarModeStopped(String reason) {
    if (!_running) return;
    _running = false;
    final controller = _controller;
    _controller = null;
    unawaited(controller?.stop());
    controller?.dispose();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_running) unawaited(stopCarMode(reason: 'dispose'));
    if (_probing) unawaited(stopProbe());
    channel.detach();
    super.dispose();
  }
}
