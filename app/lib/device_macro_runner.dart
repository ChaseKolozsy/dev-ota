import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'device_macro_profile.dart';
import 'terminal_macro.dart';

const deviceMacroActions = <String>{
  'launchApp',
  'launchIntent',
  'tap',
  'tapImage',
  'longTap',
  'swipe',
  'typeText',
  'back',
  'home',
  'recents',
  'openSettings',
  'openUri',
  'screenshot',
  'uiDump',
  'tapUi',
  'assertUi',
  'assertDeviceProfile',
  'installBuild',
  'humanCheckpoint',
  'localHttpAssert',
};

class HumanCheckpointConfig {
  const HumanCheckpointConfig({
    required this.durationSeconds,
    required this.screenshotsPerSecond,
    required this.frameCount,
  });

  final double durationSeconds;
  final double screenshotsPerSecond;
  final int frameCount;

  factory HumanCheckpointConfig.fromArgs(Map<String, dynamic> args) {
    final duration = (args['durationSeconds'] as num?)?.toDouble() ?? 10;
    final rate = (args['screenshotsPerSecond'] as num?)?.toDouble() ?? 1;
    if (!duration.isFinite || duration <= 0 || duration > 120) {
      throw const FormatException(
        'durationSeconds must be greater than 0 and at most 120',
      );
    }
    if (!rate.isFinite || rate < 0.1 || rate > 5) {
      throw const FormatException('screenshotsPerSecond must be from 0.1 to 5');
    }
    final frames = (duration * rate).ceil();
    if (frames > 120) {
      throw const FormatException(
        'human checkpoint may capture at most 120 screenshots',
      );
    }
    return HumanCheckpointConfig(
      durationSeconds: duration,
      screenshotsPerSecond: rate,
      frameCount: frames,
    );
  }
}

class FailureDiagnosticsConfig {
  const FailureDiagnosticsConfig({
    required this.durationSeconds,
    required this.intervalSeconds,
    required this.captureScreenshot,
    required this.captureUi,
    required this.probes,
    required this.frameCount,
  });

  final double durationSeconds;
  final double intervalSeconds;
  final bool captureScreenshot;
  final bool captureUi;
  final List<Map<String, dynamic>> probes;
  final int frameCount;

  factory FailureDiagnosticsConfig.fromJson(Map<String, dynamic> json) {
    final duration = (json['durationSeconds'] as num?)?.toDouble() ?? 300;
    final interval = (json['intervalSeconds'] as num?)?.toDouble() ?? 30;
    if (!duration.isFinite || duration < 2 || duration > 3600) {
      throw const FormatException(
        'failureDiagnostics durationSeconds must be from 2 to 3600',
      );
    }
    if (!interval.isFinite || interval < 2 || interval > 300) {
      throw const FormatException(
        'failureDiagnostics intervalSeconds must be from 2 to 300',
      );
    }
    final frames = (duration / interval).floor() + 1;
    if (frames > 120) {
      throw const FormatException(
        'failureDiagnostics may capture at most 120 frames',
      );
    }
    final rawProbes = json['probes'];
    if (rawProbes != null && rawProbes is! List) {
      throw const FormatException('failureDiagnostics probes must be a list');
    }
    final probes = <Map<String, dynamic>>[];
    for (final raw in (rawProbes as List? ?? const [])) {
      if (raw is! Map) {
        throw const FormatException(
          'failureDiagnostics probe must be an object',
        );
      }
      final probe = Map<String, dynamic>.from(raw);
      final uri = Uri.tryParse(probe['url']?.toString() ?? '');
      if (uri == null ||
          uri.scheme != 'http' ||
          !const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.fragment.isNotEmpty) {
        throw const FormatException(
          'failureDiagnostics probe must use an http loopback URL',
        );
      }
      probes.add(probe);
    }
    if (probes.length > 8) {
      throw const FormatException(
        'failureDiagnostics permits at most 8 probes',
      );
    }
    final captureScreenshot = json['captureScreenshot'] != false;
    final captureUi = json['captureUi'] != false;
    if (!captureScreenshot && !captureUi && probes.isEmpty) {
      throw const FormatException(
        'failureDiagnostics must capture or probe something',
      );
    }
    return FailureDiagnosticsConfig(
      durationSeconds: duration,
      intervalSeconds: interval,
      captureScreenshot: captureScreenshot,
      captureUi: captureUi,
      probes: probes,
      frameCount: frames,
    );
  }
}

