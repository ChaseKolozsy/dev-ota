import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:devota/terminal_notification_bridge.dart';
import 'package:devota/terminal_watch.dart';

void main() {
  const channel = MethodChannel('devota/terminal_notifications');
  testWidgets('publication bursts coalesce and delivery is acknowledged', (
    tester,
  ) async {
    var updates = 0;
    final watch = TerminalWatchController();
    final bridge = TerminalNotificationBridge(watch);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'update') updates++;
      if (call.method == 'status') {
        return {'allowed': true, 'posted': 3, 'requested': 3};
      }
      return null;
    });
    for (var i = 0; i < 50; i++) {
      bridge.publish();
    }
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 350));
    expect(updates, 1);
    expect(
      bridge.deliveryStatus.value,
      'Android reports 3/3 window cards posted.',
    );
    bridge.dispose();
    // A late disconnect callback must not schedule work after disposal.
    bridge.publish();
    watch.dispose();
    await tester.pump(const Duration(milliseconds: 350));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  testWidgets('Save cannot confirm delivery while the bridge is disabled', (
    tester,
  ) async {
    final watch = TerminalWatchController();
    watch.configure([
      TerminalWatchBinding(
        pane: const WatchedPane(
          id: '%0',
          identity: 'id',
          label: 'test:1.0',
          window: '1',
        ),
        macroId: 'test',
      ),
    ], []);
    final bridge = TerminalNotificationBridge(watch)..enabled = false;
    await expectLater(bridge.verifyDelivery(), throwsStateError);
    bridge.dispose();
    watch.dispose();
    await tester.pump(const Duration(milliseconds: 350));
  });

  for (final blocked in [false, true]) {
    testWidgets(
      'Save exposes ${blocked ? 'blocked channel' : 'missing cards'}',
      (tester) async {
        final watch = TerminalWatchController();
        watch.configure([
          TerminalWatchBinding(
            pane: const WatchedPane(
              id: '%0',
              identity: 'id',
              label: 'test:1.0',
              window: '1',
            ),
            macroId: 'test',
          ),
        ], []);
        final bridge = TerminalNotificationBridge(watch);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'status') {
              return {'allowed': !blocked, 'posted': 0, 'requested': 1};
            }
            return null;
          },
        );
        final result = expectLater(bridge.verifyDelivery(), throwsStateError);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        if (!blocked) {
          await tester.pump(const Duration(seconds: 2));
          await tester.pump(const Duration(milliseconds: 350));
        }
        await result;
        expect(
          bridge.deliveryStatus.value,
          contains(blocked ? 'blocked' : '0/1'),
        );
        bridge.dispose();
        watch.dispose();
        await tester.pump(const Duration(milliseconds: 350));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      },
    );
  }
}
