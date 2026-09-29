/// "read screen" and "read reply": what voice control speaks from the lines
/// the Terminal tab is showing.
///
/// Input is the tab's own terminal buffer, one string per visible row, exactly
/// as it renders (no SSH, no tmux capture). Everything here is pure so the
/// tests can run it on real captured screens.
///
/// Two TUIs are recognized from the screen itself:
///
///  * Claude Code: every block starts with `●` (`⏺` on macOS). The input box
///    is a `❯` (older versions `>`) line with a rule line directly above it;
///    under it sit the footer (`⏵⏵ bypass permissions on (shift+tab to
///    cycle)`, `? for shortcuts`) and the agent-status list (`● main`,
///    `◯ title-audit-lane …`).
///  * Codex CLI: every block starts with `•`, tool output hangs off `└`. The
///    input box is a `›` line near the bottom, followed by the footer (the
///    model line and `? for shortcuts` / `esc to interrupt`).
///
/// "read reply" speaks the latest answer: the last text block (tool-summary
/// blocks such as `● Bash(…)` or `• Ran …` are skipped, output and all) down to
/// the input box. On any other screen it reads the screen.
library;

enum TerminalTui { claudeCode, codex, other }

/// What a read command found: the TUI it recognized and the text to speak
/// (empty when there is nothing to read).
class ScreenReading {
  const ScreenReading(this.tui, this.text);
  final TerminalTui tui;
  final String text;
  bool get isEmpty => text.trim().isEmpty;
}

final _ansi = RegExp(
  r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-_]',
);
final _controls = RegExp(r'[\x00-\x08\x0b-\x1f\x7f]');

/// Box-drawing, block and rule characters.
const _ruleChars =
    '─━═│┃┄┅┆┇┈┉┊┋╌╍╎╏┌┐└┘├┤┬┴┼╭╮╰╯┏┓┗┛┣┫┳┻╋╔╗╚╝╠╣╦╩╬║▀▄█▌▐░▒▓▔▁▏▕';

final _ruleOnly = RegExp('^[\\s$_ruleChars\\-_=~]*\$');
final _ruleRun = RegExp('[$_ruleChars]{3,}');
final _sideBorders = RegExp('^\\s*[│┃║]\\s?|\\s?[│┃║]\\s*\$');

/// Strips escape sequences and control characters, keeps everything else.
String stripAnsi(String line) =>
    line.replaceAll(_ansi, '').replaceAll(_controls, '').replaceAll('\r', '');

/// A line made only of box-drawing or rule characters (and spaces).
bool isRuleLine(String line) {
  final t = line.trim();
  return t.isNotEmpty && _ruleOnly.hasMatch(t);
}

/// The tmux status bar: `[session] 0:node- 1:claude*  "host" 04:40 29-Sep-26`.
bool isTmuxStatusLine(String line) {
  final t = line.trim();
  // The default status-left "[session] ", then the window list "0:name*".
  if (RegExp(r'^\[[^\]]{1,40}\]\s+\d+:\S').hasMatch(t)) return true;
  // No status-left: the window list, and the default clock on the right.
  return RegExp(r'^\d+:\S').hasMatch(t) &&
      RegExp(r'\d{1,2}:\d\d \d{1,2}-[A-Z][a-z]{2}-\d\d$').hasMatch(t);
}

// --- Claude Code -------------------------------------------------------------

final _claudePrompt = RegExp(r'^\s*(?:❯|>)(?:\s|$)');
final _claudeBoxPrompt = RegExp(r'^\s*[│┃]\s*(?:❯|>)(?:\s|$)');
final _claudeBullet = RegExp(r'^\s{0,2}[●⏺]\s?');
final _claudeFooter = RegExp(
  r'bypass permissions|shift\+tab to cycle|\? for shortcuts|'
  r'accept edits on|plan mode on|auto-accept edits|esc to interrupt|'
  r'ctrl\+o to expand|for agents|to manage|context left until auto-compact',
  caseSensitive: false,
);

