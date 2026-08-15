import 'dart:io';

import 'package:devota/device_macro_evidence_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps evidence offline and delivers it after a process restart',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'devota-macro-outbox-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final offline = DeviceMacroEvidenceOutbox(
        rootDirectory: () async => temporary,
        sender: (_, _) async => throw const SocketException('offline'),
      );
      await offline.enqueueStep(
        runId: 'run-philippines-drive',
        baseUrl: 'http://10.243.53.96:8082/',
        payload: {
          'stepIndex': 1,
          'frameIndex': 1,
          'capturedAt': '2026-08-15T02:54:45.182448Z',
          'screenshot': {'pngBase64': 'durable-frame'},
        },
      );
      await offline.enqueueCompletion(
        runId: 'run-philippines-drive',
        baseUrl: 'http://10.243.53.96:8082/',
        payload: {'status': 'passed'},
      );
      await offline.flush();
      expect(await offline.pendingRecordCount(), 2);

      final delivered = <({String url, Map<String, dynamic> payload})>[];
      final restarted = DeviceMacroEvidenceOutbox(
        rootDirectory: () async => temporary,
        sender: (url, payload) async {
          delivered.add((url: url, payload: payload));
        },
      );
      await restarted.flush();

      expect(delivered, hasLength(2));
      expect(delivered.first.url, endsWith('/run-philippines-drive/steps'));
      expect(delivered.first.payload['capturedAt'], isNotNull);
      expect(delivered.last.url, endsWith('/run-philippines-drive/complete'));
      expect(await restarted.pendingRecordCount(), 0);
    },
  );

  test('does not let completion overtake multiple captured frames', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'devota-macro-order-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final delivered = <String>[];
    final outbox = DeviceMacroEvidenceOutbox(
      rootDirectory: () async => temporary,
      sender: (url, payload) async {
        delivered.add(
          url.endsWith('/complete')
              ? 'complete'
              : 'frame-${payload['frameIndex']}',
        );
      },
    );
    for (var frame = 1; frame <= 3; frame++) {
      await outbox.enqueueStep(
        runId: 'run-frame-order',
        baseUrl: 'http://relay.example',
        payload: {'stepIndex': 2, 'frameIndex': frame},
      );
    }
    await outbox.enqueueCompletion(
      runId: 'run-frame-order',
      baseUrl: 'http://relay.example',
      payload: {'status': 'passed'},
    );

    await outbox.flush();

    expect(delivered, ['frame-1', 'frame-2', 'frame-3', 'complete']);
  });
}
