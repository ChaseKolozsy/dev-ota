import 'package:devota/terminal_pad_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeKeySequence', () {
    test('passes plain text through unchanged', () {
      expect(decodeKeySequence('ls -la'), 'ls -la');
      expect(decodeKeySequence('+'), '+');
      expect(decodeKeySequence(''), '');
    });

    test('expands named escapes', () {
      expect(decodeKeySequence(r'\t'), '\t');
      expect(decodeKeySequence(r'\r'), '\r');
      expect(decodeKeySequence(r'\n'), '\n');
      expect(decodeKeySequence(r'\e'), '\x1B');
      expect(decodeKeySequence(r'\E'), '\x1B');
      expect(decodeKeySequence(r'\\'), r'\');
    });

    test('expands \\xNN hex escapes', () {
      expect(decodeKeySequence(r'\x1a'), '\x1A'); // Ctrl-Z
      expect(decodeKeySequence(r'\x12'), '\x12'); // Ctrl-R
      expect(decodeKeySequence(r'\x1B[H'), '\x1B[H'); // ESC + [H
    });

    test('keeps unknown or dangling escapes literal', () {
      expect(decodeKeySequence(r'\q'), r'\q');
      expect(decodeKeySequence('trailing\\'), 'trailing\\');
      expect(decodeKeySequence(r'\x'), r'\x'); // no hex digits
    });
  });

  group('resolveKeySpec', () {
    String seq(String spec) {
      final r = resolveKeySpec(spec);
      expect(r.ok, isTrue, reason: 'expected "$spec" to resolve: ${r.error}');
      return r.sequence!;
    }

    test('control letters', () {
      expect(seq('Ctrl-C'), '\x03');
      expect(seq('ctrl-c'), '\x03');
      expect(seq('C-c'), '\x03');
      expect(seq('^C'), '\x03');
      expect(seq('Ctrl-Z'), '\x1A');
    });

    test('alt and shift on letters', () {
      expect(seq('Alt-b'), '\x1Bb');
      expect(seq('Shift-a'), 'A');
      expect(seq('Ctrl-Alt-c'), '\x1B\x03');
    });

    test('named keys, unmodified', () {
      expect(seq('Home'), '\x1B[H');
      expect(seq('End'), '\x1B[F');
      expect(seq('PgUp'), '\x1B[5~');
      expect(seq('PageDown'), '\x1B[6~');
      expect(seq('Up'), '\x1B[A');
      expect(seq('Del'), '\x1B[3~');
      expect(seq('F5'), '\x1B[15~');
      expect(seq('F1'), '\x1BOP');
    });

    test('modified navigation keys use the CSI convention', () {
      expect(seq('Ctrl-End'), '\x1B[1;5F');
      expect(seq('Ctrl-Home'), '\x1B[1;5H');
      expect(seq('Ctrl-Shift-End'), '\x1B[1;6F');
      expect(seq('Ctrl-Up'), '\x1B[1;5A');
      expect(seq('Ctrl-PgUp'), '\x1B[5;5~');
      expect(seq('Shift-Tab'), '\x1B[Z');
    });

    test('space, punctuation control codes, quoted literals, escapes', () {
      expect(seq('Space'), ' ');
      expect(seq('Ctrl-Space'), '\x00');
      expect(seq(r'Ctrl-['), '\x1B');
      expect(seq('"ls -la"'), 'ls -la');
      expect(seq(r'\x1b'), '\x1B');
      expect(seq('Esc Ctrl-C'), '\x1B\x03');
    });

    test('descriptions are human readable', () {
      expect(resolveKeySpec('Ctrl-End').description, 'Ctrl-End');
      expect(resolveKeySpec('ctrl-c').description, 'Ctrl-c');
      expect(resolveKeySpec('Home').description, 'Home');
    });

    test('unresolvable specs return an error, not garbage', () {
      expect(resolveKeySpec('').ok, isFalse);
      expect(resolveKeySpec('Frobnicate').ok, isFalse);
      expect(resolveKeySpec('Ctrl-Nonsense').ok, isFalse);
      expect(resolveKeySpec('Hyper-C').ok, isFalse);
      expect(resolveKeySpec('Ctrl-F5').ok, isFalse);
      expect(resolveKeySpec('Ctrl-Enter').ok, isFalse);
      expect(resolveKeySpec(r'\q').ok, isFalse);
    });
  });

  group('TerminalPadConfig', () {
    test('defaults reproduce the original two-row layout', () {
      final config = TerminalPadConfig.defaults();
      expect(config.rows.length, 2);
      expect(config.rows[0].middleIds, [
        'tab',
        'esc',
        'ctrl_c',
        'slash',
        'attach_file',
      ]);
      expect(config.rows[0].fixedRightId, 'backspace');
      expect(config.rows[1].middleIds, ['home', 'end', 'page_up', 'page_down']);
      expect(config.rows[1].fixedRightId, 'enter');
      expect(config.customKeys, isEmpty);
    });

    test('round-trips through encode/decode with a custom key', () {
      final config = TerminalPadConfig.defaults();
      config.customKeys.add(
        const TerminalPadKey(
          id: 'custom:1',
          abbreviation: 'C-z',
          name: 'Ctrl-Z',
          sequence: r'\x1a',
        ),
      );
      config.rows[0].middleIds.add('custom:1');
      config.rows[1].sortByFrequency = true;
      config.rows[1].fixedRightId = null;

      final restored = TerminalPadConfig.decode(config.encode());

      expect(restored.rows[0].middleIds.contains('custom:1'), isTrue);
      expect(restored.rows[1].sortByFrequency, isTrue);
      expect(restored.rows[1].fixedRightId, isNull);
      expect(restored.customKeys.single.abbreviation, 'C-z');
      expect(restored.customKeys.single.name, 'Ctrl-Z');
      expect(restored.customKeys.single.sequence, r'\x1a');
      expect(restored.customKeys.single.builtin, isFalse);
    });

    test('decode falls back to defaults on malformed input', () {
      final fallback = TerminalPadConfig.decode('not json');
      expect(fallback.rows.length, 2);
      expect(fallback.rows[0].fixedRightId, 'backspace');
    });

    test('decode backfills a second row when the blob is short', () {
      final restored = TerminalPadConfig.decode(
        '{"version":1,"customKeys":[],"rows":[{"middleIds":["tab"],'
        '"fixedRightId":null,"sortByFrequency":false}]}',
      );
      expect(restored.rows.length, 2);
      expect(restored.rows[1].middleIds, ['home', 'end', 'page_up', 'page_down']);
    });
  });
}