/// Claude's spinner / work line above the box: `✻ Waiting for 5 background
/// agents to finish`, `✽ Thinking… (12s · esc to interrupt)`, `✻ Worked for 3m`.
final _claudeSpinner = RegExp(r'^\s*[·✢✳✶✻✽*]\s+\S');

/// `● Bash(git status)`, `● Web Search("x")`, `● devota - android_tap (MCP)(x)`,
/// `● Read 3 files (ctrl+o to expand)`.
final _claudeToolHead = RegExp(
  r'^(?:[A-Z][A-Za-z]*(?: [A-Z][A-Za-z]*)*|[a-z][\w-]*(?: - [\w-]+)?(?: \(MCP\))?)\(',
);

/// Index of the rule line above Claude's input box, or null.
int? _claudeInputBox(List<String> lines) {
  for (var i = lines.length - 1; i > 0; i--) {
    final line = lines[i];
    if (_claudePrompt.hasMatch(line) && isRuleLine(lines[i - 1])) return i - 1;
    // Older builds: ╭───╮ / │ > │ / ╰───╯
    if (_claudeBoxPrompt.hasMatch(line) &&
        RegExp(r'^\s*╭').hasMatch(lines[i - 1])) {
      return i - 1;
    }
  }
  return null;
}

// --- Codex CLI ---------------------------------------------------------------

final _codexPrompt = RegExp(r'^\s*›(?:\s|$)');
final _codexBullet = RegExp(r'^\s{0,2}•\s?');
final _codexFooter = RegExp(
  r'\? for shortcuts|esc to interrupt|context left|for agents|'
  r'ctrl\+j newline|tab to queue|send\s+·|to send',
  caseSensitive: false,
);

/// Codex tool blocks: most hang their output off `└`; these are recognized by
/// their head alone (running, waiting, planning, patch summaries).
final _codexToolHead = RegExp(
  r'^(?:Working|Running|Waiting|Waited|Exploring|Explored|Calling|Called|'
  r'Updated Plan|Proposed Change|Change Approved|Change Rejected|'
  r'Viewed Image)\b|'
  r'^(?:Edited|Added|Deleted)\s+(?:\S+|\d+ files?)\s+\(\+\d+ -\d+\)',
);
final _codexWorked = RegExp(r'^\s*[─━\s]*Worked for \d', caseSensitive: false);

/// Index of Codex's `›` input line, or null. It must be the last `›` line and
/// have the footer under it, so an approval menu (`› 1. Yes, proceed`) with its
/// own hint line does not count.
int? _codexInputBox(List<String> lines) {
  for (var i = lines.length - 1; i >= 0; i--) {
    if (!_codexPrompt.hasMatch(lines[i])) continue;
    final after = lines.sublist(i + 1).where((l) => l.trim().isNotEmpty);
    if (after.any(_codexFooter.hasMatch) && after.length <= 8) return i;
    return null;
  }
  return null;
}

// --- Both --------------------------------------------------------------------

/// Cleans a raw screen: escape codes gone, the tmux status bar dropped, and
/// trailing blank rows removed.
List<String> _clean(List<String> raw) {
  final lines = [for (final l in raw) stripAnsi(l).trimRight()];
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isNotEmpty && isTmuxStatusLine(lines.last)) lines.removeLast();
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return lines;
}

TerminalTui detectTui(List<String> screen) {
  final lines = _clean(screen);
  if (_claudeInputBox(lines) != null) return TerminalTui.claudeCode;
  if (_codexInputBox(lines) != null) return TerminalTui.codex;
  return TerminalTui.other;
}

