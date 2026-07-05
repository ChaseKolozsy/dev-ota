import 'dart:convert';

/// Recommended maximum length for a pad-key abbreviation. The custom-key editor
/// shows a soft warning once an abbreviation is longer than this; it is a
/// recommendation, not a hard limit.
const int kRecommendedAbbrevMax = 4;

/// One customizable button in the terminal control pad.
///
/// A key carries a short [abbreviation] (rendered on the pill) and a longer
/// [name] (shown as the tooltip and in the settings list). Built-in keys may
/// render an [iconName] instead of the abbreviation. [sequence] is the data to
/// send to the terminal: built-in keys store the literal characters already
/// decoded, while custom keys store escape notation that [decodeKeySequence]
/// expands at send time.
class TerminalPadKey {
  const TerminalPadKey({
    required this.id,
    required this.abbreviation,
    required this.name,
    this.iconName,
    this.sequence = '',
    this.spec = '',
    this.builtin = false,
    this.enabledWhenDisconnected = false,
  });

  final String id;
  final String abbreviation;
  final String name;
  final String? iconName;

  /// The raw bytes sent to the terminal (already decoded/resolved).
  final String sequence;

  /// The human-friendly key spec the user typed (e.g. `Ctrl-End`), kept so the
  /// editor can re-open with the original text. Empty for built-in keys.
  final String spec;

  final bool builtin;
  final bool enabledWhenDisconnected;