class DeviceMacroStepSpec {
  const DeviceMacroStepSpec({
    required this.action,
    required this.args,
    required this.expect,
    required this.capture,
    required this.allowError,
    this.label,
  });

  final String action;
  final Map<String, dynamic> args;
  final Map<String, dynamic> expect;
  final bool capture;
  final bool allowError;
  final String? label;

  factory DeviceMacroStepSpec.parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('device action must be a JSON object');
    }
    final json = Map<String, dynamic>.from(decoded);
    final action = json['action']?.toString().trim() ?? '';
    if (!deviceMacroActions.contains(action)) {
      throw FormatException('unsupported device macro action: $action');
    }
    final rawArgs = json['args'];
    final rawExpect = json['expect'];
    return DeviceMacroStepSpec(
      action: action,
      args: rawArgs is Map ? Map<String, dynamic>.from(rawArgs) : {},
      expect: rawExpect is Map ? Map<String, dynamic>.from(rawExpect) : {},
      capture: json['capture'] != false,
      allowError: json['allowError'] == true,
      label: json['label']?.toString(),
    );
  }
}

class DeviceMacroEvidence {
  const DeviceMacroEvidence({
    required this.stepIndex,
    required this.stepCount,
    required this.stepId,
    required this.name,
    required this.action,
    required this.startedAt,
    required this.completedAt,
    required this.actionResult,
    required this.screenshot,
    required this.ui,
    this.actionError,
    this.frameIndex,
    this.frameCount,
    this.capturedAt,
  });

  final int stepIndex;
  final int stepCount;
  final String stepId;
  final String name;
  final String action;
  final DateTime startedAt;
  final DateTime completedAt;
  final Map<String, dynamic>? actionResult;
  final String? actionError;
  final Map<String, dynamic>? screenshot;
  final Map<String, dynamic>? ui;
  final int? frameIndex;
  final int? frameCount;
  final DateTime? capturedAt;

  Map<String, dynamic> toJson({bool includeScreenshotBytes = true}) {
    final screenshotJson = screenshot == null
        ? null
        : Map<String, dynamic>.from(screenshot!);
    if (!includeScreenshotBytes) screenshotJson?.remove('pngBase64');
    return {
      'stepIndex': stepIndex,
      'stepCount': stepCount,
      'stepId': stepId,
      'name': name,
      'action': action,
      if (frameIndex != null) 'frameIndex': frameIndex,
      if (frameCount != null) 'frameCount': frameCount,
      if (capturedAt != null)
        'capturedAt': capturedAt!.toUtc().toIso8601String(),
      'startedAt': startedAt.toUtc().toIso8601String(),
      'completedAt': completedAt.toUtc().toIso8601String(),
      'actionResult': actionResult,
      if (actionError != null) 'actionError': actionError,
      'screenshot': screenshotJson,
      'ui': ui,
    };
  }
}

/// Persists one evidence record locally. Implementations must not perform
/// network delivery inline because that would couple macro timing to the
/// quality of the phone's current connection.
typedef DeviceMacroEvidenceSink =
    Future<void> Function(DeviceMacroEvidence evidence);
typedef DeviceMacroInstallBuild =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> args);
typedef DeviceMacroLocalHttpAssert =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> args, {
      Future<void> Function(Map<String, dynamic> attempt)? onAttempt,
    });

class DeviceMacroRunner {
  DeviceMacroRunner({
    required MethodChannel channel,
    required DeviceMacroEvidenceSink evidenceSink,
    required DeviceMacroInstallBuild installBuild,
    required DeviceMacroLocalHttpAssert localHttpAssert,
    void Function(int stepIndex, int stepCount, String label)? onProgress,
    bool Function()? shouldStop,
    Future<void> Function(Duration duration)? diagnosticDelay,
  }) : _channel = channel,
       _evidenceSink = evidenceSink,
       _installBuild = installBuild,
       _localHttpAssert = localHttpAssert,
       _onProgress = onProgress,
       _shouldStop = shouldStop,
       _diagnosticDelay = diagnosticDelay ?? Future<void>.delayed;

