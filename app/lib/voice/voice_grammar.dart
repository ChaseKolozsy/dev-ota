/// The passive-listening command grammar (docs/passive-voice-control.md).
///
/// Every utterance is either a command or dictation. It is a command only
/// when the WHOLE utterance matches one entry below exactly (after
/// normalisation); there is no fuzzy matching, so a command word inside a
/// longer sentence ("please submit the form") stays dictation.
library;

import '../terminal_pad_key.dart';

enum VoiceCommandKind {
  keys,
  enter,
  submit,
  slash,
  backspace,
  macroNumber,
  macroName,
  listMacros,
  window,
  whichWindow,
  scrollUp,
  scrollDown,
  scrollBottom,
  clearDraft,
  readBack,
  stopListening,
  openKeyboard,
  closeKeyboard,
  confirmYes,
  confirmNo,
}

class VoiceCommand {
  const VoiceCommand(
    this.kind,
    this.echo, {
    this.bytes,
    this.count,
    this.text,
    this.needsConfirm = false,
  });

  final VoiceCommandKind kind;

  /// A short spoken name for the command ("Control C", "Slash compact").
  final String echo;

  /// Raw key bytes for [VoiceCommandKind.keys].
  final String? bytes;

  /// Repeat count (backspace N, scroll N) or 1-based number (macro N,
  /// window N).
  final int? count;

  /// Slash command without the slash ("compact"), or a spoken macro name.
  final String? text;

  /// Asks "Say yes to confirm" before it runs: destructive commands, macros
  /// by position, and slash commands DevOTA does not know.
  final bool needsConfirm;

  @override
  String toString() =>
      'VoiceCommand($kind, "$echo", count: $count, text: $text, '
      'needsConfirm: $needsConfirm)';
}

/// Lowercases, strips punctuation, reads "/" as the word "slash", folds
/// ctrl / ctl to "control" and "back space" to "backspace". Number words are
/// NOT converted here; that happens only inside number slots.
List<String> voiceNormalize(String transcript) {
  var text = transcript.toLowerCase();
  text = text.replaceAll('/', ' slash ');
  text = text.replaceAll(RegExp(r"['’`]"), '');
  text = text.replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ');
  final tokens = <String>[];
  for (final raw in text.split(RegExp(r'\s+'))) {
    if (raw.isEmpty) continue;
    final t = switch (raw) {
      'ctrl' || 'ctl' => 'control',
      'nevermind' => 'never',
      _ => raw,
    };
    tokens.add(t);
    if (raw == 'nevermind') tokens.add('mind');
  }
  for (var i = 0; i + 1 < tokens.length; i++) {
    if (tokens[i] == 'back' && tokens[i + 1] == 'space') {
      tokens
        ..removeAt(i + 1)
        ..[i] = 'backspace';
    }
  }
  return tokens;
}

