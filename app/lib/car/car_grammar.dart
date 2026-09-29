import '../terminal_pad_key.dart';

/// What a spoken command asks for (proposal §8.2).
enum CarCommandKind {
  keys,
  enter,
  submit,
  slash,
  backspace,
  macroNumber,
  macroName,
  listMacros,
  read,
  earlier,
  stopReading,
  status,
  window,
  scrollUp,
  scrollDown,
  scrollMore,
  scrollBottom,
  ui,
  done,
  repeat,
  cancel,
  scratch,
  privacyOn,
  privacyOff,
  carModeOff,
  takeButtons,
  help,
  confirmYes,
  confirmNo,
}

enum CarUiCommand {
  openKeyboard,
  closeKeyboard,
  maximize,
  minimize,
  openTools,
  collapseTools,
}

class CarCommand {
  const CarCommand(
    this.kind,
    this.echo, {
    this.bytes,
    this.count,
    this.text,
    this.ui,
    this.destructive = false,
  });

  final CarCommandKind kind;

  /// Spoken before or with the action. Always non-empty (§12 S5).
  final String echo;

  /// Raw bytes for [CarCommandKind.keys] (and one backspace for
  /// [CarCommandKind.backspace]).
  final String? bytes;

  /// Repeat count (backspace N, scroll N) or 1-based number (macro N,
  /// window N).
  final int? count;

  /// Slash command word(s) without the slash, or a spoken macro name.
  final String? text;
  final CarUiCommand? ui;

  /// Inherently destructive (§8.6). The controller still applies the
  /// owner's confirmation switches.
  final bool destructive;

  @override
  String toString() =>
      'CarCommand($kind, "$echo", count: $count, text: $text, destructive: $destructive)';
}

class CarParse {
  const CarParse.ok(CarCommand this.command) : error = null;
  const CarParse.error(String this.error) : command = null;
  final CarCommand? command;
  final String? error;
  bool get ok => command != null;
}

const carDidntCatch = "Didn't catch that";

/// Normalises a recognizer transcript: lowercase, punctuation stripped,
/// a leading or inner "/" read as the word "slash", and control / ctrl / ctl
/// folded to "control". Number words are NOT converted here; that happens
/// only inside number slots (§8.2).
List<String> carNormalize(String transcript) {
  var text = transcript.toLowerCase();
  text = text.replaceAll('/', ' slash ');
  text = text.replaceAll('+', ' plus ');
  text = text.replaceAll('?', ' question mark ');
  text = text.replaceAll(RegExp(r"['’`]"), '');
  text = text.replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ');
  final tokens = text
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .map((t) => switch (t) {
            'ctrl' || 'ctl' => 'control',
            'nevermind' => 'never mind',
            _ => t,
          })
      .expand((t) => t.split(' '))
      .toList();
  // "question mark" appended by "?" after a spoken "question mark" would
  // double; collapse exact duplicates of that phrase.
  for (var i = 0; i + 3 < tokens.length; i++) {
    if (tokens[i] == 'question' &&
        tokens[i + 1] == 'mark' &&
        tokens[i + 2] == 'question' &&
        tokens[i + 3] == 'mark') {
      tokens.removeRange(i + 2, i + 4);
    }
  }
  return tokens;
}

const _units = {
  'zero': 0, 'oh': 0, 'one': 1, 'won': 1, 'two': 2, 'to': 2, 'too': 2,
  'three': 3, 'four': 4, 'for': 4, 'fore': 4, 'five': 5, 'six': 6,
  'seven': 7, 'eight': 8, 'ate': 8, 'nine': 9, 'ten': 10, 'eleven': 11,
  'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15,
  'sixteen': 16, 'seventeen': 17, 'eighteen': 18, 'nineteen': 19,
};
const _tens = {
  'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50, 'sixty': 60,
  'seventy': 70, 'eighty': 80, 'ninety': 90,
};

