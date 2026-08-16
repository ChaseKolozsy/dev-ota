import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef DeviceMacroOutboxSender =
    Future<void> Function(String url, Map<String, dynamic> payload);

/// Durable, app-private delivery queue for device-macro evidence.
///
/// A macro is executed and captured locally. Network delivery is deliberately
/// separate: weak or absent ZeroTier connectivity must not change screenshot
/// cadence or turn a successful local test into a failed test. Each run keeps
/// its step records until the server acknowledges them, and completion is sent
/// only after every queued step for that run has been acknowledged.
class DeviceMacroEvidenceOutbox {
  DeviceMacroEvidenceOutbox({
    required Future<Directory> Function() rootDirectory,
    required DeviceMacroOutboxSender sender,
  }) : _rootDirectory = rootDirectory,
       _sender = sender;

  final Future<Directory> Function() _rootDirectory;
  final DeviceMacroOutboxSender _sender;
  Future<void>? _flushFuture;
  bool _flushRequested = false;

  Future<void> enqueueStep({
    required String runId,
    required String baseUrl,
    required Map<String, dynamic> payload,
  }) async {
    final stepIndex = payload['stepIndex'];
    if (stepIndex is! int || stepIndex < 1) {
      throw ArgumentError.value(stepIndex, 'stepIndex');
    }
    final frameIndex = payload['frameIndex'];
    if (frameIndex != null && (frameIndex is! int || frameIndex < 1)) {
      throw ArgumentError.value(frameIndex, 'frameIndex');
    }
    final suffix = frameIndex == null
        ? ''
        : '-frame-${frameIndex.toString().padLeft(4, '0')}';
    final filename = 'step-${stepIndex.toString().padLeft(4, '0')}$suffix.json';
    await _writeRecord(
      runId: runId,
      filename: filename,
      record: {
        'version': 1,
        'kind': 'step',
        'baseUrl': _normalizeBaseUrl(baseUrl),
        'payload': payload,
      },
    );
  }

  Future<void> enqueueCompletion({
    required String runId,
    required String baseUrl,
    required Map<String, dynamic> payload,
  }) {
    return _writeRecord(
      runId: runId,
      filename: 'complete.json',
      record: {
        'version': 1,
        'kind': 'complete',
        'baseUrl': _normalizeBaseUrl(baseUrl),
        'payload': payload,
      },
    );
  }

  Future<int> pendingRecordCount() async {
    final root = await _ensureRoot();
    var count = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) count++;
    }
    return count;
  }

  /// Attempts all currently queued deliveries and stops at the first network
  /// failure. Failures intentionally remain queued for the next resume/refresh.
  Future<void> flush() {
    _flushRequested = true;
    final active = _flushFuture;
    if (active != null) return active;
    final future = _flushLoop();
    _flushFuture = future;
    return future.whenComplete(() {
      _flushFuture = null;
    });
  }

  Future<void> _flushLoop() async {
    while (_flushRequested) {
      _flushRequested = false;
      final delivered = await _flushOnce();
      if (!delivered) return;
    }
  }

  Future<bool> _flushOnce() async {
    final root = await _ensureRoot();
    final runDirs = await root
        .list(followLinks: false)
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    runDirs.sort((a, b) => a.path.compareTo(b.path));
    for (final runDir in runDirs) {
      final runId = _basename(runDir.path);
      final steps = await runDir
          .list(followLinks: false)
          .where(
            (entity) =>
                entity is File &&
                _basename(entity.path).startsWith('step-') &&
                entity.path.endsWith('.json'),
          )
          .cast<File>()
          .toList();
      steps.sort((a, b) => a.path.compareTo(b.path));
      for (final step in steps) {
        if (!await _deliver(runId, step)) return false;
      }

      final completion = File('${runDir.path}/complete.json');
      if (await completion.exists()) {
        // Re-read after delivering steps so a concurrently queued frame cannot
        // be overtaken by the completion marker.
        final remainingSteps = await runDir
            .list(followLinks: false)
            .where(
              (entity) =>
                  entity is File &&
                  _basename(entity.path).startsWith('step-') &&
                  entity.path.endsWith('.json'),
            )
            .isEmpty;
        if (remainingSteps && !await _deliver(runId, completion)) return false;
      }
      if (await runDir.exists() && await runDir.list().isEmpty) {
        await runDir.delete();
      }
    }
    return true;
  }

  Future<bool> _deliver(String runId, File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return false;
      final record = Map<String, dynamic>.from(decoded);
      final baseUrl = record['baseUrl']?.toString() ?? '';
      final payloadValue = record['payload'];
      if (baseUrl.isEmpty || payloadValue is! Map) return false;
      final payload = Map<String, dynamic>.from(payloadValue);
      final kind = record['kind'];
      final endpoint = kind == 'step'
          ? '$baseUrl/macro-runs/$runId/steps'
          : kind == 'complete'
          ? '$baseUrl/macro-runs/$runId/complete'
          : null;
      if (endpoint == null) return false;
      await _sender(endpoint, payload);
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeRecord({
    required String runId,
    required String filename,
    required Map<String, dynamic> record,
  }) async {
    final safeRunId = _safeRunId(runId);
    final root = await _ensureRoot();
    final runDir = Directory('${root.path}/$safeRunId');
    await runDir.create(recursive: true);
    final destination = File('${runDir.path}/$filename');
    final temporary = File(
      '${runDir.path}/.$filename.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(jsonEncode(record), flush: true);
    await temporary.rename(destination.path);
  }

  Future<Directory> _ensureRoot() async {
    final root = await _rootDirectory();
    await root.create(recursive: true);
    return root;
  }

  String _safeRunId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 180 ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(trimmed)) {
      throw ArgumentError.value(value, 'runId');
    }
    return trimmed;
  }

  String _normalizeBaseUrl(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) throw ArgumentError.value(value, 'baseUrl');
    return normalized;
  }

  String _basename(String path) => path.split(Platform.pathSeparator).last;
}
