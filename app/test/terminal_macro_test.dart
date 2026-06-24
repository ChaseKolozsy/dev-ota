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
}
