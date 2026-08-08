import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Keeps DevOTA's process alive (and therefore its SSH socket usable) while the
/// app is in the background.
///
/// Android 12+ freezes cached processes within seconds of the app losing
/// visibility, and Pixel 7-era builds enforce it much harder than older phones
/// did. A frozen isolate can't run keepalive timers or read its socket, so the
/// SSH session silently dies whenever the user checks something else — or
/// whenever the control agent drives the phone away from DevOTA. There is no
/// "stay connected in the background" permission; a foreground service is the
/// supported way out, so this starts one for the lifetime of the session.
class BackgroundSessionService {
  static const MethodChannel _channel = MethodChannel(
    'io.github.chasekolozsy.devota/control_agent',
  );

  static bool _notificationPermissionAsked = false;

  /// Starts (or relabels) the foreground service that pins the process.
  static Future<void> start(String label) async {
    // The service runs whether or not the notification is visible, but a
    // silently hidden ongoing notification is worse than asking once.
    if (!_notificationPermissionAsked) {
      _notificationPermissionAsked = true;
      try {
        if (!await Permission.notification.isGranted) {
          await Permission.notification.request();
        }
      } catch (_) {
        // Not fatal: the service still keeps the process out of cached state.
      }
    }
    try {
      await _channel.invokeMethod<bool>('startSshSession', {'label': label});
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stopSshSession');
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  /// Doze can still stall an idle screen-off session behind a foreground
  /// service, so the terminal offers this exemption once.
  static Future<bool> isBatteryOptimizationExempt() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } on PlatformException catch (_) {
      return true;
    } on MissingPluginException catch (_) {
      return true;
    }
  }

  static Future<bool> requestBatteryOptimizationExemption() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }
}
