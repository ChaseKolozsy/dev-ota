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
    this.builtin = false,
    this.enabledWhenDisconnected = false,
  });

  final String id;
  final String abbreviation;
  final String name;
  final String? iconName;
  final String sequence;
  final bool builtin;
  final bool enabledWhenDisconnected;

  TerminalPadKey copyWith({
    String? abbreviation,
    String? name,
    String? iconName,
    String? sequence,
  }) {
    return TerminalPadKey(
      id: id,
      abbreviation: abbreviation ?? this.abbreviation,
      name: name ?? this.name,
      iconName: iconName ?? this.iconName,
      sequence: sequence ?? this.sequence,
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
