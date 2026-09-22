import 'dart:async';
import 'package:flutter/services.dart';
import 'terminal_watch.dart';

class TerminalNotificationBridge {
  TerminalNotificationBridge(this.watch) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'action') return;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (args['action'] == 'stop') {
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
  bool enabled = true;
  void publish() {
    unawaited(_publish());
  }

  Future<void> _publish() async {
    try {
      await _channel.invokeMethod<void>('update', {
        'cards': enabled ? watch.cards : [],
      });
    } on MissingPluginException catch (_) {
      // Desktop terminals have no Android notification surface.
    } on PlatformException catch (_) {
      // Notification permissions may have been revoked.
    }
  }

  void dispose() {
    enabled = false;
    watch.removeListener(publish);
    _channel.setMethodCallHandler(null);
    publish();
  }
}
