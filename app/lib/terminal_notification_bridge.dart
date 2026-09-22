import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'terminal_watch.dart';
import 'terminal_conclusion.dart';

class TerminalNotificationBridge {
  TerminalNotificationBridge(this.watch, {this.onSessionAction}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sessionAction') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final action = args['action']?.toString();
        if (action != null) unawaited(onSessionAction?.call(action));
        return;
      }
      if (call.method == 'actionRejected') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        watch.rejectAction(
          args['id'] as String,
          'Not sent: button expired or terminal changed. Use the current button once settled.',
        );
        return;
      }
      if (call.method == 'readerAction') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        unawaited(_readerAction(args['action'] as String));
        return;
      }
      if (call.method != 'action') return;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (args['action'] == 'listen') {
        unawaited(_listen(args['id'] as String, args['token'] as String));
      } else if (args['action'] == 'stop') {
        if (watch.runningPane == args['id']) watch.stop();
      } else {
        unawaited(
          watch.act(
            args['id'] as String,
            args['action'] as String,
            args['token'] as String,
          ),
        );
      }
    });
    watch.addListener(publish);
  }
  static const _channel = MethodChannel('devota/terminal_notifications');
  final TerminalWatchController watch;
  final Future<void> Function(String action)? onSessionAction;
  bool enabled = true;
  final deliveryStatus = ValueNotifier<String?>(null);
  Timer? _publishTimer;
  bool _disposed = false;
  int _publishVersion = 0;
  ConclusionReading? _reading;
  String? _readingToken;
  int _historyLines = 120;
  int _request = 0;
  String? _readerError;
  String? _errorPane;
  void publish() {
    if (_disposed) return;
    final reading = _reading;
    if (reading != null) {
      final bindings = watch.bindings.where((b) => b.pane.id == reading.paneId);
      if (!enabled ||
          bindings.isEmpty ||
          watch.token(bindings.first) != _readingToken ||
          watch.observations[reading.paneId]?.error != null ||
          watch.runningPane == reading.paneId) {
        _stopReading();
      }
    }
    _publishTimer?.cancel();
    _publishTimer = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_publish()),
    );
  }

  void _stopReading() {
    _request++;
    _reading = null;
    _readingToken = null;
    unawaited(
      _channel.invokeMethod<void>('stopReading').catchError((Object _) {}),
    );
  }

  Future<void> _listen(String paneId, String token) async {
    _stopReading();
    final request = _request;
    _readerError = null;
    _errorPane = paneId;
    try {
      final source = await watch.conclusion(paneId, token);
      if (request != _request || !enabled) return;
      final binding = watch.bindings.firstWhere((b) => b.pane.id == paneId);
      _reading = ConclusionReading(paneId, binding.pane.label, source);
      _readingToken = token;
      _historyLines = 120;
      await _speak();
    } catch (_) {
      if (request == _request) {
        _readerError =
            'Reading unavailable: terminal changed or offline voice missing.';
        publish();
      }
    }
  }

  Future<void> _speak() async {
    final reading = _reading;
    if (reading == null) return;
    await _channel.invokeMethod<void>('speak', {
      'text': reading.text,
      'title': reading.title,
      'earlier': reading.hasEarlier || _historyLines < 800,
    });
  }

  Future<void> _readerAction(String action) async {
    if (action == 'stopReading' || action == 'interrupted') {
      _stopReading();
      return;
    }
    final reading = _reading;
    final token = _readingToken;
    if (reading == null || token == null) return;
    final request = _request;
    try {
      if (action == 'earlier') {
        if (reading.hasEarlier) {
          reading.earlier();
        } else if (_historyLines < 800) {
          final nextLines = (_historyLines + 120).clamp(120, 800);
          final source = await watch.conclusion(
            reading.paneId,
            token,
            lines: nextLines,
          );
          if (request != _request) return;
          if (!source.endsWith(reading.source)) {
            throw StateError('Terminal history changed');
          }
          _historyLines = source == reading.source ? 800 : nextLines;
          final expanded = ConclusionReading(
            reading.paneId,
            reading.title,
            source,
          );
          while (expanded.hasEarlier &&
              expanded.text.length <= reading.text.length) {
            expanded.earlier();
          }
          _reading = expanded;
        }
      } else if (action != 'replay') {
        return;
      }
      await _speak();
    } catch (_) {
      if (request == _request) {
        _readerError = 'Could not read earlier text or play the offline voice.';
        _errorPane = reading.paneId;
        _stopReading();
        publish();
      }
    }
  }

  Future<Map<Object?, Object?>?> _publish() async {
    final version = ++_publishVersion;
    try {
      await _channel.invokeMethod<void>('update', {
        'cards': enabled
            ? watch.cards
                  .map(
                    (card) => {
                      ...card,
                      if (_readerError != null && card['id'] == _errorPane)
                        'status': '${card['status']} · $_readerError',
                    },
                  )
                  .toList()
            : [],
      });
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final status = await _channel.invokeMapMethod<Object?, Object?>('status');
      if (!_disposed && version == _publishVersion && status != null) {
        deliveryStatus.value = status['allowed'] != true
            ? 'Terminal macro notifications are blocked in Android settings.'
            : status['error'] != null
            ? 'Notification error: ${status['error']}'
            : 'Android reports ${status['posted']}/${status['requested']} window cards posted.';
      }
      return status;
    } on MissingPluginException catch (_) {
      // Desktop terminals have no Android notification surface.
      return null;
    } on PlatformException catch (error) {
      if (!_disposed) {
        deliveryStatus.value =
            'Notification error: ${error.message ?? error.code}';
      }
      return {'error': error.message ?? error.code};
    }
  }

  Future<void> verifyDelivery() async {
    _publishTimer?.cancel();
    if (watch.bindings.isNotEmpty && !enabled) {
      throw StateError(
        'Settings saved, but background SSH notifications are inactive. Reconnect and retry.',
      );
    }
    var status = await _publish();
    if (status == null || watch.bindings.isEmpty) return;
    // Allow Android's asynchronous notification posting/rate limit to settle.
    if (status['allowed'] == true && status['posted'] != status['requested']) {
      await Future<void>.delayed(const Duration(seconds: 2));
      status = await _publish();
    }
    if (status != null &&
        (status['allowed'] != true ||
            status['error'] != null ||
            status['posted'] != status['requested'])) {
      throw StateError(
        'Settings saved, but ${deliveryStatus.value ?? 'Android did not confirm the window notifications.'}',
      );
    }
  }

  void dispose() {
    enabled = false;
    _disposed = true;
    _publishTimer?.cancel();
    _stopReading();
    watch.removeListener(publish);
    _channel.setMethodCallHandler(null);
    unawaited(_publish());
    deliveryStatus.dispose();
  }
}
