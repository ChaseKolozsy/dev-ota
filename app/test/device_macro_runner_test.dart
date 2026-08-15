import 'package:devota/device_macro_runner.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'io.github.chasekolozsy.devota/control_agent.test',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('parses allowlisted device action and rejects arbitrary commands', () {
    final spec = DeviceMacroStepSpec.parse(
      '{"action":"launchApp","args":{"packageName":"example.app"}}',
    );
    expect(spec.action, 'launchApp');
    expect(spec.args['packageName'], 'example.app');
    expect(spec.capture, isTrue);
    expect(
      () => DeviceMacroStepSpec.parse('{"action":"arbitraryShell"}'),
      throwsFormatException,
    );
  });

  test('human checkpoint validates bounded screenshot cadence', () {
    final config = HumanCheckpointConfig.fromArgs({
      'durationSeconds': 10,
      'screenshotsPerSecond': 2,
    });
    expect(config.frameCount, 20);
    expect(
      () => HumanCheckpointConfig.fromArgs({
        'durationSeconds': 120,
        'screenshotsPerSecond': 5,
      }),
      throwsFormatException,
    );
  });

  test('matches exact visible UI selectors and assertions', () {
    final ui = {
      'activePackage': 'example.app',
      'nodes': [
        {
          'text': 'Continue',
          'contentDescription': null,
          'resourceId': 'example.app:id/continue',
          'className': 'android.widget.Button',
          'bounds': {'left': 10, 'top': 20, 'right': 110, 'bottom': 80},
        },
      ],
    };
    expect(matchDeviceUiNodes(ui, {'text': 'Continue'}), hasLength(1));
    expect(
      () => assertDeviceMacroExpectations(
        {
          'activePackage': 'example.app',
          'textIncludes': ['Continue'],
        },
        ui,
        null,
      ),
      returnsNormally,
    );
    expect(
      () => assertDeviceMacroExpectations(
        {
          'textExcludes': ['Continue'],
        },
        ui,
        null,
      ),
      throwsStateError,
    );
  });

  test('matches an anonymous control by normalized center region', () {
    final ui = {
      'nodes': [
        {
          'className': 'android.widget.FrameLayout',
          'bounds': {'left': 0, 'top': 0, 'right': 720, 'bottom': 1640},
        },
        {
          'className': 'android.widget.Button',
          'bounds': {'left': 616, 'top': 61, 'right': 712, 'bottom': 157},
        },
        {
          'className': 'android.widget.Button',
          'bounds': {'left': 56, 'top': 783, 'right': 664, 'bottom': 887},
        },
        {
          'className': 'android.widget.Button',
          'bounds': {'left': 56, 'top': 967, 'right': 664, 'bottom': 1071},
        },
      ],
    };

    final matches = matchDeviceUiNodes(ui, {
      'className': 'android.widget.Button',
      'centerRegion': {'left': .8, 'top': 0, 'right': 1, 'bottom': .15},
    });

    expect(matches, hasLength(1));
    expect((matches.single['bounds'] as Map)['left'], 616);
  });

  test('exact selectors do not confuse short labels with containing text', () {
    final matches = matchDeviceUiNodes(
      {
        'nodes': [
          {
            'className': 'android.widget.Button',
            'contentDescription': 'EN',
            'bounds': {'left': 700, 'top': 700, 'right': 850, 'bottom': 850},
          },
          {
            'className': 'android.widget.Button',
            'contentDescription': 'Show menu',
            'bounds': {'left': 100, 'top': 1200, 'right': 250, 'bottom': 1350},
          },
        ],
      },
      {
        'classNameExact': 'android.widget.Button',
        'contentDescriptionExact': 'EN',
      },
    );

    expect(matches, hasLength(1));
    expect(matches.single['contentDescription'], 'EN');
  });

  test('tapUi uses its local image fallback when selector is absent', () async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final envelope = Map<String, dynamic>.from(call.arguments as Map);
          final action = envelope['action'] as String;
          actions.add(action);
          if (action == 'uiDump') {
            return {'activePackage': 'example.app', 'nodes': []};
          }
          if (action == 'tapImage') {
            final tapArgs = Map<String, dynamic>.from(envelope['args'] as Map);
            expect(tapArgs['packageName'], 'example.app');
            expect(
              Map<String, dynamic>.from(tapArgs['template'] as Map)['format'],
              'devota-image-template',
            );
            return {'ok': true, 'matched': true, 'score': 0.93};
          }
          if (action == 'screenshot') return {'pngBase64': 'frame'};
          return {'ok': true};
        });
    final evidence = <DeviceMacroEvidence>[];
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (item) async => evidence.add(item),
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (_, {onAttempt}) async => {'ok': true},
    );
    const macro = TerminalMacro(
      id: 'image-fallback',
      name: 'Image fallback',
      steps: [
        TerminalMacroStep(
          id: 'tap',
          type: TerminalMacroStepType.device,
          value:
              '{"action":"tapUi","args":{"selector":{"text":"Install"},"packageName":"example.app","imageFallback":{"format":"devota-image-template","version":1,"pngBase64":"AA=="}}}',
          delaySeconds: 0,
        ),
      ],
    );

    final result = await runner.run(macro);

    expect(result.single.actionResult?['matched'], isTrue);
    expect(actions, containsAllInOrder(['uiDump', 'tapImage']));
  });

  test(
    'tapUi delegates the unique semantic match to native accessibility',
    () async {
      final actions = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final envelope = Map<String, dynamic>.from(call.arguments as Map);
            final action = envelope['action'] as String;
            actions.add(action);
            if (action == 'uiDump') {
              return {
                'activePackage': 'example.app',
                'nodes': [
                  {
                    'contentDescription': 'Settings',
                    'className': 'android.widget.Button',
                    'bounds': {
                      'left': 900,
                      'top': 20,
                      'right': 1000,
                      'bottom': 120,
                    },
                  },
                ],
              };
            }
            if (action == 'tapUi') {
              final args = Map<String, dynamic>.from(envelope['args'] as Map);
              expect(args['packageName'], 'example.app');
              expect(
                (args['selector'] as Map)['contentDescription'],
                'Settings',
              );
              return {'ok': true, 'method': 'accessibility_click'};
            }
            if (action == 'screenshot') return {'pngBase64': 'frame'};
            return {'ok': true};
          });
      final runner = DeviceMacroRunner(
        channel: channel,
        evidenceSink: (_) async {},
        installBuild: (_) async => {'ok': true},
        localHttpAssert: (_, {onAttempt}) async => {'ok': true},
      );
      const macro = TerminalMacro(
        id: 'semantic-click',
        name: 'Semantic click',
        steps: [
          TerminalMacroStep(
            id: 'tap',
            type: TerminalMacroStepType.device,
            value:
                '{"action":"tapUi","args":{"selector":{"contentDescription":"Settings"},"packageName":"example.app"}}',
            delaySeconds: 0,
          ),
        ],
      );

      await runner.run(macro);

      expect(actions, containsAllInOrder(['uiDump', 'tapUi']));
      expect(actions, isNot(contains('tap')));
    },
  );

  test('tapUi can delegate a package window without a generic UI precheck', () async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final envelope = Map<String, dynamic>.from(call.arguments as Map);
          final action = envelope['action'] as String;
          actions.add(action);
          if (action == 'tapUi') {
            final args = Map<String, dynamic>.from(envelope['args'] as Map);
            expect(args['packageName'], 'com.android.permissioncontroller');
            expect((args['selector'] as Map)['textExact'], 'Allow');
            return {'ok': true, 'method': 'accessibility_click'};
          }
          if (action == 'screenshot') return {'pngBase64': 'frame'};
          return {'ok': true};
        });
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (_) async {},
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (_, {onAttempt}) async => {'ok': true},
    );
    const macro = TerminalMacro(
      id: 'system-window-click',
      name: 'System window click',
      steps: [
        TerminalMacroStep(
          id: 'allow',
          type: TerminalMacroStepType.device,
          value:
              '{"action":"tapUi","args":{"selector":{"textExact":"Allow"},"packageName":"com.android.permissioncontroller","selectorPrecheck":false}}',
          delaySeconds: 0,
        ),
      ],
    );

    await runner.run(macro);

    expect(actions.first, 'tapUi');
    expect(actions.indexOf('uiDump'), greaterThan(actions.indexOf('tapUi')));
  });

  test('normalized swipe resolves against the live device profile', () async {
    Map<String, dynamic>? swipeArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final envelope = Map<String, dynamic>.from(call.arguments as Map);
          final action = envelope['action'] as String;
          if (action == 'deviceProfile') {
            return {'widthPx': 1080, 'heightPx': 2436};
          }
          if (action == 'swipe') {
            swipeArgs = Map<String, dynamic>.from(envelope['args'] as Map);
            return {'ok': true};
          }
          if (action == 'screenshot') return {'pngBase64': 'frame'};
          if (action == 'uiDump') {
            return {'activePackage': 'example.app', 'nodes': []};
          }
          return {'ok': true};
        });
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (_) async {},
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (_, {onAttempt}) async => {'ok': true},
    );
    const macro = TerminalMacro(
      id: 'normalized-swipe',
      name: 'Normalized swipe',
      steps: [
        TerminalMacroStep(
          id: 'swipe',
          type: TerminalMacroStepType.device,
          value:
              '{"action":"swipe","args":{"x1Normalized":0.5,"y1Normalized":0.8,"x2Normalized":0.5,"y2Normalized":0.3,"durationMs":400}}',
          delaySeconds: 0,
        ),
      ],
    );

    await runner.run(macro);

    expect(swipeArgs, isNotNull);
    expect(swipeArgs!['x1'], 540);
    expect(swipeArgs!['y1'], closeTo(1948.8, 0.0001));
    expect(swipeArgs!['x2'], 540);
    expect(swipeArgs!['y2'], closeTo(730.8, 0.0001));
    expect(swipeArgs, isNot(contains('x1Normalized')));
  });

  test(
    'runner captures every step and captures a failure before stopping',
    () async {
      final actions = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final action = args['action'] as String;
            actions.add(action);
            if (action == 'openSettings') {
              return {'ok': true};
            }
            if (action == 'launchApp') {
              throw PlatformException(
                code: 'missing',
                message: 'not installed',
              );
            }
            if (action == 'screenshot') {
              return {'pngBase64': 'evidence'};
            }
            if (action == 'uiDump') {
              return {'activePackage': 'com.android.settings', 'nodes': []};
            }
            return {'ok': true};
          });
      final evidence = <DeviceMacroEvidence>[];
      final runner = DeviceMacroRunner(
        channel: channel,
        evidenceSink: (item) async => evidence.add(item),
        installBuild: (_) async => {'ok': true},
        localHttpAssert: (_, {onAttempt}) async => {'ok': true},
      );
      const macro = TerminalMacro(
        id: 'device-proof',
        name: 'Device proof',
        steps: [
          TerminalMacroStep(
            id: 'step-1',
            type: TerminalMacroStepType.device,
            value:
                '{"action":"openSettings","expect":{"activePackage":"com.android.settings"}}',
            delaySeconds: 0,
          ),
          TerminalMacroStep(
            id: 'step-2',
            type: TerminalMacroStepType.wait,
            value: '',
            delaySeconds: 0,
          ),
          TerminalMacroStep(
            id: 'step-3',
            type: TerminalMacroStepType.device,
            value:
                '{"action":"launchApp","args":{"packageName":"missing.app"}}',
            delaySeconds: 0,
          ),
        ],
      );

      await expectLater(runner.run(macro), throwsStateError);
      expect(evidence, hasLength(3));
      expect(evidence[0].action, 'openSettings');
      expect(evidence[1].action, 'wait');
      expect(evidence[2].actionError, contains('not installed'));
      expect(actions.where((action) => action == 'screenshot'), hasLength(3));
      expect(actions.where((action) => action == 'uiDump'), hasLength(3));
    },
  );

  test(
    'runner persists the action result when its UI expectation fails',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final envelope = Map<String, dynamic>.from(call.arguments as Map);
            final action = envelope['action'] as String;
            if (action == 'openSettings') {
              return {'ok': true, 'method': 'accessibility_click'};
            }
            if (action == 'screenshot') return {'pngBase64': 'failed-frame'};
            if (action == 'uiDump') {
              return {'activePackage': 'example.app', 'nodes': []};
            }
            return {'ok': true};
          });
      final evidence = <DeviceMacroEvidence>[];
      final runner = DeviceMacroRunner(
        channel: channel,
        evidenceSink: (item) async => evidence.add(item),
        installBuild: (_) async => {'ok': true},
        localHttpAssert: (_, {onAttempt}) async => {'ok': true},
      );
      const macro = TerminalMacro(
        id: 'failed-expectation',
        name: 'Failed expectation',
        steps: [
          TerminalMacroStep(
            id: 'settings',
            type: TerminalMacroStepType.device,
            value:
                '{"action":"openSettings","expect":{"textIncludes":["Settings"]}}',
            delaySeconds: 0,
          ),
        ],
      );

      await expectLater(runner.run(macro), throwsStateError);

      expect(evidence, hasLength(1));
      expect(evidence.single.actionResult?['method'], 'accessibility_click');
      expect(evidence.single.actionError, contains('UI did not include'));
      expect(evidence.single.screenshot?['pngBase64'], 'failed-frame');
    },
  );

  test('runner paces consecutive ordinary screenshot captures', () async {
    final screenshotAttempts = <DateTime>[];
    final requestedDelays = <Duration>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final action = args['action'] as String;
          if (action == 'screenshot') {
            screenshotAttempts.add(DateTime.now());
            return {'pngBase64': 'paced-frame'};
          }
          if (action == 'uiDump') {
            return {'activePackage': 'example.app', 'nodes': const []};
          }
          return {'ok': true};
        });
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (_) async {},
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (_, {onAttempt}) async => {'ok': true},
      diagnosticDelay: (duration) async => requestedDelays.add(duration),
    );
    const macro = TerminalMacro(
      id: 'paced-captures',
      name: 'Paced captures',
      steps: [
        TerminalMacroStep(
          id: 'first',
          type: TerminalMacroStepType.device,
          value: '{"action":"openSettings"}',
          delaySeconds: 0,
        ),
        TerminalMacroStep(
          id: 'second',
          type: TerminalMacroStepType.device,
          value: '{"action":"openSettings"}',
          delaySeconds: 0,
        ),
      ],
    );

    await runner.run(macro);

    expect(screenshotAttempts, hasLength(2));
    expect(requestedDelays, hasLength(1));
    expect(requestedDelays.single.inMilliseconds, greaterThanOrEqualTo(1100));
    expect(requestedDelays.single.inMilliseconds, lessThanOrEqualTo(1200));
  });

  test('failure starts a bounded read-only diagnostic tail', () async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final envelope = Map<String, dynamic>.from(call.arguments as Map);
          final action = envelope['action'] as String;
          actions.add(action);
          if (action == 'launchApp') {
            throw PlatformException(code: 'failed', message: 'install stalled');
          }
          if (action == 'screenshot') return {'pngBase64': 'diagnostic-frame'};
          if (action == 'uiDump') {
            return {
              'activePackage': 'io.github.chasekolozsy.cradlespeak',
              'nodes': const [],
            };
          }
          return {'ok': true};
        });
    final evidence = <DeviceMacroEvidence>[];
    var probeCount = 0;
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (item) async => evidence.add(item),
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (args, {onAttempt}) async {
        probeCount++;
        expect(args['retryUntilSeconds'], 0);
        return {
          'status': 200,
          'json': {'phase': 'installing'},
        };
      },
      diagnosticDelay: (_) async {},
    );
    const macro = TerminalMacro(
      id: 'diagnostic-tail',
      name: 'Diagnostic tail',
      failureDiagnostics: {
        'durationSeconds': 60,
        'intervalSeconds': 30,
        'probes': [
          {
            'url': 'http://127.0.0.1:8002/install-status',
            'expectedStatus': 200,
            'timeoutSeconds': 5,
            'jsonPaths': ['phase'],
          },
        ],
      },
      steps: [
        TerminalMacroStep(
          id: 'fail',
          type: TerminalMacroStepType.device,
          value: '{"action":"launchApp","args":{"packageName":"missing.app"}}',
          delaySeconds: 0,
        ),
      ],
    );

    await expectLater(runner.run(macro), throwsStateError);

    expect(evidence, hasLength(4));
    expect(evidence.first.action, 'launchApp');
    expect(
      evidence.skip(1).map((item) => item.action),
      everyElement('failureDiagnostics'),
    );
    expect(evidence.last.frameIndex, 3);
    expect(evidence.last.frameCount, 3);
    expect(probeCount, 3);
    expect(actions.where((action) => action == 'screenshot'), hasLength(4));
    expect(actions.where((action) => action == 'uiDump'), hasLength(4));
  });

  test('human checkpoint durably sinks each timestamped frame', () async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final action = args['action'] as String;
          actions.add(action);
          if (action == 'humanCheckpoint') return {'ok': true};
          if (action == 'screenshot') return {'pngBase64': 'frame'};
          if (action == 'uiDump') {
            return {'activePackage': 'game.app', 'nodes': []};
          }
          return {'ok': true};
        });
    final uploaded = <DeviceMacroEvidence>[];
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (item) async {
        uploaded.add(item);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      },
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (_, {onAttempt}) async => {'ok': true},
    );
    const macro = TerminalMacro(
      id: 'human-proof',
      name: 'Human proof',
      steps: [
        TerminalMacroStep(
          id: 'human-step',
          type: TerminalMacroStepType.device,
          value:
              '{"action":"humanCheckpoint","args":{"durationSeconds":0.4,"screenshotsPerSecond":5},"expect":{"activePackage":"game.app"}}',
          delaySeconds: 0,
        ),
      ],
    );

    final result = await runner.run(macro);

    expect(result, hasLength(2));
    expect(uploaded.map((item) => item.frameIndex), [1, 2]);
    expect(uploaded.every((item) => item.capturedAt != null), isTrue);
    expect(actions.where((action) => action == 'screenshot'), hasLength(2));
    expect(actions.first, 'humanCheckpoint');
  });

  test('local HTTP poll durably captures intermediate UI frames', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final action = args['action'] as String;
          if (action == 'screenshot') return {'pngBase64': 'install-frame'};
          if (action == 'uiDump') {
            return {
              'activePackage': 'io.github.chasekolozsy.cradlespeak',
              'nodes': [
                {'contentDescription': 'Installing Hungarian pack'},
              ],
            };
          }
          return {'ok': true};
        });
    final uploaded = <DeviceMacroEvidence>[];
    final runner = DeviceMacroRunner(
      channel: channel,
      evidenceSink: (item) async => uploaded.add(item),
      installBuild: (_) async => {'ok': true},
      localHttpAssert: (_, {onAttempt}) async {
        await onAttempt?.call({
          'attempt': 1,
          'ok': false,
          'error': 'phase was installing, expected done',
        });
        return {
          'ok': true,
          'attempts': 2,
          'observedJsonPaths': {'phase': 'done'},
        };
      },
    );
    const macro = TerminalMacro(
      id: 'install-monitor',
      name: 'Install monitor',
      steps: [
        TerminalMacroStep(
          id: 'poll',
          type: TerminalMacroStepType.device,
          value:
              '{"action":"localHttpAssert","args":{"url":"http://127.0.0.1:8002/market-client/install-status?sku=hu-v2","expectedStatus":200,"retryUntilSeconds":600,"captureIntervalSeconds":10},"expect":{"activePackage":"io.github.chasekolozsy.cradlespeak","textExcludes":["TimeoutException"]}}',
          delaySeconds: 0,
        ),
      ],
    );

    final result = await runner.run(macro);

    expect(result, hasLength(2));
    expect(uploaded, hasLength(2));
    expect(uploaded.first.name, contains('poll frame 1'));
    expect(uploaded.last.name, contains('final'));
    expect(uploaded.last.actionResult?['attempts'], 2);
  });

  test(
    'local HTTP poll survives a transient intermediate capture failure',
    () async {
      var screenshotCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final action = args['action'] as String;
            if (action == 'screenshot') {
              screenshotCalls++;
              if (screenshotCalls == 1) {
                throw PlatformException(
                  code: 'device_action_failed',
                  message: 'accessibility screenshot temporarily unavailable',
                );
              }
              return {'pngBase64': 'final-frame'};
            }
            if (action == 'uiDump') {
              return {
                'activePackage': 'io.github.chasekolozsy.cradlespeak',
                'nodes': const [],
              };
            }
            return {'ok': true};
          });
      final uploaded = <DeviceMacroEvidence>[];
      final runner = DeviceMacroRunner(
        channel: channel,
        evidenceSink: (item) async => uploaded.add(item),
        installBuild: (_) async => {'ok': true},
        localHttpAssert: (_, {onAttempt}) async {
          await onAttempt?.call({
            'attempt': 1,
            'ok': false,
            'error': 'phase was installing, expected done',
          });
          return {
            'ok': true,
            'attempts': 2,
            'observedJsonPaths': {'phase': 'done'},
          };
        },
      );
      const macro = TerminalMacro(
        id: 'transient-capture',
        name: 'Transient capture',
        steps: [
          TerminalMacroStep(
            id: 'poll',
            type: TerminalMacroStepType.device,
            value:
                '{"action":"localHttpAssert","args":{"url":"http://127.0.0.1:8002/status","expectedStatus":200,"retryUntilSeconds":60,"captureIntervalSeconds":10},"expect":{"activePackage":"io.github.chasekolozsy.cradlespeak"}}',
            delaySeconds: 0,
          ),
        ],
      );

      final result = await runner.run(macro);

      expect(result, hasLength(2));
      expect(uploaded, hasLength(2));
      expect(
        uploaded.first.actionResult?['evidenceCaptureError'],
        contains('temporarily unavailable'),
      );
      expect(uploaded.first.screenshot, isNull);
      expect(uploaded.last.actionResult?['attempts'], 2);
      expect(uploaded.last.screenshot?['pngBase64'], 'final-frame');
    },
  );
}