  final MethodChannel _channel;
  final DeviceMacroEvidenceSink _evidenceSink;
  final DeviceMacroInstallBuild _installBuild;
  final DeviceMacroLocalHttpAssert _localHttpAssert;
  final void Function(int stepIndex, int stepCount, String label)? _onProgress;
  final bool Function()? _shouldStop;
  final Future<void> Function(Duration duration) _diagnosticDelay;
  final Stopwatch _screenshotClock = Stopwatch()..start();
  Duration? _lastScreenshotAttempt;

  static const _screenshotCooldown = Duration(milliseconds: 1200);

  Future<Map<String, dynamic>> _takeScreenshot() async {
    final lastAttempt = _lastScreenshotAttempt;
    if (lastAttempt != null) {
      final elapsed = _screenshotClock.elapsed - lastAttempt;
      if (elapsed < _screenshotCooldown) {
        await _diagnosticDelay(_screenshotCooldown - elapsed);
      }
    }
    // Record attempts, not just successes. Android rate-limits accessibility
    // screenshots even when the preceding request returned errorCode=3.
    _lastScreenshotAttempt = _screenshotClock.elapsed;
    return _invoke('screenshot');
  }

  Future<List<DeviceMacroEvidence>> run(TerminalMacro macro) async {
    if (!macro.isDeviceMacro) {
      throw StateError('macro has no device-action steps');
    }
    final evidence = <DeviceMacroEvidence>[];
    try {
      for (var offset = 0; offset < macro.steps.length; offset++) {
        if (_shouldStop?.call() == true) break;
        final step = macro.steps[offset];
        if (step.type == TerminalMacroStepType.wait) {
          _onProgress?.call(offset + 1, macro.steps.length, 'wait');
          final startedAt = DateTime.now();
          await _delay(step.delaySeconds);
          final record = DeviceMacroEvidence(
            stepIndex: offset + 1,
            stepCount: macro.steps.length,
            stepId: step.id,
            name: 'wait',
            action: 'wait',
            startedAt: startedAt,
            completedAt: DateTime.now(),
            actionResult: const {'ok': true},
            screenshot: await _takeScreenshot(),
            ui: await _invoke('uiDump'),
          );
          evidence.add(record);
          await _evidenceSink(record);
          continue;
        }
        if (step.type != TerminalMacroStepType.device) {
          throw StateError(
            'device macros may contain only Device action and Wait steps; '
            'step ${offset + 1} is ${step.type.name}',
          );
        }
        final spec = DeviceMacroStepSpec.parse(step.value);
        final label = spec.label?.trim().isNotEmpty == true
            ? spec.label!.trim()
            : spec.action;
        _onProgress?.call(offset + 1, macro.steps.length, label);
        if (spec.action == 'humanCheckpoint') {
          final records = await _runHumanCheckpoint(
            spec: spec,
            step: step,
            stepIndex: offset + 1,
            stepCount: macro.steps.length,
            label: label,
          );
          evidence.addAll(records);
          continue;
        }
        if (spec.action == 'localHttpAssert' &&
            spec.args.containsKey('captureIntervalSeconds')) {
          final records = await _runLocalHttpAssertWithFrames(
            spec: spec,
            step: step,
            stepIndex: offset + 1,
            stepCount: macro.steps.length,
            label: label,
          );
          evidence.addAll(records);
          continue;
        }
        final startedAt = DateTime.now();
        Map<String, dynamic>? actionResult;
        String? actionError;
        try {
          actionResult = await _execute(spec);
        } catch (error) {
          actionError = error.toString();
        }
        if (step.delaySeconds > 0) await _delay(step.delaySeconds);

        Map<String, dynamic>? screenshot;
        Map<String, dynamic>? ui;
        if (spec.capture || spec.expect.isNotEmpty) {
          screenshot = await _takeScreenshot();
          ui = await _invoke('uiDump');
          try {
            assertDeviceMacroExpectations(spec.expect, ui, actionError);
          } catch (error) {
            actionError = actionError == null
                ? error.toString()
                : '$actionError; expectation failed: $error';
          }
        }
        final record = DeviceMacroEvidence(
          stepIndex: offset + 1,
          stepCount: macro.steps.length,
          stepId: step.id,
          name: label,
          action: spec.action,
          startedAt: startedAt,
          completedAt: DateTime.now(),
          actionResult: actionResult,
          actionError: actionError,
          screenshot: screenshot,
          ui: ui,
        );
        evidence.add(record);
        await _evidenceSink(record);
        if (actionError != null && !spec.allowError) {
          throw StateError('$label failed: $actionError');
        }
      }
      return evidence;
    } catch (error, stackTrace) {
      final rawDiagnostics = macro.failureDiagnostics;
      if (rawDiagnostics != null && _shouldStop?.call() != true) {
        try {
          evidence.addAll(
            await _runFailureDiagnostics(
              macro: macro,
              config: FailureDiagnosticsConfig.fromJson(rawDiagnostics),
              originalError: error,
            ),
          );
        } catch (_) {
          // The original macro failure remains authoritative. Diagnostic
          // collection is deliberately best-effort and may never replace it.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<List<DeviceMacroEvidence>> _runFailureDiagnostics({
    required TerminalMacro macro,
    required FailureDiagnosticsConfig config,
    required Object originalError,
  }) async {
    final records = <DeviceMacroEvidence>[];
    final startedAt = DateTime.now();
    // The failed step normally captured a screenshot immediately before this
    // tail. Respect Android's screenshot cooldown before the first frame.
    await _diagnosticDelay(const Duration(milliseconds: 1200));
    for (var frame = 0; frame < config.frameCount; frame++) {
      if (_shouldStop?.call() == true) break;
      if (frame > 0) {
        await _diagnosticDelay(
          Duration(milliseconds: (config.intervalSeconds * 1000).round()),
        );
      }
      _onProgress?.call(
        macro.steps.length + 1,
        macro.steps.length + 1,
        'failure diagnostics ${frame + 1}/${config.frameCount}',
      );
      final probes = <Map<String, dynamic>>[];
      for (final probe in config.probes) {
        try {
          probes.add({
            'url': probe['url'],
            'ok': true,
            'result': await _localHttpAssert({
              ...probe,
              'retryUntilSeconds': 0,
            }),
          });
        } catch (error) {
          probes.add({
            'url': probe['url'],
            'ok': false,
            'error': error.toString(),
          });
        }
      }
      Map<String, dynamic>? screenshot;
      Map<String, dynamic>? ui;
      String? screenshotError;
      String? uiError;
      if (config.captureScreenshot) {
        try {
          screenshot = await _takeScreenshot();
        } catch (error) {
          screenshotError = error.toString();
        }
      }
      if (config.captureUi) {
        try {
          ui = await _invoke('uiDump');
        } catch (error) {
          uiError = error.toString();
        }
      }
      final record = DeviceMacroEvidence(
        stepIndex: macro.steps.length + 1,
        stepCount: macro.steps.length + 1,
        stepId: 'failure-diagnostics',
        name: 'Failure diagnostics — frame ${frame + 1}',
        action: 'failureDiagnostics',
        startedAt: startedAt,
        completedAt: DateTime.now(),
        actionResult: {
          'originalError': originalError.toString(),
          'probes': probes,
          'screenshotError': ?screenshotError,
          'uiError': ?uiError,
        },
        actionError: originalError.toString(),
        screenshot: screenshot,
        ui: ui,
        frameIndex: frame + 1,
        frameCount: config.frameCount,
        capturedAt: DateTime.now(),
      );
      records.add(record);
      await _evidenceSink(record);
    }
    return records;
  }

  Future<Map<String, dynamic>> _execute(DeviceMacroStepSpec spec) async {
    switch (spec.action) {
      case 'tapUi':
        final selector = spec.args['selector'];
        if (selector is! Map) {
          throw const FormatException('tapUi args.selector must be an object');
        }
        if (spec.args['selectorPrecheck'] == false) {
          return _invoke('tapUi', {
            'selector': Map<String, dynamic>.from(selector),
            if (spec.args['packageName'] != null)
              'packageName': spec.args['packageName'],
          });
        }
        final ui = await _invoke('uiDump');
        final matches = matchDeviceUiNodes(
          ui,
          Map<String, dynamic>.from(selector),
        );
        if (matches.length != 1) {
          final fallback = spec.args['imageFallback'];
          if (fallback is Map) {
            return _invoke('tapImage', {
              'template': Map<String, dynamic>.from(fallback),
              if (spec.args['packageName'] != null)
                'packageName': spec.args['packageName'],
            });
          }
          throw StateError(
            'tapUi expected exactly one match, found ${matches.length}',
          );
        }
        return _invoke('tapUi', {
          'selector': Map<String, dynamic>.from(selector),
          if (spec.args['packageName'] != null)
            'packageName': spec.args['packageName'],
        });
      case 'assertUi':
        final ui = await _invoke('uiDump');
        assertDeviceMacroExpectations(spec.expect, ui, null);
        return {'ok': true};
      case 'assertDeviceProfile':
        final observed = await _invoke('deviceProfile');
        assertDeviceMacroProfile(spec.args, observed);
        return {
          'ok': true,
          'profile': spec.args['profile'],
          'observed': observed,
        };
      case 'installBuild':
        return _installBuild(spec.args);
      case 'localHttpAssert':
        return _localHttpAssert(spec.args);
      default:
        return _invoke(
          spec.action,
          await _resolveNormalizedGestureArgs(spec.action, spec.args),
        );
    }
  }

  Future<Map<String, dynamic>> _resolveNormalizedGestureArgs(
    String action,
    Map<String, dynamic> args,
  ) async {
    final axes = switch (action) {
      'tap' || 'longTap' => const {'x': 'widthPx', 'y': 'heightPx'},
      'swipe' => const {
        'x1': 'widthPx',
        'y1': 'heightPx',
        'x2': 'widthPx',
        'y2': 'heightPx',
      },
      _ => const <String, String>{},
    };
    if (axes.isEmpty ||
        !axes.keys.any((axis) => args.containsKey('${axis}Normalized'))) {
      return args;
    }
    if (!axes.keys.every((axis) => args.containsKey('${axis}Normalized'))) {
      throw FormatException(
        '$action normalized coordinates must provide ${axes.keys.map((axis) => '${axis}Normalized').join(', ')}',
      );
    }
    final profile = await _invoke('deviceProfile');
    final resolved = Map<String, dynamic>.from(args);
    for (final entry in axes.entries) {
      final key = '${entry.key}Normalized';
      final normalized = (args[key] as num?)?.toDouble();
      final extent = (profile[entry.value] as num?)?.toDouble();
      if (normalized == null ||
          !normalized.isFinite ||
          normalized < 0 ||
          normalized > 1 ||
          extent == null ||
          !extent.isFinite ||
          extent <= 0) {
        throw FormatException('invalid $key or device ${entry.value}');
      }
      resolved[entry.key] = normalized * extent;
      resolved.remove(key);
    }
    return resolved;
  }

  Future<List<DeviceMacroEvidence>> _runLocalHttpAssertWithFrames({
    required DeviceMacroStepSpec spec,
    required TerminalMacroStep step,
    required int stepIndex,
    required int stepCount,
    required String label,
  }) async {
    final captureIntervalSeconds =
        (spec.args['captureIntervalSeconds'] as num?)?.toDouble() ?? 0;
    if (!captureIntervalSeconds.isFinite ||
        captureIntervalSeconds < 2 ||
        captureIntervalSeconds > 300) {
      throw const FormatException(
        'localHttpAssert captureIntervalSeconds must be from 2 to 300',
      );
    }
    final retryUntilSeconds =
        (spec.args['retryUntilSeconds'] as num?)?.toDouble() ?? 0;
    if (retryUntilSeconds > 0 &&
        (retryUntilSeconds / captureIntervalSeconds).ceil() + 1 > 120) {
      throw const FormatException(
        'localHttpAssert may capture at most 120 polling screenshots',
      );
    }

    final records = <DeviceMacroEvidence>[];
    final actionStartedAt = DateTime.now();
    final watch = Stopwatch()..start();
    var nextCapture = Duration.zero;
    DateTime? lastCaptureAt;
    Map<String, dynamic>? actionResult;
    String? actionError;
    try {
      // Android's accessibility screenshot API rejects back-to-back captures
      // with errorCode=3. The preceding macro step normally captured its
      // final screen moments before this poll began, so leave one measured
      // screenshot cooldown before the first polling frame.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      actionResult = await _localHttpAssert(
        spec.args,
        onAttempt: (attempt) async {
          if (_shouldStop?.call() == true) {
            throw StateError('macro stopped during local HTTP poll');
          }
          if (watch.elapsed < nextCapture) return;
          final capturedAt = DateTime.now();
          Map<String, dynamic>? screenshot;
          Map<String, dynamic>? ui;
          String? evidenceCaptureError;
          try {
            screenshot = await _takeScreenshot();
            ui = await _invoke('uiDump');
          } catch (error) {
            // Evidence frames are periodic observations, not the assertion
            // itself. Android can transiently reject an accessibility
            // screenshot while a memory-heavy install is in progress. Keep
            // polling and record the missed frame; the final capture below
            // remains mandatory, and any successfully captured UI still has
            // to satisfy every expectation.
            evidenceCaptureError = error.toString();
          }
          if (ui != null) {
            assertDeviceMacroExpectations(spec.expect, ui, null);
          }
          final record = DeviceMacroEvidence(
            stepIndex: stepIndex,
            stepCount: stepCount,
            stepId: step.id,
            name: '$label — poll frame ${records.length + 1}',
            action: spec.action,
            startedAt: actionStartedAt,
            completedAt: DateTime.now(),
            actionResult: {
              ...attempt,
              'evidenceCaptureError': ?evidenceCaptureError,
            },
            screenshot: screenshot,
            ui: ui,
            frameIndex: records.length + 1,
            capturedAt: capturedAt,
          );
          records.add(record);
          await _evidenceSink(record);
          lastCaptureAt = capturedAt;
          nextCapture =
              watch.elapsed +
              Duration(milliseconds: (captureIntervalSeconds * 1000).round());
        },
      );
    } catch (error) {
      actionError = error.toString();
    }

    final sinceLastCapture = lastCaptureAt == null
        ? const Duration(seconds: 2)
        : DateTime.now().difference(lastCaptureAt!);
    if (sinceLastCapture < const Duration(milliseconds: 1200)) {
      await Future<void>.delayed(
        const Duration(milliseconds: 1200) - sinceLastCapture,
      );
    }
    if (step.delaySeconds > 0) await _delay(step.delaySeconds);
    final screenshot = await _takeScreenshot();
    final ui = await _invoke('uiDump');
    assertDeviceMacroExpectations(spec.expect, ui, actionError);
    final finalRecord = DeviceMacroEvidence(
      stepIndex: stepIndex,
      stepCount: stepCount,
      stepId: step.id,
      name: '$label — final',
      action: spec.action,
      startedAt: actionStartedAt,
      completedAt: DateTime.now(),
      actionResult: actionResult,
      actionError: actionError,
      screenshot: screenshot,
      ui: ui,
      frameIndex: records.length + 1,
      capturedAt: DateTime.now(),
    );
    records.add(finalRecord);
    await _evidenceSink(finalRecord);
    watch.stop();
    if (actionError != null && !spec.allowError) {
      throw StateError('$label failed: $actionError');
    }
    return records;
  }

  Future<List<DeviceMacroEvidence>> _runHumanCheckpoint({
    required DeviceMacroStepSpec spec,
    required TerminalMacroStep step,
    required int stepIndex,
    required int stepCount,
    required String label,
  }) async {
    final config = HumanCheckpointConfig.fromArgs(spec.args);
    final actionStartedAt = DateTime.now();
    Map<String, dynamic> actionResult;
    try {
      actionResult = await _invoke('humanCheckpoint', spec.args);
    } catch (error) {
      final record = DeviceMacroEvidence(
        stepIndex: stepIndex,
        stepCount: stepCount,
        stepId: step.id,
        name: label,
        action: spec.action,
        startedAt: actionStartedAt,
        completedAt: DateTime.now(),
        actionResult: null,
        actionError: error.toString(),
        screenshot: await _takeScreenshot(),
        ui: await _invoke('uiDump'),
      );
      await _evidenceSink(record);
      throw StateError('$label failed: $error');
    }

    final records = <DeviceMacroEvidence>[];
    final stopwatch = Stopwatch()..start();
    final intervalMicros =
        (Duration.microsecondsPerSecond / config.screenshotsPerSecond).round();
    for (var offset = 0; offset < config.frameCount; offset++) {
      if (_shouldStop?.call() == true) break;
      final target = Duration(microseconds: intervalMicros * offset);
      final remaining = target - stopwatch.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      final capturedAt = DateTime.now();
      final screenshot = await _takeScreenshot();
      final captureUi = offset == 0 || offset == config.frameCount - 1;
      final ui = captureUi ? await _invoke('uiDump') : null;
      final record = DeviceMacroEvidence(
        stepIndex: stepIndex,
        stepCount: stepCount,
        stepId: step.id,
        name: '$label — frame ${offset + 1} of ${config.frameCount}',
        action: spec.action,
        startedAt: actionStartedAt,
        completedAt: DateTime.now(),
        actionResult: {
          ...actionResult,
          'durationSeconds': config.durationSeconds,
          'screenshotsPerSecond': config.screenshotsPerSecond,
        },
        screenshot: screenshot,
        ui: ui,
        frameIndex: offset + 1,
        frameCount: config.frameCount,
        capturedAt: capturedAt,
      );
      records.add(record);
      // Persist each frame immediately. The production sink writes first to
      // the app-private outbox, then attempts delivery asynchronously without
      // coupling network latency to local capture cadence.
      await _evidenceSink(record);
    }
    stopwatch.stop();
    final finalUi = records.isNotEmpty && records.last.ui != null
        ? records.last.ui!
        : await _invoke('uiDump');
    assertDeviceMacroExpectations(spec.expect, finalUi, null);
    return records;
  }

  Future<Map<String, dynamic>> _invoke(
    String action, [
    Map<String, dynamic> args = const {},
  ]) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'runDeviceAction',
      {'action': action, 'args': args},
    );
    return value == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(value);
  }

  Future<void> _delay(double seconds) async {
    var remaining = Duration(milliseconds: (seconds * 1000).round());
    while (remaining > Duration.zero && _shouldStop?.call() != true) {
      final slice = remaining > const Duration(milliseconds: 200)
          ? const Duration(milliseconds: 200)
          : remaining;
      await Future<void>.delayed(slice);
      remaining -= slice;
    }
  }
}

