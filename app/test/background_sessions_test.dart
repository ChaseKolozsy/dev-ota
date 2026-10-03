import 'package:devota/background_session_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'disconnecting one terminal keeps the foreground service for the other',
    () async {
      const channel = MethodChannel(
        'io.github.chasekolozsy.devota/control_agent',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final first = Object(), second = Object();
      Future<void> update(Object owner, bool live, bool active, String label) =>
          BackgroundSessionService.updateSession(
            owner,
            keepAlive: live,
            active: active,
            label: label,
            action: live ? 'disconnect' : 'connect',
            actionLabel: live ? 'Disconnect' : 'Connect',
            zeroTierRecovery: false,
          );
      await update(first, true, true, 'First');
      await update(second, true, false, 'Second');
      expect(
        (calls.last.arguments as Map)['label'],
        contains('2 SSH sessions'),
      );
      calls.clear();
      await update(first, false, true, 'First disconnected');
      expect(calls.any((call) => call.method == 'stopSshSession'), isFalse);
      expect((calls.last.arguments as Map)['label'], 'First disconnected');
      expect((calls.last.arguments as Map)['action'], 'connect');
      await update(first, false, false, 'First');
      expect((calls.last.arguments as Map)['label'], 'Second');
      calls.clear();
      await update(second, false, false, 'Second');
      expect(calls.last.method, 'stopSshSession');
    },
  );
}