/// Parses a number starting at [start]. Returns (value, tokens consumed)
/// candidates, longest first. Mishearings "to/too" -> 2 and "for" -> 4 are
/// accepted here because this is only ever called inside a number slot.
List<(int, int)> carParseNumber(List<String> tokens, int start) {
  final out = <(int, int)>[];
  if (start >= tokens.length) return out;
  final t = tokens[start];
  if (RegExp(r'^\d{1,4}$').hasMatch(t)) {
    out.add((int.parse(t), 1));
    return out;
  }
  int? base;
  var used = 0;
  if (t == 'a' || t == 'one' || t == 'hundred') {
    // "a hundred", "one hundred", "hundred"
    if (t == 'hundred') {
      out.add((100, 1));
    } else if (start + 1 < tokens.length && tokens[start + 1] == 'hundred') {
      out.add((100, 2));
    }
    if (t != 'one') return out;
  }
  if (_tens.containsKey(t)) {
    base = _tens[t]!;
    used = 1;
    if (start + 1 < tokens.length) {
      final u = _units[tokens[start + 1]];
      if (u != null && u > 0 && u < 10) out.add((base + u, 2));
    }
    out.add((base, used));
    return out;
  }
  final unit = _units[t];
  if (unit != null) {
    if (start + 1 < tokens.length && tokens[start + 1] == 'hundred' &&
        unit > 0 && unit < 10) {
      out.add((unit * 100, 2));
    }
    out.add((unit, 1));
  }
  return out;
}

const _letterNames = {
  'see': 'c', 'sea': 'c', 'cee': 'c', 'el': 'l', 'ell': 'l', 'are': 'r',
  'ar': 'r', 'why': 'y', 'you': 'u', 'bee': 'b', 'be': 'b', 'dee': 'd',
  'gee': 'g', 'jay': 'j', 'kay': 'k', 'em': 'm', 'en': 'n', 'pee': 'p',
  'queue': 'q', 'cue': 'q', 'tea': 't', 'tee': 't', 'vee': 'v', 'ex': 'x',
  'zed': 'z', 'zee': 'z', 'eff': 'f', 'ess': 's', 'aitch': 'h', 'eye': 'i',
  'oh': 'o', 'double you': 'w',
};

String? _letter(String token) {
  if (RegExp(r'^[a-z]$').hasMatch(token)) return token;
  return _letterNames[token];
}

typedef _Build = CarCommand? Function(_Captures c);

class _Captures {
  final nums = <int>[];
  String? letter;
  List<String> rest = const [];
}

class _Rule {
  _Rule(this.id, String pattern, this.build, {this.fuzzy = true})
    : pattern = pattern.split(' ');
  final String id;
  final List<String> pattern;
  final _Build build;
  final bool fuzzy;
  bool get literal => pattern.every((p) => !_slots.contains(p));
}

const _slots = {'N', 'L', '*'};

String _repeat(String s, int n) => List.filled(n, s).join();

CarCommand _key(String echo, String bytes, {bool destructive = false}) =>
    CarCommand(CarCommandKind.keys, echo, bytes: bytes, destructive: destructive);

CarCommand? _arrow(String dir, String seq, _Captures c) {
  final n = c.nums.isEmpty ? 1 : c.nums.first;
  if (n < 1 || n > 20) return null;
  final name = '${dir[0].toUpperCase()}${dir.substring(1)}';
  return CarCommand(
    CarCommandKind.keys,
    n == 1 ? name : '$name $n times',
    bytes: _repeat(seq, n),
    count: n,
  );
}

CarCommand? _backspace(_Captures c) {
  final n = c.nums.isEmpty ? 1 : c.nums.first;
  if (n < 1 || n > 200) return null;
  return CarCommand(
    CarCommandKind.backspace,
    n == 1 ? 'Backspace' : 'Backspace $n',
    bytes: '\x7f',
    count: n,
    destructive: n > 30,
  );
}

CarCommand? _scroll(CarCommandKind kind, _Captures c) {
  final n = c.nums.isEmpty ? 15 : c.nums.first;
  if (n < 1 || n > 200) return null;
  return CarCommand(
    kind,
    kind == CarCommandKind.scrollUp ? 'Scroll up $n' : 'Scroll down $n',
    count: n,
  );
}