List<Map<String, dynamic>> matchDeviceUiNodes(
  Map<String, dynamic> ui,
  Map<String, dynamic> selector,
) {
  final rawNodes = ui['nodes'];
  if (rawNodes is! List) return const [];
  final nodes = rawNodes
      .whereType<Map>()
      .map((node) => Map<String, dynamic>.from(node))
      .toList();
  final screenRight = nodes
      .map((node) => node['bounds'])
      .whereType<Map>()
      .map((bounds) => (bounds['right'] as num?)?.toDouble() ?? 0)
      .fold<double>(0, math.max);
  final screenBottom = nodes
      .map((node) => node['bounds'])
      .whereType<Map>()
      .map((bounds) => (bounds['bottom'] as num?)?.toDouble() ?? 0)
      .fold<double>(0, math.max);
  return nodes.where((node) {
    for (final key in const [
      'text',
      'contentDescription',
      'resourceId',
      'className',
    ]) {
      final expected = selector[key];
      if (expected != null) {
        final actual = node[key]?.toString().toLowerCase() ?? '';
        if (!actual.contains(expected.toString().toLowerCase())) {
          return false;
        }
      }
    }
    for (final entry in const {
      'textExact': 'text',
      'contentDescriptionExact': 'contentDescription',
      'resourceIdExact': 'resourceId',
      'classNameExact': 'className',
    }.entries) {
      final expected = selector[entry.key];
      if (expected != null) {
        final actual = node[entry.value]?.toString().toLowerCase() ?? '';
        if (actual != expected.toString().toLowerCase()) return false;
      }
    }
    if (selector['visibleOnly'] != false) {
      final bounds = node['bounds'];
      if (bounds is! Map) return false;
      final left = (bounds['left'] as num?)?.toDouble() ?? 0;
      final right = (bounds['right'] as num?)?.toDouble() ?? 0;
      final top = (bounds['top'] as num?)?.toDouble() ?? 0;
      final bottom = (bounds['bottom'] as num?)?.toDouble() ?? 0;
      if (right <= left || bottom <= top) return false;
    }
    final centerRegion = selector['centerRegion'];
    if (centerRegion != null) {
      if (centerRegion is! Map || screenRight <= 0 || screenBottom <= 0) {
        return false;
      }
      final bounds = node['bounds'];
      if (bounds is! Map) return false;
      final left = (bounds['left'] as num?)?.toDouble();
      final right = (bounds['right'] as num?)?.toDouble();
      final top = (bounds['top'] as num?)?.toDouble();
      final bottom = (bounds['bottom'] as num?)?.toDouble();
      final regionLeft = (centerRegion['left'] as num?)?.toDouble();
      final regionRight = (centerRegion['right'] as num?)?.toDouble();
      final regionTop = (centerRegion['top'] as num?)?.toDouble();
      final regionBottom = (centerRegion['bottom'] as num?)?.toDouble();
      if (left == null ||
          right == null ||
          top == null ||
          bottom == null ||
          regionLeft == null ||
          regionRight == null ||
          regionTop == null ||
          regionBottom == null ||
          !regionLeft.isFinite ||
          !regionRight.isFinite ||
          !regionTop.isFinite ||
          !regionBottom.isFinite ||
          regionLeft < 0 ||
          regionTop < 0 ||
          regionRight > 1 ||
          regionBottom > 1 ||
          regionRight <= regionLeft ||
          regionBottom <= regionTop) {
        return false;
      }
      final centerX = ((left + right) / 2) / screenRight;
      final centerY = ((top + bottom) / 2) / screenBottom;
      if (centerX < regionLeft ||
          centerX > regionRight ||
          centerY < regionTop ||
          centerY > regionBottom) {
        return false;
      }
    }
    return true;
  }).toList();
}

