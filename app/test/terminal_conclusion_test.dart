import 'dart:convert';
import 'package:devota/terminal_conclusion.dart';
import 'package:devota/terminal_watch.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a new submission cannot reuse an unchanged old conclusion', () {
    final state = PaneObservation();
    final time = DateTime(2026);
    state.observe('Previous job complete.', time, const Duration(seconds: 8));
    state.submittedScreen = state.content;
    state.awaitingOutput = true;
    state.observe('Previous job complete.', time, const Duration(seconds: 8));
    expect(state.awaitingOutput, isTrue);
    state.observe('New job is working.', time, const Duration(seconds: 8));
    expect(state.awaitingOutput, isFalse);
  });
  test(
    'cleanup removes terminal debris without losing failed checks or negation',
    () {
      final result = cleanTerminalConclusion(
        '\x1b[32m● Not complete.\x1b[0m\n'
        '│ Tests failed: 2. │\n─────\n❯\nesc to interrupt\n'
        'See /tmp/log.txt.\n',
      );
      expect(result, contains('Not complete.'));
      expect(result, contains('Tests failed: 2.'));
      expect(result, contains('/tmp/log.txt'));
      expect(result, isNot(contains('\x1b')));
      expect(result, isNot(contains('interrupt')));
    },
  );
  test(
    'reading cursor starts near the end and walks back without dropping text',
    () {
      final source = List.generate(
        40,
        (i) => 'Paragraph $i. ${'Useful text. ' * 12}\n\n',
      ).join();
      final reading = ConclusionReading('%1', 'Window one', source);
      final first = reading.text;
      expect(first, contains('Paragraph 39'));
      expect(first, isNot(contains('Paragraph 0.')));
      reading.earlier();
      expect(reading.text.length, greaterThan(first.length));
      while (reading.hasEarlier) {
        reading.earlier();
      }
      expect(reading.text, startsWith('Paragraph 0.'));
      expect(reading.text, contains('Paragraph 39'));
    },
  );
  test(
    'speech removes markdown markup and fenced code, preserving caveats',
    () {
      expect(
        speakableConclusion(
          '## Result\n**Not done**.\n```sh\nexit 1\n```\nTests failed.',
        ),
        contains('Not done'),
      );
      expect(
        speakableConclusion('```sh\nexit 1\n```'),
        contains('Code block omitted'),
      );
    },
  );
  test('malformed or unsupported model verdict never becomes success', () {
    for (final value in [
      'true',
      '{}',
      '{"status":"reported_success","reason":"ok","evidence":"invented"}',
    ]) {
      expect(
        ConclusionVerdict.parse(value, 'still working').status,
        'uncertain',
      );
    }
  });
  test(
    'new output invalidates verdicts and one bad window does not block another',
    () async {
      var now = DateTime(2026);
      var screen = 'Final answer: all checks passed.';
      final watch = TerminalWatchController(now: () => now);
      addTearDown(watch.dispose);
      const pane = WatchedPane(
        id: '%1',
        identity: '1:2:3',
        label: 'One',
        window: '1',
      );
      const second = WatchedPane(
        id: '%2',
        identity: '1:2:4',
        label: 'Two',
        window: '2',
      );
      final firstBinding = TerminalWatchBinding(pane: pane, macroId: 'm');
      final secondBinding = TerminalWatchBinding(pane: second, macroId: 'm');
      watch.configure(
        [firstBinding, secondBinding],
        [const TerminalMacro(id: 'm', name: 'Hello', steps: [])],
      );
      watch.connect(TmuxWatchTransport((command) async => screen));
      await watch.poll();
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(seconds: 6));
        await watch.poll();
      }
      watch.observations['%1']!.verdict = const ConclusionVerdict(
        'needs_attention',
        'Tests failed.',
        'Tests failed.',
      );
      watch.observations['%2']!.verdict = const ConclusionVerdict(
        'reported_success',
        'Checks passed.',
        'all checks passed.',
      );
      expect(watch.canAct(secondBinding), isTrue);
      expect(watch.cards.last['status'], contains('Reported success'));
      screen = 'Working on the next task';
      await watch.poll();
      expect(watch.observations['%2']!.verdict, isNull);
      expect(watch.cards.last['status'], isNot(contains('Reported success')));
    },
  );
  test('late review for old output is discarded', () async {
    var now = DateTime(2026);
    var screen = 'All work completed.';
    final watch = TerminalWatchController(now: () => now);
    addTearDown(watch.dispose);
    const pane = WatchedPane(
      id: '%1',
      identity: '1:2:3',
      label: 'One',
      window: '1',
    );
    watch.configure(
      [TerminalWatchBinding(pane: pane, macroId: 'm')],
      [const TerminalMacro(id: 'm', name: 'Hello', steps: [])],
    );
    watch.connect(
      TmuxWatchTransport(
        (command) async => screen,
        reviewer: (source) async {
          screen = 'New output arrived';
          await watch.poll();
          return jsonEncode({
            'status': 'reported_success',
            'reason': 'Done.',
            'evidence': source,
          });
        },
      ),
    );
    await watch.poll();
    for (var i = 0; i < 2; i++) {
      now = now.add(const Duration(seconds: 6));
      await watch.poll();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(watch.observations['%1']!.verdict, isNull);
  });
}