CarCommand? _ctrlLetter(_Captures c) {
  final l = c.letter;
  if (l == null) return null;
  final spec = resolveKeySpec('Ctrl-$l');
  if (!spec.ok || spec.sequence == null) return null;
  return CarCommand(
    CarCommandKind.keys,
    'Control ${l.toUpperCase()}',
    bytes: spec.sequence,
    destructive: l == 'c' || l == 'd',
  );
}

CarCommand _slash(String word, {String? echo}) => CarCommand(
  CarCommandKind.slash,
  echo ?? 'Slash $word',
  text: word,
);

CarCommand _ui(CarUiCommand ui, String echo) =>
    CarCommand(CarCommandKind.ui, echo, ui: ui);

CarCommand _simple(CarCommandKind kind, String echo, {bool destructive = false}) =>
    CarCommand(kind, echo, destructive: destructive);

final List<_Rule> _rules = [
  // Keys.
  _Rule('tab', 'tab', (_) => _key('Tab', '\t')),
  _Rule('tab', 'tab key', (_) => _key('Tab', '\t')),
  _Rule('shift_tab', 'shift tab', (_) => _key('Shift tab', '\x1b[Z')),
  _Rule('shift_tab', 'back tab', (_) => _key('Shift tab', '\x1b[Z')),
  // "escape" is accepted only exactly (§8.3), never by fuzzy match.
  _Rule('escape', 'escape', (_) => _key('Escape', '\x1b'), fuzzy: false),
  _Rule('escape', 'escape key', (_) => _key('Escape', '\x1b'), fuzzy: false),
  _Rule('escape', 'e s c', (_) => _key('Escape', '\x1b'), fuzzy: false),
  _Rule('escape', 'esc', (_) => _key('Escape', '\x1b'), fuzzy: false),
  _Rule('enter', 'enter', (_) => _simple(CarCommandKind.enter, 'Enter')),
  _Rule('enter', 'return', (_) => _simple(CarCommandKind.enter, 'Enter')),
  _Rule('enter', 'press enter', (_) => _simple(CarCommandKind.enter, 'Enter')),
  _Rule('submit', 'submit', (_) => _simple(CarCommandKind.submit, 'Submit')),
  _Rule('submit', 'send', (_) => _simple(CarCommandKind.submit, 'Submit')),
  _Rule('submit', 'send it', (_) => _simple(CarCommandKind.submit, 'Submit')),
  _Rule('ctrl_c', 'interrupt', (_) => _key('Control C', '\x03', destructive: true)),
  _Rule('ctrl_home', 'control home', (_) => _key('Control home', '\x1b[1;5H')),
  _Rule('ctrl_end', 'control end', (_) => _key('Control end', '\x1b[1;5F')),
  _Rule('ctrl_letter', 'control L', _ctrlLetter),
  _Rule('slash_key', 'forward slash', (_) => _key('Slash', '/')),
  _Rule('slash_key', 'slash', (_) => _key('Slash', '/'), fuzzy: false),
  _Rule('plus', 'plus', (_) => _key('Plus', '+')),
  _Rule('minus', 'minus', (_) => _key('Minus', '-')),
  _Rule('minus', 'dash', (_) => _key('Minus', '-')),
  _Rule('minus', 'hyphen', (_) => _key('Minus', '-')),
  _Rule('question', 'question mark', (_) => _key('Question mark', '?')),
  _Rule('space', 'space', (_) => _key('Space', ' ')),
  for (final word in ['option', 'choose', 'number'])
    _Rule('option', '$word N', (c) {
      final n = c.nums.first;
      if (n < 1 || n > 9) return null;
      return _key('Option $n', '$n');
    }),
  for (final (dir, seq) in [
    ('up', '\x1b[A'),
    ('down', '\x1b[B'),
    ('left', '\x1b[D'),
    ('right', '\x1b[C'),
  ]) ...[
    _Rule('arrow_$dir', dir, (c) => _arrow(dir, seq, c), fuzzy: false),
    _Rule('arrow_$dir', '$dir N', (c) => _arrow(dir, seq, c)),
    _Rule('arrow_$dir', '$dir N times', (c) => _arrow(dir, seq, c)),
    _Rule('arrow_$dir', 'arrow $dir', (c) => _arrow(dir, seq, c)),
    _Rule('arrow_$dir', 'arrow $dir N', (c) => _arrow(dir, seq, c)),
    _Rule('arrow_$dir', 'arrow $dir N times', (c) => _arrow(dir, seq, c)),
  ],
  _Rule('home', 'home', (_) => _key('Home', '\x1b[H'), fuzzy: false),
  _Rule('end', 'end', (_) => _key('End', '\x1b[F'), fuzzy: false),
  _Rule('page_up', 'page up', (_) => _key('Page up', '\x1b[5~')),
  _Rule('page_up', 'pg up', (_) => _key('Page up', '\x1b[5~')),
  _Rule('page_down', 'page down', (_) => _key('Page down', '\x1b[6~')),
  _Rule('page_down', 'pg down', (_) => _key('Page down', '\x1b[6~')),
  _Rule('backspace', 'backspace', _backspace, fuzzy: false),
  _Rule('backspace', 'backspace N', _backspace),
  _Rule('backspace', 'backspace N characters', _backspace),
  _Rule('backspace', 'delete N', _backspace),
  _Rule('backspace', 'delete N characters', _backspace),
  _Rule('backspace', 'back N', _backspace),
  _Rule('clear_line', 'clear line', (_) => _key('Clear line', '\x15', destructive: true)),
  // Slash commands. Bare synonyms map to the named slash command; "exit"
  // is never a mode-exit word (§8.1).
  _Rule('slash_exit', 'exit', (_) => _slash('exit', echo: 'Exit Claude')),
  _Rule('slash_exit', 'exit claude', (_) => _slash('exit', echo: 'Exit Claude')),
  _Rule('slash_exit', 'quit', (_) => _slash('exit', echo: 'Exit Claude')),
  _Rule('slash_compact', 'compact', (_) => _slash('compact')),
  _Rule('slash_clear', 'clear conversation', (_) => _slash('clear')),
  _Rule('slash_plan', 'plan', (_) => _slash('plan')),
  _Rule('slash_plan', 'plan mode', (_) => _slash('plan')),
  _Rule('slash_other', 'slash *', (c) {
    final word = c.rest.join('-');
    if (!RegExp(r'^[a-z][a-z0-9-]{0,30}$').hasMatch(word)) return null;
    return _slash(word, echo: word == 'exit' ? 'Exit Claude' : 'Slash ${c.rest.join(' ')}');
  }, fuzzy: false),
  // Macros.
  _Rule('macro_number', 'macro N', (c) {
    final n = c.nums.first;
    if (n < 1 || n > 99) return null;
    return CarCommand(CarCommandKind.macroNumber, 'Macro $n', count: n);
  }),
  _Rule('macro_name', 'macro *', (c) {
    return CarCommand(
      CarCommandKind.macroName,
      'Macro ${c.rest.join(' ')}',
      text: c.rest.join(' '),
    );
  }, fuzzy: false),
  _Rule('list_macros', 'list macros', (_) => _simple(CarCommandKind.listMacros, 'Macros')),
  // Reading, windows, scrolling.
  for (final p in ['read', 'listen', 'read latest'])
    _Rule('read', p, (_) => _simple(CarCommandKind.read, 'Reading')),
  for (final p in ['earlier', 'read earlier', 'go back'])
    _Rule('earlier', p, (_) => _simple(CarCommandKind.earlier, 'Earlier')),
  for (final p in ['stop', 'quiet', 'stop reading'])
    _Rule('stop_reading', p, (_) => _simple(CarCommandKind.stopReading, 'Stopped')),
  for (final p in ['status', 'which window', 'how are the windows'])
    _Rule('status', p, (_) => _simple(CarCommandKind.status, 'Status')),
  for (final p in ['window N', 'target N'])
    _Rule('window', p, (c) {
      final n = c.nums.first;
      if (n < 1 || n > 3) return null;
      return CarCommand(CarCommandKind.window, 'Window $n', count: n);
    }),
  for (final p in [
    'scroll up',
    'scroll up N',
    'scroll up N lines',
    'scroll back',
    'scroll back N',
    'scroll back N lines',
  ])
    _Rule('scroll_up', p, (c) => _scroll(CarCommandKind.scrollUp, c)),
  for (final p in ['scroll down', 'scroll down N', 'scroll down N lines'])
    _Rule('scroll_down', p, (c) => _scroll(CarCommandKind.scrollDown, c)),
  _Rule('scroll_more', 'scroll up more', (_) => _simple(CarCommandKind.scrollMore, 'More')),
  _Rule('scroll_more', 'more', (_) => _simple(CarCommandKind.scrollMore, 'More'), fuzzy: false),
  for (final p in ['scroll to bottom', 'bottom', 'latest'])
    _Rule('scroll_bottom', p, (_) => _simple(CarCommandKind.scrollBottom, 'Bottom')),
  // UI commands.
  for (final p in ['open keyboard', 'show keyboard'])
    _Rule('ui_kb_open', p, (_) => _ui(CarUiCommand.openKeyboard, 'Keyboard open')),
  for (final p in ['close keyboard', 'hide keyboard'])
    _Rule('ui_kb_close', p, (_) => _ui(CarUiCommand.closeKeyboard, 'Keyboard closed')),
  for (final p in ['maximize', 'full screen', 'fullscreen', 'hide tabs'])
    _Rule('ui_max', p, (_) => _ui(CarUiCommand.maximize, 'Full screen')),
  for (final p in ['minimize', 'exit full screen', 'exit fullscreen', 'show tabs'])
    _Rule('ui_min', p, (_) => _ui(CarUiCommand.minimize, 'Tabs shown')),
  for (final p in ['open tools', 'expand tools', 'show tools'])
    _Rule('ui_tools_open', p, (_) => _ui(CarUiCommand.openTools, 'Tools open')),
  for (final p in ['collapse tools', 'close tools', 'hide tools'])
    _Rule('ui_tools_close', p, (_) => _ui(CarUiCommand.collapseTools, 'Tools collapsed')),
  // Car-mode control.
  for (final p in ['done', 'thats all', 'stop listening'])
    _Rule('done', p, (_) => _simple(CarCommandKind.done, 'Commands off')),
  for (final p in ['repeat', 'say again'])
    _Rule('repeat', p, (_) => _simple(CarCommandKind.repeat, 'Repeat')),
  for (final p in ['cancel', 'never mind'])
    _Rule('cancel', p, (_) => _simple(CarCommandKind.cancel, 'Cancelled')),
  _Rule('scratch', 'scratch that', (_) => _simple(CarCommandKind.scratch, 'Scratch that', destructive: true)),
  _Rule('privacy_on', 'privacy on', (_) => _simple(CarCommandKind.privacyOn, 'Privacy on')),
  _Rule('privacy_off', 'privacy off', (_) => _simple(CarCommandKind.privacyOff, 'Privacy off')),
  for (final p in ['car mode off', 'buttons off'])
    _Rule('car_off', p, (_) => _simple(CarCommandKind.carModeOff, 'Car mode off')),
  _Rule('take_buttons', 'take the buttons back', (_) => _simple(CarCommandKind.takeButtons, 'Buttons back')),
  _Rule('help', 'help', (_) => _simple(CarCommandKind.help, 'Help')),
  for (final p in ['yes', 'confirm'])
    _Rule('yes', p, (_) => _simple(CarCommandKind.confirmYes, 'Confirmed'), fuzzy: false),
  _Rule('no', 'no', (_) => _simple(CarCommandKind.confirmNo, 'Cancelled'), fuzzy: false),
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
      for (final (value, used) in carParseNumber(tokens, ti)) {
        final next = _Captures()
          ..nums.addAll(c.nums)
          ..nums.add(value)
          ..letter = c.letter
          ..rest = c.rest;
        walk(pi + 1, ti + used, next);
      }
      return;
    }
    if (p == 'L') {
      if (ti >= tokens.length) return;
      // "double you" is two tokens.
      if (ti + 1 < tokens.length &&
          tokens[ti] == 'double' &&
          tokens[ti + 1] == 'you') {
        walk(pi + 1, ti + 2, _Captures()
          ..nums.addAll(c.nums)
          ..letter = 'w'
          ..rest = c.rest);
      }
      final l = _letter(tokens[ti]);
      if (l == null) return;
      walk(pi + 1, ti + 1, _Captures()
        ..nums.addAll(c.nums)
        ..letter = l
        ..rest = c.rest);
      return;
    }
    if (p == '*') {
      if (pi != pattern.length - 1 || ti >= tokens.length) return;
      walk(pattern.length, tokens.length, _Captures()
        ..nums.addAll(c.nums)
        ..letter = c.letter
        ..rest = tokens.sublist(ti));
      return;
    }
    if (ti < tokens.length && tokens[ti] == p) walk(pi + 1, ti + 1, c);
  }

  walk(0, 0, _Captures());
  return results;
}

