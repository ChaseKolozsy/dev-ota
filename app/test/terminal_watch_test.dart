import 'package:devota/terminal_macro.dart';
import 'package:devota/terminal_submission.dart';
import 'package:devota/terminal_watch.dart';
import 'package:flutter_test/flutter_test.dart';

const pane = WatchedPane(
  id: '%1',
  identity: '1:2:3',
  label: 'test:1.0',
  window: '1',
);
TerminalMacroStep step(TerminalMacroStepType type, String value) =>
    TerminalMacroStep(id: value, type: type, value: value, delaySeconds: 0);

void main() {
  test(
    'shell quoting preserves apostrophes and command substitution literally',
    () {
      expect(shellQuote("a'b\$(whoami)"), "'a'\\''b\$(whoami)'");
    },
  );

  test(
    'disconnect after paste cancels Enter and never replays the run',
    () async {
      var time = DateTime(2026);
      final commands = <String>[];
      final binding = TerminalWatchBinding(pane: pane, macroId: 'hello');
      final watch = TerminalWatchController(now: () => time);
      addTearDown(watch.dispose);
      watch.configure(
        [binding],
        [
          TerminalMacro(
            id: 'hello',
            name: 'Hello',
            steps: [step(TerminalMacroStepType.shell, 'hello')],
          ),
        ],
      );
      final transport = TmuxWatchTransport((command) async {
        commands.add(command);
        if (command.contains('paste-buffer')) watch.connect(null);
        return 'unchanged';
      });
      watch.connect(transport);
      await watch.poll();
      for (var i = 0; i < 2; i++) {
        time = time.add(const Duration(seconds: 6));
        await watch.poll();
      }
      await watch.act('%1', 'run', watch.token(binding));
      expect(commands.where((c) => c.contains('paste-buffer')), hasLength(1));
      expect(commands.where((c) => c.contains('send-keys')), isEmpty);
      expect(watch.observations['%1']!.submissionUnconfirmed, isTrue);
      watch.connect(transport);
      await watch.poll();
      expect(commands.where((c) => c.contains('paste-buffer')), hasLength(1));
      expect(watch.canAct(binding), isFalse);
    },
  );

  test(
    'editing macro or creating a controller invalidates old action tokens',
    () {
      final binding = TerminalWatchBinding(pane: pane, macroId: 'hello');
      final watch = TerminalWatchController();
      final other = TerminalWatchController();
      addTearDown(watch.dispose);
      addTearDown(other.dispose);
      final oldToken = watch.token(binding);
      expect(other.token(binding), isNot(oldToken));
      watch.updateMacros([
        TerminalMacro(
          id: 'hello',
          name: 'Updated',
          steps: [step(TerminalMacroStepType.shell, 'hello')],
        ),
      ]);
      expect(watch.token(binding), isNot(oldToken));
    },
  );

  test('stop interrupts a wait before any later keystrokes', () async {
    var time = DateTime(2026);
    final commands = <String>[];
    final binding = TerminalWatchBinding(pane: pane, macroId: 'hello');
    final watch = TerminalWatchController(now: () => time);
    addTearDown(watch.dispose);
    watch.configure(
      [binding],
      [
        TerminalMacro(
          id: 'hello',
          name: 'Hello',
          steps: [
            const TerminalMacroStep(
              id: 'wait',
              type: TerminalMacroStepType.wait,
              value: '',
              delaySeconds: 1,
            ),
            step(TerminalMacroStepType.shell, 'hello'),
          ],
        ),
      ],
    );
    watch.connect(
      TmuxWatchTransport((command) async {
        commands.add(command);
        return 'unchanged';
      }),
    );
    await watch.poll();
    for (var i = 0; i < 2; i++) {
      time = time.add(const Duration(seconds: 6));
      await watch.poll();
    }
    watch.addListener(() {
      if (watch.progress?.contains('step 1') ?? false) watch.stop();
    });
    await watch.act('%1', 'run', watch.token(binding));
    expect(commands.any((c) => c.contains('paste-buffer')), isFalse);
    expect(watch.observations['%1']!.runError, contains('Stopped'));
  });

  test('explicit Enter across Wait replaces implicit submission', () {
    final steps = [
      step(TerminalMacroStepType.shell, 'hello'),
      step(TerminalMacroStepType.wait, ''),
      step(TerminalMacroStepType.terminalKey, 'enter'),
    ];
    expect(commandNeedsEnter(steps, 0), isFalse);
    expect(commandNeedsEnter(steps.take(1).toList(), 0), isTrue);
    expect(terminalKeySequence('enter'), '\r');
  });

  test('settled requires fresh observations and resets after a gap', () {
    final state = PaneObservation();
    final start = DateTime(2026);
    const freshness = Duration(seconds: 8);
    const quiet = Duration(seconds: 10);
    state.observe('hello', start, freshness);
    state.observe('hello', start.add(const Duration(seconds: 6)), freshness);
    expect(
      state.settled(start.add(const Duration(seconds: 10)), quiet, freshness),
      isTrue,
    );
    expect(
      state.settled(start.add(const Duration(seconds: 15)), quiet, freshness),
      isFalse,
    );
    state.observe('hello', start.add(const Duration(seconds: 20)), freshness);
    expect(
      state.settled(start.add(const Duration(seconds: 20)), quiet, freshness),
      isFalse,
    );
  });

  test(
    'input is pane-targeted, quoted and separately submitted exactly once',
    () async {
      final commands = <String>[];
      final transport = TmuxWatchTransport((command) async {
        commands.add(command);
        return '';
      });
      await transport.paste(pane, "hello '\n\$(do-not-run)");
      await transport.key(pane, 'enter');
      expect(commands[0], contains("paste-buffer -d -p"));
      expect(commands[0], isNot(contains('do-not-run')));
      expect(commands.every((c) => c.contains("'1:2:3'")), isTrue);
      expect(commands[1], contains("send-keys -H -t '%1' d"));
    },
  );

  test(
    'stale and duplicate actions cannot run; hidden pane receives one Enter',
    () async {
      var time = DateTime(2026);
      final commands = <String>[];
      final binding = TerminalWatchBinding(pane: pane, macroId: 'hello');
      final watch = TerminalWatchController(now: () => time);
      addTearDown(watch.dispose);
      watch.configure(
        [binding],
        [
          TerminalMacro(
            id: 'hello',
            name: 'Hello',
            steps: [
              step(TerminalMacroStepType.shell, 'hello'),
              step(TerminalMacroStepType.terminalKey, 'enter'),
            ],
          ),
        ],
      );
      watch.connect(
        TmuxWatchTransport((command) async {
          commands.add(command);
          return command.contains('capture-pane') ? 'unchanged' : '';
        }),
      );
      await watch.poll();
      time = time.add(const Duration(seconds: 6));
      await watch.poll();
      time = time.add(const Duration(seconds: 5));
      await watch.poll();
      expect(watch.canAct(binding), isTrue);
      await watch.act('%1', 'run', 'stale');
      final token = watch.token(binding);
      final run = watch.act('%1', 'run', token);
      await watch.act('%1', 'run', token);
      await run;
      expect(commands.where((c) => c.contains('paste-buffer')), hasLength(1));
      expect(commands.where((c) => c.contains('send-keys')), hasLength(1));
      expect(watch.observations['%1']!.submissionUnconfirmed, isTrue);
      expect(watch.canAct(binding), isFalse);
    },
  );

  test('changed preflight and missing panes never send input', () async {
    var time = DateTime(2026);
    var screen = 'before';
    var failed = false;
    final commands = <String>[];
    final binding = TerminalWatchBinding(pane: pane, macroId: 'hello');
    final watch = TerminalWatchController(now: () => time);
    addTearDown(watch.dispose);
    watch.configure(
      [binding],
      [
        TerminalMacro(
          id: 'hello',
          name: 'Hello',
          steps: [step(TerminalMacroStepType.shell, 'hello')],
        ),
      ],
    );
    watch.connect(
      TmuxWatchTransport((command) async {
        commands.add(command);
        if (failed) throw StateError('gone');
        return screen;
      }),
    );
    await watch.poll();
    for (var i = 0; i < 2; i++) {
      time = time.add(const Duration(seconds: 6));
      await watch.poll();
    }
    screen = 'working again';
    await watch.act('%1', 'run', watch.token(binding));
    expect(commands.any((c) => c.contains('paste-buffer')), isFalse);
    failed = true;
    await watch.poll();
    expect(watch.canAct(binding), isFalse);
    expect(watch.cards.single['status'], contains('unavailable'));
  });
}
