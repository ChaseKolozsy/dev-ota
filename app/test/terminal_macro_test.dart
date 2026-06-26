import 'package:devota/macro_sync_service.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('terminal macros serialize and restore steps', () {
    const macro = TerminalMacro(
      id: 'macro-1',
      name: 'Build check',
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
    expect(restored.steps, hasLength(2));
    expect(restored.steps[0].type, TerminalMacroStepType.shell);
    expect(restored.steps[0].value, 'flutter test');
    expect(restored.steps[0].delaySeconds, 0.5);
    expect(restored.steps[1].type, TerminalMacroStepType.tmux);
    expect(restored.steps[1].value, 'n');
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
      containsAll(['0', '1', '2', '3']),
    );
    expect(
      terminalMacroTmuxOptions.map((option) => option.value),
      contains('\x02'),
    );
    expect(
      terminalMacroTmuxOptions.map((option) => option.value),
      containsAll(['0', '1', '2', '3', '10']),
    );
  });

  test('numeric tmux macro values select exact windows', () {
    expect(terminalMacroTmuxSequence('0'), '\x02:select-window -t :0\r');
    expect(terminalMacroTmuxSequence('10'), '\x02:select-window -t :10\r');
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
}
