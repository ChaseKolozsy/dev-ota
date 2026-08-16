import 'package:devota/macro_sync_service.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('terminal macros serialize and restore steps', () {
    const macro = TerminalMacro(
      id: 'macro-1',
      name: 'Build check',
      priority: 7,
      steps: [
        TerminalMacroStep(
          id: 'step-1',
          type: TerminalMacroStepType.shell,
          value: 'flutter test',
          delaySeconds: 0.5,
        ),
        TerminalMacroStep(
          id: 'step-2',
          type: TerminalMacroStepType.tmux,
          value: 'n',
          delaySeconds: 0,
        ),
      ],
    );

    final restored = TerminalMacro.fromJson(macro.toJson());

    expect(restored.id, 'macro-1');
    expect(restored.name, 'Build check');
    expect(restored.priority, 7);
    expect(restored.steps, hasLength(2));
    expect(restored.steps[0].type, TerminalMacroStepType.shell);
    expect(restored.steps[0].value, 'flutter test');
    expect(restored.steps[0].delaySeconds, 0.5);
    expect(restored.steps[1].type, TerminalMacroStepType.tmux);
    expect(restored.steps[1].value, 'n');
  });

  test('macro ranking uses priority and keeps saved order for ties', () {
    TerminalMacro macro(String id, int priority) =>
        TerminalMacro(id: id, name: id, priority: priority, steps: const []);

    final ranked = rankTerminalMacros([
      macro('first-default', 0),
      macro('high-a', 10),
      macro('high-b', 10),
      macro('last-default', 0),
      macro('low', -2),
    ]);

    expect(ranked.map((macro) => macro.id), [
      'high-a',
      'high-b',
      'first-default',
      'last-default',
      'low',
    ]);
  });

  test('legacy macro JSON defaults priority to zero', () {
    final macro = TerminalMacro.fromJson({
      'id': 'legacy',
      'name': 'Legacy',
      'steps': const [],
    });

    expect(macro.priority, 0);
  });

  test('device macro steps round trip and identify device macros', () {
    const macro = TerminalMacro(
      id: 'device-1',
      name: 'Visible device proof',
      priority: 100,
      steps: [
        TerminalMacroStep(
          id: 'device-step-1',
          type: TerminalMacroStepType.device,
          value: '{"action":"openSettings"}',
          delaySeconds: 0.25,
        ),
      ],
    );
    final restored = TerminalMacro.fromJson(macro.toJson());
    expect(restored.isDeviceMacro, isTrue);
    expect(restored.steps.single.type, TerminalMacroStepType.device);
    expect(restored.steps.single.value, '{"action":"openSettings"}');
  });

  test('terminal macro steps fall back to safe defaults', () {
    final step = TerminalMacroStep.fromJson({
      'id': 'step-1',
      'type': 'not-a-step-type',
      'delaySeconds': -4,
    });

    expect(step.type, TerminalMacroStepType.shell);
    expect(step.value, '');
    expect(step.delaySeconds, 0);
  });

  test('terminal macro options include prefix controls', () {
    expect(
      terminalMacroTerminalKeyOptions.map((option) => option.value),
      contains('ctrl_b'),
    );
    expect(
      terminalMacroTerminalKeyOptions.map((option) => option.value),
      containsAll(['backspace', '0', '1', '2', '3']),
    );
    expect(
      terminalMacroTmuxOptions.map((option) => option.value),
      contains('\x02'),
    );
    expect(
      terminalMacroTmuxOptions.map((option) => option.value),
      containsAll(['0', '1', '2', '3']),
    );
    expect(
      terminalMacroTmuxOptions.map((option) => option.value),
      isNot(contains('10')),
    );
  });

  test('numeric tmux macro values use direct prefix digit windows', () {
    expect(terminalMacroTmuxSequence('0'), '\x020');
    expect(terminalMacroTmuxSequence('9'), '\x029');
    expect(terminalMacroTmuxSequence('10'), isNull);
    expect(terminalMacroTmuxSequence('n'), '\x02n');
  });

  test('macro sync snapshot parses server payload', () {
    final snapshot = MacroSyncSnapshot.fromJson({
      'updatedAt': '2026-06-26T00:00:00Z',
      'macros': [
        {
          'id': 'macro-1',
          'name': 'hello',
          'steps': [
            {
              'id': 'step-1',
              'type': 'shell',
              'value': 'say hello',
              'delaySeconds': 0.25,
            },
          ],
        },
      ],
      'usageCounts': {'macro-1': 2},
    });

    expect(snapshot.updatedAt, '2026-06-26T00:00:00Z');
    expect(snapshot.macros, hasLength(1));
    expect(snapshot.macros.first.name, 'hello');
    expect(snapshot.usageCounts, {'macro-1': 2});
    expect(snapshot.toJson()['macros'], isA<List>());
  });

  test('run progress reports a fraction and a human step label', () {
    const start = MacroRunProgress(
      macroName: 'Deploy',
      stepIndex: 0,
      stepCount: 0,
    );
    expect(start.fraction, isNull);
    expect(start.stepLabel, 'starting');

    const midway = MacroRunProgress(
      macroName: 'Deploy',
      stepIndex: 2,
      stepCount: 4,
    );
    expect(midway.fraction, 0.5);
    expect(midway.stepLabel, 'step 2 of 4');
  });

  test('controller exposes progress and stop only while a macro runs', () {
    final controller = TerminalMacroController();
    addTearDown(controller.dispose);

    var running = false;
    var stopRequested = false;
    var stepIndex = 0;
    controller.attach(
      runner: (_) async => running = true,
      canRun: () => !running,
      isRunning: () => running,
      progress: () => MacroRunProgress(
        macroName: 'Deploy',
        stepIndex: stepIndex,
        stepCount: 3,
        stopping: stopRequested,
      ),
      stop: () => stopRequested = true,
    );

    // Idle: nothing to show and nothing to stop, so no screen renders a
    // busy banner or an armed Stop button.
    expect(controller.progress, isNull);
    expect(controller.canStop, isFalse);
    controller.requestStop();
    expect(stopRequested, isFalse);

    running = true;
    stepIndex = 2;
    expect(controller.canRun, isFalse);
    expect(controller.progress?.macroName, 'Deploy');
    expect(controller.progress?.stepLabel, 'step 2 of 3');
    expect(controller.canStop, isTrue);

    controller.requestStop();
    expect(stopRequested, isTrue);
    expect(controller.progress?.stopping, isTrue);

    running = false;
    expect(controller.progress, isNull);

    controller.detach();
    expect(controller.isAttached, isFalse);
  });

  group('repositionTerminalMacro', () {
    TerminalMacro macro(String id, int priority) =>
        TerminalMacro(id: id, name: id, priority: priority, steps: const []);

    test('dragging a macro to the top outranks everything else', () {
      final moved = repositionTerminalMacro(
        [macro('a', 0), macro('b', 0), macro('c', 5)],
        'b',
        0,
      );

      expect(rankTerminalMacros(moved).map((macro) => macro.id), [
        'b',
        'c',
        'a',
      ]);
    });

    test('a macro dropped lower keeps the order of the macros it passed', () {
      final ranked = rankTerminalMacros([
        macro('a', 0),
        macro('b', 0),
        macro('c', 0),
        macro('d', 0),
      ]);
      final moved = repositionTerminalMacro(ranked, 'a', 2);

      expect(rankTerminalMacros(moved).map((macro) => macro.id), [
        'b',
        'c',
        'a',
        'd',
      ]);
    });

    test('the new order survives a save and reload', () {
      final moved = repositionTerminalMacro(
        [macro('a', 0), macro('b', 0), macro('c', 0)],
        'c',
        0,
      );
      final restored = moved
          .map((macro) => TerminalMacro.fromJson(macro.toJson()))
          .toList();

      expect(rankTerminalMacros(restored).map((macro) => macro.id), [
        'c',
        'a',
        'b',
      ]);
    });

    test('an unknown macro or an unchanged slot leaves the list alone', () {
      final macros = [macro('a', 0), macro('b', 0)];

      expect(repositionTerminalMacro(macros, 'missing', 0), same(macros));
      expect(repositionTerminalMacro(macros, 'a', 0), same(macros));
      expect(repositionTerminalMacro(const [], 'a', 0), isEmpty);
    });
  });
}
