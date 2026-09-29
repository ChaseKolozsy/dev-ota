import 'dart:io';

import 'package:devota/voice/screen_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screens as the Terminal tab's buffer holds them: one string per row.
///
/// claude_code_reply.txt and codex_reply.txt are real `tmux capture-pane`
/// screens of Claude Code and Codex CLI (the Codex one with its private paths
/// and prose replaced by neutral text of the same shape), with the tmux status
/// bar the phone draws under them. The *_working screens use the same formats
/// with tool blocks and a spinner, which the live panes were not showing.
List<String> fixture(String name) =>
    File('test/fixtures/voice_read/$name').readAsLinesSync();

void main() {
  group('Claude Code', () {
    final reply = fixture('claude_code_reply.txt');
    final working = fixture('claude_code_working.txt');

    test('is recognized from its input box', () {
      expect(detectTui(reply), TerminalTui.claudeCode);
      expect(detectTui(working), TerminalTui.claudeCode);
    });

    test('read screen drops rules, the input box, footer, agents and '
        'the tmux status bar', () {
      final text = readScreen(reply).text;
      expect(text, startsWith('Yes, it will read Codex too.'));
      expect(
        text.split('\n'),
        contains('Waiting for 5 background agents to finish'),
      );
      expect(text, contains("I'll tell you when the build is in the Builds"));
      for (final chrome in [
        '─',
        '❯',
        '●',
        'bypass permissions',
        'shift+tab',
        'for agents',
        'title-audit-lane',
        'main',
        'tokens',
        '[authoring]',
        'neweyesiss',
      ]) {
        expect(text, isNot(contains(chrome)), reason: chrome);
      }
      // Whitespace collapsed, list items on their own lines without dashes.
      expect(text, isNot(contains('  ')));
      expect(
        text.split('\n'),
        contains(
          'DevOTA will work out from the screen itself whether you\'re '
          'looking at Claude or Codex, and apply that one\'s layout.',
        ),
      );
    });

    test('read reply is the last ● block, down to the input box', () {
      final text = readReply(reply).text;
      expect(text, startsWith('Yes, it will read Codex too.'));
      expect(text, endsWith('Builds tab.'));
      expect(text, isNot(contains('Waiting for 5 background agents')));
      expect(text, isNot(contains('main')));
    });

    test('read reply skips tool blocks and the unsent prompt', () {
      final text = readReply(working).text;
      expect(
        text,
        'Yes. The footer and the agent list under the input box are never '
        'read. The rule lines around the box are skipped too.\n'
        'Checking the Codex screen next.',
      );
      final screen = readScreen(working).text;
      expect(screen, contains('does it skip the footer?'));
      expect(screen, contains('Bash(tmux capture-pane'));
      expect(screen, isNot(contains('also check the status bar')));
      expect(screen, isNot(contains('esc to interrupt')));
    });

    test('older builds with a boxed > prompt', () {
      final lines = [
        '● Done. Two files changed.',
        '',
        '╭──────────────────────────────╮',
        '│ >                            │',
        '╰──────────────────────────────╯',
        '  ? for shortcuts',
      ];
      expect(detectTui(lines), TerminalTui.claudeCode);
      expect(readReply(lines).text, 'Done. Two files changed.');
      expect(readScreen(lines).text, 'Done. Two files changed.');
    });

    test('a reply whose bullet scrolled off still reads what is left', () {
      final lines = [
        '  the rest of a long answer, still on screen.',
        '',
        '──────────',
        '❯ ',
        '──────────',
        '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
      ];
      expect(
        readReply(lines).text,
        'the rest of a long answer, still on screen.',
      );
    });
  });

  group('Codex CLI', () {
    final reply = fixture('codex_reply.txt');
    final working = fixture('codex_working.txt');

    test('is recognized from its › input line and footer', () {
      expect(detectTui(reply), TerminalTui.codex);
      expect(detectTui(working), TerminalTui.codex);
    });

    test('read reply is the last text • block, without "Worked for"', () {
      expect(
        readReply(reply).text,
        'All three suites pass. The widget tests and unit tests ran from:\n'
        '/home/example/project/app/test/voice_terminal_tab_test.dart and '
        'app/android\n'
        'No test was skipped. The branch is pushed and the build is '
        'unchanged.',
      );
    });

    test('read reply skips Explored / Ran / Working blocks', () {
      expect(
        readReply(working).text,
        "I'll look at how the status bar is drawn on the phone first.",
      );
    });

    test('read screen keeps tool blocks, drops the input box and footer', () {
      final text = readScreen(reply).text;
      expect(text, startsWith('also run the widget tests please'));
      expect(text, contains('Ran flutter test'));
      expect(text, contains('Worked for 1m 57s'));
      for (final chrome in [
        'Ask Codex',
        'GPT-6-Sol',
        'for shortcuts',
        '[authoring]',
        '└',
        '•',
      ]) {
        expect(text, isNot(contains(chrome)), reason: chrome);
      }
    });

    test('an approval menu is not taken for the input box', () {
      final lines = [
        '• Ran rm -rf build',
        '',
        '  Would you like to run the following command?',
        '',
        '› 1. Yes, proceed',
        '  2. No, and tell Codex what to do differently',
        '',
        '  Press enter to confirm or esc to cancel',
      ];
      expect(detectTui(lines), TerminalTui.other);
      expect(readScreen(lines).text, contains('2. No, and tell Codex'));
    });
  });

  group('any other screen', () {
    final shell = fixture('plain_shell.txt');

    test('read reply falls back to the whole screen', () {
      expect(detectTui(shell), TerminalTui.other);
      final screen = readScreen(shell).text;
      expect(readReply(shell).text, screen);
      // Short rows are their own lines, not run together like wrapped prose.
      expect(screen.split('\n').take(1), [
        'chase@neweyesiss:~/dev-ota\$ git log --oneline -2',
      ]);
      expect(screen.split('\n'), contains('app docs mcp scripts server'));
      expect(screen, isNot(contains('[authoring]')));
    });

    test('escape codes are stripped', () {
      final lines = ['\x1b[1m\x1b[38;5;2m•\x1b[0m \x1b[1mbold\x1b[0m   text'];
      expect(readScreen(lines).text, 'bold text');
    });

    test('an empty or rule-only screen has nothing to read', () {
      expect(readScreen(const []).isEmpty, isTrue);
      expect(readScreen(const ['', '─────', '   ']).isEmpty, isTrue);
      expect(
        readReply(const ['─────', '❯ ', '─────', '? for shortcuts']).isEmpty,
        isTrue,
      );
    });
  });

  group('speech chunks', () {
    test('split at sentences, never longer than the limit', () {
      final text = List.generate(
        30,
        (i) => 'Sentence number $i is here.',
      ).join(' ');
      final chunks = speechChunks(text, maxChars: 120);
      expect(chunks.length, greaterThan(5));
      expect(chunks.every((c) => c.length <= 120), isTrue);
      expect(chunks.every((c) => c.endsWith('.')), isTrue);
      expect(chunks.join(' '), text);
    });

    test('a very long sentence is cut at spaces', () {
      final text = List.filled(100, 'word').join(' ');
      final chunks = speechChunks(text, maxChars: 50);
      expect(chunks.every((c) => c.length <= 50), isTrue);
      expect(chunks.join(' '), '$text.');
    });

    test('paragraphs without punctuation still get a pause', () {
      expect(speechChunks('Heading\nBody text.'), ['Heading. Body text.']);
      expect(speechChunks(''), isEmpty);
    });
  });
}