  TerminalPadKey copyWith({
    String? abbreviation,
    String? name,
    String? iconName,
    String? sequence,
    String? spec,
  }) {
    return TerminalPadKey(
      id: id,
      abbreviation: abbreviation ?? this.abbreviation,
      name: name ?? this.name,
      iconName: iconName ?? this.iconName,
      sequence: sequence ?? this.sequence,
      spec: spec ?? this.spec,
      builtin: builtin,
      enabledWhenDisconnected: enabledWhenDisconnected,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'abbreviation': abbreviation,
    'name': name,
    if (iconName != null) 'iconName': iconName,
    'sequence': sequence,
    if (spec.isNotEmpty) 'spec': spec,
    'builtin': builtin,
    'enabledWhenDisconnected': enabledWhenDisconnected,
  };

  factory TerminalPadKey.fromJson(Map<String, dynamic> json) {
    return TerminalPadKey(
      id: (json['id'] ?? '').toString(),
      abbreviation: (json['abbreviation'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      iconName: json['iconName']?.toString(),
      sequence: (json['sequence'] ?? '').toString(),
      spec: (json['spec'] ?? '').toString(),
      builtin: json['builtin'] == true,
      enabledWhenDisconnected: json['enabledWhenDisconnected'] == true,
    );
  }
}

/// Layout of a single control-pad row: an ordered list of scrollable middle
/// keys, an optional key pinned to the right edge, and whether the middle keys
/// are auto-ordered by frequency of use.
class TerminalPadRowConfig {
  TerminalPadRowConfig({
    required this.middleIds,
    this.fixedRightId,
    this.sortByFrequency = false,
  });

  List<String> middleIds;
  String? fixedRightId;
  bool sortByFrequency;

  TerminalPadRowConfig clone() => TerminalPadRowConfig(
    middleIds: List<String>.from(middleIds),
    fixedRightId: fixedRightId,
    sortByFrequency: sortByFrequency,
  );

  Map<String, dynamic> toJson() => {
    'middleIds': middleIds,
    'fixedRightId': fixedRightId,
    'sortByFrequency': sortByFrequency,
  };

  factory TerminalPadRowConfig.fromJson(Map<String, dynamic> json) {
    final ids = json['middleIds'];
    return TerminalPadRowConfig(
      middleIds: ids is List
          ? ids.map((e) => e.toString()).toList()
          : <String>[],
      fixedRightId: json['fixedRightId']?.toString(),
      sortByFrequency: json['sortByFrequency'] == true,
    );
  }
}

/// The full control-pad customization: the user's custom keys and the two-row
/// layout. [TerminalPadConfig.defaults] reproduces the app's original layout so
/// nothing changes on screen until the user customizes it.
class TerminalPadConfig {
  TerminalPadConfig({
    this.version = 1,
    required this.customKeys,
    required this.rows,
  });

  int version;
  List<TerminalPadKey> customKeys;
  List<TerminalPadRowConfig> rows;

  factory TerminalPadConfig.defaults() {
    return TerminalPadConfig(
      customKeys: <TerminalPadKey>[],
      rows: [
        TerminalPadRowConfig(
          middleIds: ['tab', 'esc', 'ctrl_c', 'slash', 'attach_file'],
          fixedRightId: 'backspace',
        ),
        TerminalPadRowConfig(
          middleIds: ['home', 'end', 'page_up', 'page_down'],
          fixedRightId: 'enter',
        ),
      ],
    );
  }

  TerminalPadConfig clone() => TerminalPadConfig(
    version: version,
    customKeys: customKeys.map((k) => k.copyWith()).toList(),
    rows: rows.map((r) => r.clone()).toList(),
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'customKeys': customKeys.map((k) => k.toJson()).toList(),
    'rows': rows.map((r) => r.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());

  factory TerminalPadConfig.fromJson(Map<String, dynamic> json) {
    final rawRows = json['rows'];
    final rows = rawRows is List
        ? rawRows
              .whereType<Map>()
              .map(
                (e) => TerminalPadRowConfig.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .toList()
        : <TerminalPadRowConfig>[];
    final rawCustom = json['customKeys'];
    final customKeys = rawCustom is List
        ? rawCustom
              .whereType<Map>()
              .map(
                (e) => TerminalPadKey.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .toList()
        : <TerminalPadKey>[];
    // The pad always renders exactly two rows; backfill from defaults if a
    // stored/older blob is short so the layout stays stable.
    if (rows.length < 2) {
      final defaults = TerminalPadConfig.defaults();
      while (rows.length < 2) {
        rows.add(defaults.rows[rows.length]);
      }
    }
    return TerminalPadConfig(
      version: json['version'] is int ? json['version'] as int : 1,
      customKeys: customKeys,
      rows: rows,
    );
  }

  /// Decodes [source] (JSON produced by [encode]); falls back to defaults on any
  /// malformed input so a bad blob can never brick the control pad.
  static TerminalPadConfig decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return TerminalPadConfig.defaults();
      return TerminalPadConfig.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (_) {
      return TerminalPadConfig.defaults();
    }
  }
}

/// Expands escape notation used by custom pad keys into the literal string sent
/// to the terminal. Supports `\t \r \n \e \xNN \\`; any other character —
/// including an unrecognized escape — is passed through unchanged. A string
/// with no backslash is returned as-is.
String decodeKeySequence(String notation) {
  if (!notation.contains(r'\')) return notation;
  final buffer = StringBuffer();
  for (var i = 0; i < notation.length; i++) {
    final ch = notation[i];
    if (ch != r'\' || i + 1 >= notation.length) {
      buffer.write(ch);
      continue;
    }
    final next = notation[i + 1];
    switch (next) {
      case 't':
        buffer.write('\t');
        i++;
      case 'r':
        buffer.write('\r');
        i++;
      case 'n':
        buffer.write('\n');
        i++;
      case 'e':
      case 'E':
        buffer.write('\x1B');
        i++;
      case '\\':
        buffer.write(r'\');
        i++;
      case 'x':
      case 'X':
        // \xNN — consume up to two following hex digits.
        final hex = StringBuffer();
        var j = i + 2;
        while (j < notation.length &&
            hex.length < 2 &&
            _isHexDigit(notation[j])) {
          hex.write(notation[j]);
          j++;
        }
        if (hex.isEmpty) {
          buffer.write(ch); // lone "\x" — pass the backslash through
        } else {
          buffer.writeCharCode(int.parse(hex.toString(), radix: 16));
          i = j - 1;
        }
      default:
        buffer.write(ch); // unknown escape: keep the backslash literally
    }
  }
  return buffer.toString();
}

bool _isHexDigit(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) || // 0-9
      (code >= 0x41 && code <= 0x46) || // A-F
      (code >= 0x61 && code <= 0x66); // a-f
}

/// Outcome of resolving a human-friendly key spec (e.g. `Ctrl-C`, `Home`,
/// `Ctrl-End`) into the raw bytes a terminal expects. Either [sequence] +
/// [description] are set (success) or [error] explains why it could not be
/// resolved.
class KeySpecResult {
  const KeySpecResult._(this.sequence, this.description, this.error);
  const KeySpecResult.ok(String sequence, String description)
    : this._(sequence, description, null);
  const KeySpecResult.err(String error) : this._(null, null, error);

  final String? sequence;
  final String? description;
  final String? error;

  bool get ok => error == null;
}

/// A named (non-printable) key: its unmodified [base] byte sequence plus how a
/// modifier-combined form is encoded — a CSI "letter" form (`ESC [ 1 ; m L`) or
/// a CSI "tilde" form (`ESC [ n ; m ~`). Keys with neither only accept Alt
/// (encoded as an ESC prefix).
class _NamedKey {
  const _NamedKey(this.base, {this.letter, this.tilde});
  final String base;
  final String? letter;
  final int? tilde;
}

const Map<String, _NamedKey> _kNamedKeys = {
  'tab': _NamedKey('\t'),
  'enter': _NamedKey('\r'),
  'return': _NamedKey('\r'),
  'esc': _NamedKey('\x1B'),
  'escape': _NamedKey('\x1B'),
  'backspace': _NamedKey('\x7F'),
  'bksp': _NamedKey('\x7F'),
  'del': _NamedKey('\x1B[3~', tilde: 3),
  'delete': _NamedKey('\x1B[3~', tilde: 3),
  'ins': _NamedKey('\x1B[2~', tilde: 2),
  'insert': _NamedKey('\x1B[2~', tilde: 2),
  'home': _NamedKey('\x1B[H', letter: 'H'),
  'end': _NamedKey('\x1B[F', letter: 'F'),
  'pgup': _NamedKey('\x1B[5~', tilde: 5),
  'pageup': _NamedKey('\x1B[5~', tilde: 5),
  'pgdn': _NamedKey('\x1B[6~', tilde: 6),
  'pagedown': _NamedKey('\x1B[6~', tilde: 6),
  'up': _NamedKey('\x1B[A', letter: 'A'),
  'down': _NamedKey('\x1B[B', letter: 'B'),
  'right': _NamedKey('\x1B[C', letter: 'C'),
  'left': _NamedKey('\x1B[D', letter: 'D'),
};

// Canonical display names for the keys above (first alias wins).
const Map<String, String> _kNamedDisplay = {
  'tab': 'Tab', 'enter': 'Enter', 'return': 'Enter', 'esc': 'Esc',
  'escape': 'Esc', 'backspace': 'Backspace', 'bksp': 'Backspace',
  'del': 'Del', 'delete': 'Del', 'ins': 'Ins',
  'insert': 'Ins', 'home': 'Home', 'end': 'End', 'pgup': 'PgUp',
  'pageup': 'PgUp', 'pgdn': 'PgDn', 'pagedown': 'PgDn', 'up': 'Up',
  'down': 'Down', 'right': 'Right', 'left': 'Left',
};

// Ctrl + these punctuation characters map to specific control codes.
const Map<String, String> _kCtrlPunct = {
  '@': '\x00', ' ': '\x00', '[': '\x1B', '\\': '\x1C', ']': '\x1D',
  '^': '\x1E', '_': '\x1F', '?': '\x7F',
};

const Map<int, String> _kFnKeys = {
  1: '\x1BOP', 2: '\x1BOQ', 3: '\x1BOR', 4: '\x1BOS',
  5: '\x1B[15~', 6: '\x1B[17~', 7: '\x1B[18~', 8: '\x1B[19~',
  9: '\x1B[20~', 10: '\x1B[21~', 11: '\x1B[23~', 12: '\x1B[24~',
};

/// Resolves a human-friendly key spec into the bytes to send. Accepts one or
/// more space-separated keys, each being: a named key (`Home`, `PgUp`, `F5`),
/// a modifier combo (`Ctrl-C`, `Alt-B`, `Ctrl-Shift-End`, `^C`), a quoted
/// literal (`"ls -la"`), or raw escape notation (`\x1b`, `\t`). Returns an
/// error message when any token cannot be resolved.
KeySpecResult resolveKeySpec(String input) {
  final spec = input.trim();
  if (spec.isEmpty) {
    return const KeySpecResult.err('Enter a key, e.g. Ctrl-C, Home or F5.');
  }
  final tokens = _splitKeySpecTokens(spec);
  final bytes = StringBuffer();
  final parts = <String>[];
  for (final token in tokens) {
    final result = _resolveKeyToken(token);
    if (!result.ok) return result;
    bytes.write(result.sequence);
    parts.add(result.description!);
  }
  return KeySpecResult.ok(bytes.toString(), parts.join(' '));
}

// Splits on whitespace but keeps a "double-quoted literal" as one token.
List<String> _splitKeySpecTokens(String spec) {
  final tokens = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < spec.length; i++) {
    final ch = spec[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
      current.write(ch);
    } else if (!inQuotes && (ch == ' ' || ch == '\t')) {
      if (current.isNotEmpty) {
        tokens.add(current.toString());
        current.clear();
      }
    } else {
      current.write(ch);
    }
  }
  if (current.isNotEmpty) tokens.add(current.toString());
  return tokens;
}

KeySpecResult _resolveKeyToken(String token) {
  // Quoted literal text.
  if (token.length >= 2 && token.startsWith('"') && token.endsWith('"')) {
    final literal = token.substring(1, token.length - 1);
    return KeySpecResult.ok(literal, '"$literal"');
  }
  // Raw escape notation.
  if (token.startsWith(r'\')) {
    if (_isKnownEscape(token)) {
      return KeySpecResult.ok(decodeKeySequence(token), token);
    }
    return KeySpecResult.err(
      'Unknown escape "$token". Try \\t, \\r, \\e or \\xNN.',
    );
  }

  var ctrl = false;
  var alt = false;
  var shift = false;
  var base = token;
  if (base.startsWith('^') && base.length > 1) {
    ctrl = true;
    base = base.substring(1);
  }
  final parts = base.split(RegExp('[-+]'));
  if (parts.length > 1) {
    for (final mod in parts.sublist(0, parts.length - 1)) {
      switch (mod.toLowerCase()) {
        case 'ctrl' || 'control' || 'ctl' || 'c' || '^':
          ctrl = true;
        case 'alt' || 'meta' || 'opt' || 'option' || 'm':
          alt = true;
        case 'shift' || 's':
          shift = true;
        default:
          return KeySpecResult.err('Unknown modifier "$mod" in "$token".');
      }
    }
    base = parts.last;
  }
  if (base.isEmpty) {
    return KeySpecResult.err('Missing a key after the modifier in "$token".');
  }

  final lower = base.toLowerCase();
  final label = _describeCombo(ctrl, alt, shift);

  // F-keys.
  final fMatch = RegExp(r'^f([1-9]|1[0-2])$').firstMatch(lower);
  if (fMatch != null) {
    if (ctrl || alt || shift) {
      return KeySpecResult.err('Modifiers on F-keys are not supported.');
    }
    return KeySpecResult.ok(_kFnKeys[int.parse(fMatch.group(1)!)]!, base.toUpperCase());
  }

  // Shift-Tab has its own sequence.
  if (lower == 'tab' && shift && !ctrl && !alt) {
    return const KeySpecResult.ok('\x1B[Z', 'Shift-Tab');
  }

  // Space routes through char resolution so Ctrl-Space -> NUL works.
  if (lower == 'space') {
    return KeySpecResult.ok(
      _resolveCharKey(' ', ctrl: ctrl, alt: alt, shift: shift)!,
      '${label}Space',
    );
  }

  // Named keys.
  final named = _kNamedKeys[lower];
  if (named != null) {
    final seq = _applyNamedModifiers(named, ctrl: ctrl, alt: alt, shift: shift);
    if (seq == null) {
      return KeySpecResult.err(
        '${_kNamedDisplay[lower]} does not accept a Ctrl or Shift modifier.',
      );
    }
    return KeySpecResult.ok(seq, '$label${_kNamedDisplay[lower]}');
  }

  // Single printable character.
  if (base.length == 1) {
    final seq = _resolveCharKey(base, ctrl: ctrl, alt: alt, shift: shift);
    if (seq == null) {
      return KeySpecResult.err(
        'Cannot make Ctrl-$base. Use a letter or one of @ [ \\ ] ^ _ ?.',
      );
    }
    final shown = shift ? base.toUpperCase() : base;
    return KeySpecResult.ok(seq, '$label$shown');
  }

  return KeySpecResult.err(
    'Unknown key "$base". Open the legend for the valid names.',
  );
}

// Modifier value per the xterm/CSI convention: 1 + shift + 2*alt + 4*ctrl.
int _modifierValue({required bool ctrl, required bool alt, required bool shift}) {
  return 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
}

String? _applyNamedModifiers(
  _NamedKey key, {
  required bool ctrl,
  required bool alt,
  required bool shift,
}) {
  if (!ctrl && !alt && !shift) return key.base;
  final mod = _modifierValue(ctrl: ctrl, alt: alt, shift: shift);
  if (key.letter != null) return '\x1B[1;$mod${key.letter}';
  if (key.tilde != null) return '\x1B[${key.tilde};$mod~';
  // No CSI modified form (Tab/Enter/Esc/Backspace/Space): only Alt is
  // representable, as an ESC prefix.
  if (ctrl || shift) return null;
  return '\x1B${key.base}';
}

String? _resolveCharKey(
  String ch, {
  required bool ctrl,
  required bool alt,
  required bool shift,
}) {
  if (ctrl) {
    final upper = ch.toUpperCase();
    final code = upper.codeUnitAt(0);
    String? control;
    if (code >= 0x41 && code <= 0x5A) {
      control = String.fromCharCode(code & 0x1F);
    } else {
      control = _kCtrlPunct[ch];
    }
    if (control == null) return null;
    return alt ? '\x1B$control' : control;
  }
  var out = ch;
  if (shift && RegExp('[a-z]').hasMatch(ch)) out = ch.toUpperCase();
  return alt ? '\x1B$out' : out;
}

String _describeCombo(bool ctrl, bool alt, bool shift) {
  final mods = <String>[
    if (ctrl) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
  ];
  return mods.isEmpty ? '' : '${mods.join('-')}-';
}

bool _isKnownEscape(String token) {
  if (token.length == 2 && r'trneE\'.contains(token[1])) return true;
  final hex = RegExp(r'^\\x[0-9A-Fa-f]{1,2}$');
  return hex.hasMatch(token);
}