/// One spoken line: leading bullets and box sides gone, rule runs gone,
/// whitespace collapsed.
String _speakable(String line) {
  var t = line.replaceAll(_sideBorders, ' ');
  t = t.replaceAll(_ruleRun, ' ');
  t = t.replaceFirst(RegExp(r'^\s*[●⏺•◯◉○⎿└├›❯✻✽✶✳✢⏵]+\s*'), '');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Joins spoken lines into paragraphs, one per output line. A row runs on
/// into the next only when it was wrapped: it reached within a word's length
/// of the screen's [width]. Anything shorter (a shell line, a heading, the
/// end of a paragraph), a list item, or a blank row starts a new paragraph.
String _join(Iterable<String> rows, int width) {
  final paragraphs = <String>[];
  var current = <String>[];
  var wrapped = false;
  void flush() {
    if (current.isNotEmpty) paragraphs.add(current.join(' '));
    current = [];
  }

  for (final raw in rows) {
    var line = _speakable(raw);
    final item = RegExp(r'^(?:[-*+]|\d+[.)])\s+').firstMatch(line);
    if (item != null || !wrapped) flush();
    if (item != null && !line.startsWith(RegExp(r'\d'))) {
      line = line.substring(item.end);
    }
    wrapped = raw.trimRight().length >= width - _wrapSlack;
    if (line.isEmpty) {
      flush();
      continue;
    }
    current.add(line);
  }
  flush();
  return paragraphs.join('\n');
}

/// How far short of the right edge a wrapped row can end (the next word did
/// not fit).
const _wrapSlack = 14;

int _width(List<String> lines) =>
    lines.fold(0, (w, l) => l.length > w ? l.length : w);

/// The screen above the input box (the whole screen when there is none),
/// without rule lines or footer hints.
List<String> _body(List<String> lines, TerminalTui tui) {
  switch (tui) {
    case TerminalTui.claudeCode:
      return lines.sublist(0, _claudeInputBox(lines)!);
    case TerminalTui.codex:
      return lines.sublist(0, _codexInputBox(lines)!);
    case TerminalTui.other:
      return lines;
  }
}

bool _isChrome(String line, TerminalTui tui) {
  if (isRuleLine(line)) return true;
  final t = line.trim();
  switch (tui) {
    case TerminalTui.claudeCode:
      return _claudeFooter.hasMatch(t) && !_claudeBullet.hasMatch(line);
    case TerminalTui.codex:
      return (_codexFooter.hasMatch(t) && !_codexBullet.hasMatch(line)) ||
          t == '+ Show details';
    case TerminalTui.other:
      return false;
  }
}

/// "read screen": every visible line except rules, the tmux status bar, and
/// the input box with its footer.
ScreenReading readScreen(List<String> screen) {
  final lines = _clean(screen);
  final tui = detectTui(lines);
  final body = _body(lines, tui).where((l) => !_isChrome(l, tui));
  return ScreenReading(tui, _join(body, _width(lines)));
}

/// "read reply": the latest answer. Falls back to [readScreen] on a screen
/// that is neither Claude Code nor Codex.
ScreenReading readReply(List<String> screen) {
  final lines = _clean(screen);
  final tui = detectTui(lines);
  switch (tui) {
    case TerminalTui.other:
      return readScreen(lines);
    case TerminalTui.claudeCode:
      return ScreenReading(
        tui,
        _join(
          _lastReply(
            _body(lines, tui),
            bullet: _claudeBullet,
            isTool: _isClaudeTool,
            isUserPrompt: _claudePrompt.hasMatch,
            isStatus: _claudeSpinner.hasMatch,
          ),
          _width(lines),
        ),
      );
    case TerminalTui.codex:
      return ScreenReading(
        tui,
        _join(
          _lastReply(
            _body(lines, tui),
            bullet: _codexBullet,
            isTool: _isCodexTool,
            isUserPrompt: _codexPrompt.hasMatch,
            isStatus: _codexWorked.hasMatch,
          ),
          _width(lines),
        ),
      );
  }
}

bool _isClaudeTool(List<String> block) {
  final head = block.first.replaceFirst(_claudeBullet, '').trim();
  if (_claudeToolHead.hasMatch(head)) return true;
  if (head.contains('(ctrl+o to expand)')) return true;
  return block.skip(1).any((l) => l.trimLeft().startsWith('⎿'));
}

bool _isCodexTool(List<String> block) {
  final head = block.first.replaceFirst(_codexBullet, '').trim();
  if (_codexToolHead.hasMatch(head)) return true;
  final next = block
      .skip(1)
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  return next.trimLeft().startsWith('└') || next.trimLeft().startsWith('│');
}

/// The rows of the last text block and everything after it that is still
/// text; tool blocks, spinner/status lines and anything from a later user
/// prompt on are dropped.
List<String> _lastReply(
  List<String> body, {
  required RegExp bullet,
  required bool Function(List<String>) isTool,
  required bool Function(String) isUserPrompt,
  required bool Function(String) isStatus,
}) {
  // Split the body into blocks, each starting at a bullet or a user prompt.
  final blocks = <({int start, List<String> rows, bool prompt})>[];
  for (var i = 0; i < body.length; i++) {
    final line = body[i];
    final startsBlock = bullet.hasMatch(line) || isUserPrompt(line);
    if (startsBlock || blocks.isEmpty) {
      blocks.add((start: i, rows: [line], prompt: isUserPrompt(line)));
    } else {
      blocks.last.rows.add(line);
    }
  }
  var from = -1;
  for (var b = blocks.length - 1; b >= 0; b--) {
    final block = blocks[b];
    if (!bullet.hasMatch(block.rows.first)) continue;
    if (isTool(block.rows)) continue;
    from = b;
    break;
  }
  if (from < 0) {
    // The reply's own bullet scrolled off the top: read the text that is left.
    if (blocks.isEmpty ||
        blocks.first.prompt ||
        bullet.hasMatch(blocks.first.rows.first)) {
      return const [];
    }
    from = 0;
  }
  final out = <String>[];
  for (var b = from; b < blocks.length; b++) {
    final block = blocks[b];
    if (block.prompt) break;
    if (b != from &&
        (!bullet.hasMatch(block.rows.first) || isTool(block.rows))) {
      continue;
    }
    for (final row in block.rows) {
      if (isStatus(row)) break;
      out.add(row);
    }
  }
  return out;
}

/// Splits [text] into pieces of at most about [maxChars], at sentence or line
/// ends where it can, so each piece is one short stretch of speech and "stop
/// reading" is heard between them.
List<String> speechChunks(String text, {int maxChars = 320}) {
  final pieces = <String>[];
  for (final paragraph in text.split('\n')) {
    final p = paragraph.trim();
    if (p.isEmpty) continue;
    final sentences = p
        .split(RegExp(r'(?<=[.!?:;])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    // A paragraph that ends without punctuation (a heading, a list item)
    // still gets a pause after it.
    if (sentences.isNotEmpty &&
        !RegExp(r'[.!?:;…]$').hasMatch(sentences.last)) {
      sentences.last = '${sentences.last}.';
    }
    pieces.addAll(sentences);
  }
  final chunks = <String>[];
  var current = '';
  void flush() {
    if (current.isNotEmpty) chunks.add(current);
    current = '';
  }

  for (var piece in pieces) {
    while (piece.length > maxChars) {
      var cut = piece.lastIndexOf(' ', maxChars);
      if (cut < maxChars ~/ 3) cut = maxChars;
      flush();
      chunks.add(piece.substring(0, cut).trim());
      piece = piece.substring(cut).trim();
    }
    if (piece.isEmpty) continue;
    if (current.isEmpty) {
      current = piece;
    } else if (current.length + 1 + piece.length <= maxChars) {
      current = '$current $piece';
    } else {
      flush();
      current = piece;
    }
  }
  flush();
  return chunks;
}
