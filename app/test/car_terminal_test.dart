import 'dart:convert';

import 'package:devota/terminal_macro.dart';
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
  late DateTime time;
  late List<String> commands;
  late String screen;
  late TerminalWatchController watch;
  late String transcriberReply;

  setUp(() async {
    time = DateTime(2026);
    commands = [];
    screen = 'prompt> ';
    transcriberReply = '{"text": "hello"}';
    watch = TerminalWatchController(now: () => time);
    addTearDown(watch.dispose);
    watch.configure(
      [TerminalWatchBinding(pane: pane, macroId: 'm')],
      [const TerminalMacro(id: 'm', name: 'Bound', steps: [])],
    );
    watch.connect(
      TmuxWatchTransport(
        (command) async {
          commands.add(command);
          if (command.contains('capture-pane')) return screen;
          return '';
        },
        transcriber: (b64) async => transcriberReply,
      ),
    );
    await watch.poll();
    commands.clear();
  });

  void settle() {
    // Two fresh, identical observations 12 s after the change.
    for (var i = 0; i < 2; i++) {
      time = time.add(const Duration(seconds: 6));
      watch.observations[pane.id]!.observe(screen, time, watch.freshness);
    }
  }

  test('keys go to a working pane, guarded, after leaving copy mode', () async {
    // Fresh but not settled: interrupting a working agent must still work.
    expect(await watch.carSendBytes('%1', '\x1b'), isNull);
    final keys = commands.where((c) => c.contains('send-keys -H')).single;
    expect(keys, contains("tmux display-message -p -t '%1'"));
    expect(keys, endsWith("-t '%1' 1b"));
    final leave = commands.indexWhere((c) => c.contains('pane_in_mode'));
    final send = commands.indexWhere((c) => c.contains('send-keys -H'));
    expect(leave, greaterThanOrEqualTo(0));
    expect(leave, lessThan(send));
    expect(watch.busy, isFalse);
  });

  test('text submit needs a settled pane, then pastes and presses Enter', () async {
    expect(await watch.carSubmitText('%1', 'run the tests'), 'window still changing');
    expect(commands.where((c) => c.contains('paste-buffer')), isEmpty);
    settle();
    expect(await watch.carSubmitText('%1', 'run the tests'), isNull);
    final paste = commands.indexWhere((c) => c.contains('paste-buffer'));
    final enter = commands.lastIndexWhere((c) => c.endsWith(' d'));
    expect(paste, greaterThanOrEqualTo(0));
    expect(enter, greaterThan(paste));
    expect(
      commands.any((c) => c.contains(base64Encode(utf8.encode('run the tests')))),
      isTrue,
    );
  });

  test('a screen that changed before the submit is not sent', () async {
    settle();
    screen = 'prompt> something new';
    expect(await watch.carSubmitText('%1', 'x'), 'window changed');
    expect(commands.where((c) => c.contains('paste-buffer')), isEmpty);
  });

  test('stale or unbound panes are refused', () async {
    expect(await watch.carSendBytes('%9', '\t'), 'window not bound');
    time = time.add(const Duration(seconds: 30));
    expect(await watch.carSendBytes('%1', '\t'), 'window unavailable');
    expect(commands, isEmpty);
  });

  test('a busy controller refuses car input', () async {
    watch.externalBusy = true;
    expect(await watch.carSendBytes('%1', '\t'), 'window busy');
  });

  test('car macros reuse the step runner and refuse device macros', () async {
    settle();
    final macro = TerminalMacro(
      id: 'x',
      name: 'Go',
      steps: [step(TerminalMacroStepType.shell, 'make test')],
    );
    expect(await watch.carRunMacro('%1', macro), isNull);
    expect(commands.any((c) => c.contains('paste-buffer')), isTrue);
    expect(watch.observations['%1']!.macroSent, isTrue);
    final device = TerminalMacro(
      id: 'd',
      name: 'Device',
      steps: [step(TerminalMacroStepType.device, '{}')],
    );
    expect(await watch.carRunMacro('%1', device), contains('device actions'));
  });

  test('scroll uses copy mode and bottom leaves it', () async {
    expect(await watch.carScroll('%1', 30, up: true), isNull);
    expect(
      commands.any((c) => c.contains('copy-mode') && c.contains('-N 30 scroll-up')),
      isTrue,
    );
    commands.clear();
    expect(await watch.carScrollBottom('%1'), isNull);
    expect(commands.any((c) => c.contains('-X cancel')), isTrue);
  });

  test('backspace reads back the removed text from a plain capture diff', () async {
    var plain = 'prompt> fix the tests';
    watch.connect(
      TmuxWatchTransport((command) async {
        commands.add(command);
        if (command.contains('capture-pane -p -t')) return plain;
        if (command.contains('capture-pane')) return screen;
        if (command.contains('send-keys -H')) plain = 'prompt> fix ';
        return '';
      }),
    );
    await watch.poll();
    final (failure, deleted) = await watch.carBackspace('%1', 9);
    expect(failure, isNull);
    expect(deleted, 'the tests');
    final keys = commands.where((c) => c.contains('send-keys -H')).single;
    expect(RegExp(r' 7f').allMatches(keys).length, 9);
  });

  test('home transcription parses the helper reply', () async {
    expect(await watch.carTranscribe('AAAA'), 'hello');
    transcriberReply = '{"error": "unreachable"}';
    expect(await watch.carTranscribe('AAAA'), isNull);
  });

  test('car conclusion reads history without needing a settled screen', () async {
    screen = 'line one\n● Done: all tests pass';
    expect(await watch.carConclusion('%1'), contains('Done: all tests pass'));
  });
}