const _units = {
  'zero': 0,
  'one': 1,
  'won': 1,
  'two': 2,
  'to': 2,
  'too': 2,
  'three': 3,
  'four': 4,
  'for': 4,
  'fore': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'ate': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
};
const _tens = {
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

/// Parses a number starting at [start] and returns (value, tokens used)
/// candidates. The mishearings "to/too" -> 2 and "for" -> 4 are accepted
/// because this is only ever called inside a number slot.
List<(int, int)> voiceParseNumber(List<String> tokens, int start) {
  final out = <(int, int)>[];
  if (start >= tokens.length) return out;
  final t = tokens[start];
  if (RegExp(r'^\d{1,4}$').hasMatch(t)) return [(int.parse(t), 1)];
  final next = start + 1 < tokens.length ? tokens[start + 1] : null;
  if (t == 'hundred') return [(100, 1)];
  if (t == 'a') return next == 'hundred' ? [(100, 2)] : out;
  final ten = _tens[t];
  if (ten != null) {
    final unit = _units[next];
    if (unit != null &&
        unit > 0 &&
        unit < 10 &&
        !{'to', 'too', 'for'}.contains(next)) {
      out.add((ten + unit, 2));
    }
    out.add((ten, 1));
    return out;
  }
  final unit = _units[t];
  if (unit != null) {
    if (next == 'hundred' && unit > 0 && unit < 10) out.add((unit * 100, 2));
    out.add((unit, 1));
  }
  return out;
}

const _letterNames = {
  'see': 'c',
  'sea': 'c',
  'cee': 'c',
  'el': 'l',
  'ell': 'l',
  'are': 'r',
  'ar': 'r',
  'why': 'y',
  'you': 'u',
  'bee': 'b',
  'be': 'b',
  'dee': 'd',
  'gee': 'g',
  'jay': 'j',
  'kay': 'k',
  'em': 'm',
  'en': 'n',
  'pee': 'p',
  'queue': 'q',
  'cue': 'q',
  'tea': 't',
  'tee': 't',
  'vee': 'v',
  'ex': 'x',
  'zed': 'z',
  'zee': 'z',
  'eff': 'f',
  'ess': 's',
  'aitch': 'h',
  'eye': 'i',
  'oh': 'o',
};

String? _letter(String token) {
  if (RegExp(r'^[a-z]$').hasMatch(token)) return token;
  return _letterNames[token];
}

class _Captures {
  _Captures([_Captures? from]) {
    if (from != null) {
      nums.addAll(from.nums);
      letter = from.letter;
      rest = from.rest;
    }
  }
  final nums = <int>[];
  String? letter;
  List<String> rest = const [];
}

typedef _Build = VoiceCommand? Function(_Captures c);

class _Rule {
  _Rule(this.id, String pattern, this.build, {this.confirmOnly = false})
    : pattern = pattern.split(' ');
  final String id;
  final List<String> pattern;
  final _Build build;

  /// Only a command while a confirmation is pending; dictation otherwise.
  final bool confirmOnly;
  bool get wildcard => pattern.contains('*');
}

VoiceCommand _key(String echo, String bytes, {bool needsConfirm = false}) =>
    VoiceCommand(
      VoiceCommandKind.keys,
      echo,
      bytes: bytes,
      needsConfirm: needsConfirm,
    );

VoiceCommand _simple(
  VoiceCommandKind kind,
  String echo, {
  bool needsConfirm = false,
}) => VoiceCommand(kind, echo, needsConfirm: needsConfirm);

/// Slash commands that end or rewrite the session always ask first.
const _destructiveSlash = {'exit', 'clear', 'compact'};

/// Claude Code's built-in commands. Any other "slash `words`" is still sent
/// (custom commands exist) but only after a spoken confirmation, so a
/// sentence that happens to start with "slash" is never typed unasked.
const knownSlashCommands = {
  'add-dir',
  'agents',
  'bashes',
  'bug',
  'clear',
  'compact',
  'config',
  'context',
  'cost',
  'doctor',
  'exit',
  'export',
  'help',
  'hooks',
  'ide',
  'init',
  'install-github-app',
  'login',
  'logout',
  'mcp',
  'memory',
  'model',
  'output-style',
  'permissions',
  'plan',
  'pr-comments',
  'privacy-settings',
  'release-notes',
  'resume',
  'review',
  'rewind',
  'sandbox',
  'security-review',
  'status',
  'statusline',
  'terminal-setup',
  'todos',
  'upgrade',
  'usage',
  'vim',
};

VoiceCommand _slash(String word, {String? echo}) => VoiceCommand(
  VoiceCommandKind.slash,
  echo ?? 'Slash ${word.replaceAll('-', ' ')}',
  text: word,
  needsConfirm:
      _destructiveSlash.contains(word) || !knownSlashCommands.contains(word),
);

VoiceCommand? _arrow(String dir, String seq, _Captures c) {
  final n = c.nums.isEmpty ? 1 : c.nums.first;
  if (n < 1 || n > 20) return null;
  final name = 'Arrow $dir';
  return VoiceCommand(
    VoiceCommandKind.keys,
    n == 1 ? name : '$name $n times',
    bytes: List.filled(n, seq).join(),
    count: n,
  );
}

VoiceCommand? _backspace(_Captures c) {
  final n = c.nums.isEmpty ? 1 : c.nums.first;
  if (n < 1 || n > 200) return null;
  return VoiceCommand(
    VoiceCommandKind.backspace,
    n == 1 ? 'Backspace' : 'Backspace $n',
    count: n,
  );
}

VoiceCommand? _scroll(VoiceCommandKind kind, _Captures c) {
  final n = c.nums.isEmpty ? 15 : c.nums.first;
  if (n < 1 || n > 200) return null;
  return VoiceCommand(
    kind,
    kind == VoiceCommandKind.scrollUp ? 'Scroll up $n' : 'Scroll down $n',
    count: n,
  );
}

VoiceCommand? _ctrlLetter(_Captures c) {
  final l = c.letter;
  if (l == null) return null;
  final spec = resolveKeySpec('Ctrl-$l');
  if (!spec.ok || spec.sequence == null) return null;
  return VoiceCommand(
    VoiceCommandKind.keys,
    'Control ${l.toUpperCase()}',
    bytes: spec.sequence,
    needsConfirm: l == 'c' || l == 'd',
  );
}

final List<_Rule> _rules = [
  // Sending.
  for (final p in ['submit', 'send it'])
    _Rule('submit', p, (_) => _simple(VoiceCommandKind.submit, 'Submit')),
  for (final p in ['enter', 'press enter', 'enter key', 'return'])
    _Rule('enter', p, (_) => _simple(VoiceCommandKind.enter, 'Enter')),
  // Keys.
  for (final p in ['escape', 'escape key', 'esc', 'e s c'])
    _Rule('escape', p, (_) => _key('Escape', '\x1b')),
  for (final p in ['tab', 'tab key']) _Rule('tab', p, (_) => _key('Tab', '\t')),
  for (final p in ['shift tab', 'back tab'])
    _Rule('shift_tab', p, (_) => _key('Shift tab', '\x1b[Z')),
  _Rule('ctrl_home', 'control home', (_) => _key('Control home', '\x1b[1;5H')),
  _Rule('ctrl_end', 'control end', (_) => _key('Control end', '\x1b[1;5F')),
  _Rule('ctrl_letter', 'control L', _ctrlLetter),
  _Rule('page_up', 'page up', (_) => _key('Page up', '\x1b[5~')),
  _Rule('page_down', 'page down', (_) => _key('Page down', '\x1b[6~')),
  for (final (dir, seq) in [
    ('up', '\x1b[A'),
    ('down', '\x1b[B'),
    ('left', '\x1b[D'),
    ('right', '\x1b[C'),
  ])
    for (final p in [
      'arrow $dir',
      'arrow $dir N',
      'arrow $dir N times',
      '$dir arrow',
      '$dir arrow N times',
    ])
      _Rule('arrow_$dir', p, (c) => _arrow(dir, seq, c)),
  _Rule('option', 'option N', (c) {
    final n = c.nums.first;
    if (n < 1 || n > 9) return null;
    return _key('Option $n', '$n');
  }),
  for (final p in [
    'backspace',
    'backspace N',
    'backspace N characters',
    'backspace N times',
    'delete N characters',
  ])
    _Rule('backspace', p, _backspace),
  _Rule(
    'clear_line',
    'clear line',
    (_) => _key('Clear line', '\x15', needsConfirm: true),
  ),
  // Slash commands. A bare "exit" is Claude's /exit.
  for (final p in ['exit', 'exit claude', 'quit'])
    _Rule('slash_exit', p, (_) => _slash('exit', echo: 'Exit Claude')),
  _Rule('slash_compact', 'compact', (_) => _slash('compact')),
  _Rule('slash_clear', 'clear conversation', (_) => _slash('clear')),
  _Rule('slash_plan', 'plan mode', (_) => _slash('plan')),
  _Rule('slash_other', 'slash *', (c) {
    final word = c.rest.join('-');
    if (c.rest.length > 3) return null;
    if (!RegExp(r'^[a-z][a-z0-9-]{0,30}$').hasMatch(word)) return null;
    return _slash(word, echo: word == 'exit' ? 'Exit Claude' : null);
  }),
  // Macros.
  _Rule('macro_number', 'macro N', (c) {
    final n = c.nums.first;
    if (n < 1 || n > 99) return null;
    return VoiceCommand(
      VoiceCommandKind.macroNumber,
      'Macro $n',
      count: n,
      needsConfirm: true,
    );
  }),
  _Rule(
    'macro_name',
    'macro *',
    (c) => VoiceCommand(
      VoiceCommandKind.macroName,
      'Macro ${c.rest.join(' ')}',
      text: c.rest.join(' '),
    ),
  ),
  _Rule(
    'list_macros',
    'list macros',
    (_) => _simple(VoiceCommandKind.listMacros, 'Macros'),
  ),
  // Windows and scrolling.
  for (final p in ['window N', 'target N', 'switch to window N'])
    _Rule('window', p, (c) {
      final n = c.nums.first;
      if (n < 1 || n > 9) return null;
      return VoiceCommand(VoiceCommandKind.window, 'Window $n', count: n);
    }),
  _Rule(
    'which_window',
    'which window',
    (_) => _simple(VoiceCommandKind.whichWindow, 'Which window'),
  ),
  for (final p in ['scroll up', 'scroll up N', 'scroll up N lines'])
    _Rule('scroll_up', p, (c) => _scroll(VoiceCommandKind.scrollUp, c)),
  for (final p in ['scroll down', 'scroll down N', 'scroll down N lines'])
    _Rule('scroll_down', p, (c) => _scroll(VoiceCommandKind.scrollDown, c)),
  for (final p in ['scroll to bottom', 'scroll to the bottom', 'scroll bottom'])
    _Rule(
      'scroll_bottom',
      p,
      (_) => _simple(VoiceCommandKind.scrollBottom, 'Bottom'),
    ),
  // The draft.
  for (final p in ['clear draft', 'clear the draft'])
    _Rule(
      'clear_draft',
      p,
      (_) => _simple(
        VoiceCommandKind.clearDraft,
        'Clear draft',
        needsConfirm: true,
      ),
    ),
  for (final p in ['read it back', 'read back', 'read the draft', 'read draft'])
    _Rule(
      'read_back',
      p,
      (_) => _simple(VoiceCommandKind.readBack, 'Read back'),
    ),
  // Listening and the app.
  _Rule(
    'stop_listening',
    'stop listening',
    (_) => _simple(VoiceCommandKind.stopListening, 'Stopped listening'),
  ),
  for (final p in ['open keyboard', 'show keyboard'])
    _Rule(
      'open_keyboard',
      p,
      (_) => _simple(VoiceCommandKind.openKeyboard, 'Keyboard open'),
    ),
  for (final p in ['close keyboard', 'hide keyboard'])
    _Rule(
      'close_keyboard',
      p,
      (_) => _simple(VoiceCommandKind.closeKeyboard, 'Keyboard closed'),
    ),
  // Confirmation answers: commands only while a confirmation is pending.
  for (final p in ['yes', 'yeah', 'yep', 'confirm', 'yes confirm'])
    _Rule(
      'yes',
      p,
      (_) => _simple(VoiceCommandKind.confirmYes, 'Yes'),
      confirmOnly: true,
    ),
  for (final p in ['no', 'nope', 'cancel', 'never mind', 'no cancel'])
    _Rule(
      'no',
      p,
      (_) => _simple(VoiceCommandKind.confirmNo, 'Cancelled'),
      confirmOnly: true,
    ),
];

List<_Captures> _match(List<String> pattern, List<String> tokens) {
  final results = <_Captures>[];
  void walk(int pi, int ti, _Captures c) {
    if (pi == pattern.length) {
      if (ti == tokens.length) results.add(c);
      return;
    }
    final p = pattern[pi];
    if (p == 'N') {
      for (final (value, used) in voiceParseNumber(tokens, ti)) {
        walk(pi + 1, ti + used, _Captures(c)..nums.add(value));
      }
      return;
    }
    if (p == 'L') {
      if (ti >= tokens.length) return;
      final l = _letter(tokens[ti]);
      if (l != null) walk(pi + 1, ti + 1, _Captures(c)..letter = l);
      return;
    }
    if (p == '*') {
      if (pi != pattern.length - 1 || ti >= tokens.length) return;
      walk(
        pattern.length,
        tokens.length,
        _Captures(c)..rest = tokens.sublist(ti),
      );
      return;
    }
    if (ti < tokens.length && tokens[ti] == p) walk(pi + 1, ti + 1, c);
  }

  walk(0, 0, _Captures());
  return results;
}

/// The command a whole utterance names, or null when it is dictation.
///
/// [confirming] is true while a needsConfirm command waits for "yes"; only
/// then are yes / no / cancel commands (otherwise they are dictation, since
/// they are also ordinary answers to the agent).
VoiceCommand? parseVoiceCommand(String transcript, {bool confirming = false}) {
  final tokens = voiceNormalize(transcript);
  if (tokens.isEmpty || tokens.length > 8) return null;
  final literal = <String, VoiceCommand>{};
  final wild = <String, VoiceCommand>{};
  for (final rule in _rules) {
    if (rule.confirmOnly && !confirming) continue;
    for (final captures in _match(rule.pattern, tokens)) {
      final command = rule.build(captures);
      if (command == null) continue;
      (rule.wildcard ? wild : literal).putIfAbsent(rule.id, () => command);
    }
  }
  // A fixed phrase outranks a wildcard ("macro 3" is macro number 3, not a
  // macro named "3"). Two different fixed phrases never both match one
  // utterance; if they ever did, the utterance stays dictation.
  if (literal.length == 1) return literal.values.single;
  if (literal.isEmpty && wild.length == 1) return wild.values.single;
  return null;
}

/// Short phrases for the notification and the on-screen help.
const voiceHelpText =
    'Say: submit · enter · escape · control C · tab · backspace 5 · '
    'scroll up · page up · macro 2 · slash compact · exit · window 2 · '
    'read it back · clear draft · stop listening. '
    'Anything else is added to the draft.';