void assertDeviceMacroExpectations(
  Map<String, dynamic> expected,
  Map<String, dynamic> ui,
  String? actionError,
) {
  if (expected['error'] == true && actionError == null) {
    throw StateError('expected the device action to fail');
  }
  if (expected['error'] == false && actionError != null) {
    throw StateError('device action failed: $actionError');
  }
  final activePackage = expected['activePackage']?.toString();
  if (activePackage != null &&
      ui['activePackage']?.toString() != activePackage) {
    throw StateError(
      'expected active package $activePackage, got ${ui['activePackage']}',
    );
  }
  final visible = (ui['nodes'] is List ? ui['nodes'] as List : const [])
      .whereType<Map>()
      .expand((node) => [node['text'], node['contentDescription']])
      .whereType<Object>()
      .map((value) => value.toString())
      .join('\n')
      .toLowerCase();
  for (final text
      in (expected['textIncludes'] is List
          ? expected['textIncludes'] as List
          : const [])) {
    if (!visible.contains(text.toString().toLowerCase())) {
      throw StateError('UI did not include ${jsonEncode(text.toString())}');
    }
  }
  for (final text
      in (expected['textExcludes'] is List
          ? expected['textExcludes'] as List
          : const [])) {
    if (visible.contains(text.toString().toLowerCase())) {
      throw StateError(
        'UI unexpectedly included ${jsonEncode(text.toString())}',
      );
    }
  }
}
