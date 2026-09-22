import 'terminal_macro.dart';

/// A following explicit Enter owns submission, even across Wait steps. Older
/// Command-only macros still submit once. This avoids LF + CR double submits.
bool commandNeedsEnter(List<TerminalMacroStep> steps, int index) {
  for (final next in steps.skip(index + 1)) {
    if (next.type == TerminalMacroStepType.wait) continue;
    return next.type != TerminalMacroStepType.terminalKey ||
        next.value != 'enter';
  }
  return true;
}

const terminalPasteSettleTime = Duration(milliseconds: 200);

String? terminalKeySequence(String value) => switch (value) {
  'enter' => '\r',
  'backspace' => '\x7f',
  'ctrl_b' => '\x02',
  'ctrl_c' => '\x03',
  'tab' => '\t',
  'esc' => '\x1b',
  'slash' => '/',
  'home' => '\x1b[H',
  'end' => '\x1b[F',
  'page_up' => '\x1b[5~',
  'page_down' => '\x1b[6~',
  'up' => '\x1b[A',
  'down' => '\x1b[B',
  'right' => '\x1b[C',
  'left' => '\x1b[D',
  '0' || '1' || '2' || '3' || '4' || '5' || '6' || '7' || '8' || '9' => value,
  _ => null,
};