int _wordDistance(List<String> a, List<String> b) {
  final d = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      d[i][j] = [
        d[i - 1][j] + 1,
        d[i][j - 1] + 1,
        d[i - 1][j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
  }
  return d[a.length][b.length];
}

/// Matches a transcript against the command table (§8.2).
///
/// A phrase must match a table entry exactly, or be within one word-level
/// edit of exactly one multi-word entry. Anything unmatched or ambiguous is
/// rejected with "Didn't catch that" and does nothing.
CarParse parseCarCommand(String transcript) {
  final tokens = carNormalize(transcript);
  if (tokens.isEmpty) return const CarParse.error(carDidntCatch);
  // Exact matches (slots allowed).
  final exact = <String, CarCommand>{};
  for (final rule in _rules) {
    final pattern = rule.pattern;
    for (final captures in _match(pattern, tokens)) {
      final command = rule.build(captures);
      if (command != null) exact.putIfAbsent(rule.id, () => command);
    }
  }
  // A literal rule outranks a wildcard one ("macro list" is not asked for,
  // but "slash exit" must stay the exit command, not "slash other").
  if (exact.length > 1) {
    final specific = exact.entries
        .where((e) => e.key != 'slash_other' && e.key != 'macro_name')
        .toList();
    if (specific.length == 1) return CarParse.ok(specific.first.value);
    if (exact.containsKey('slash_other') &&
        exact['slash_other']!.text == 'exit') {
      return CarParse.ok(exact['slash_other']!);
    }
    return const CarParse.error(carDidntCatch);
  }
  if (exact.length == 1) return CarParse.ok(exact.values.first);
  // Near matches: one word-level edit from exactly one multi-word literal
  // entry. Escape is never near-matched (§8.3).
  if (tokens.length < 2) return const CarParse.error(carDidntCatch);
  final near = <String, CarCommand>{};
  for (final rule in _rules) {
    if (!rule.fuzzy || !rule.literal || rule.pattern.length < 2) continue;
    if (_wordDistance(tokens, rule.pattern) == 1) {
      final command = rule.build(_Captures());
      if (command != null) near.putIfAbsent(rule.id, () => command);
    }
  }
  // An utterance within one edit of both "escape key" and an exit phrase is
  // exactly the ambiguity §8.3 forbids.
  final nearEscape = tokens.length <= 3 &&
      (_wordDistance(tokens, ['escape', 'key']) <= 1 ||
          _wordDistance(tokens, ['e', 's', 'c']) <= 1);
  if (near.length == 1 && !nearEscape) return CarParse.ok(near.values.first);
  return const CarParse.error(carDidntCatch);
}

/// Phrases fed to the recognizer's biasing list (API 33+).
List<String> carBiasingPhrases() => {
  for (final rule in _rules)
    if (rule.literal) rule.pattern.join(' '),
  'macro one',
  'window one',
  'backspace ten',
  'option one',
  'slash compact',
}.toList();

/// The six most-used commands, for "help" (§8.2).
const carHelpText =
    'Say: submit. Escape. Macro and a number. Slash and a command. '
    'Read. Done.';
