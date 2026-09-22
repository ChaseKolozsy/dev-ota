import 'dart:convert';

/// Conservative terminal cleanup, not summarization. Keep failures, negation,
/// numbers, paths and prose; remove escape sequences and standalone UI debris.
String cleanTerminalConclusion(String raw) {
  var text = raw.replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '');
  text = text.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '');
  final lines = <String>[];
  for (var line in text.split('\n')) {
    line = line.trimRight();
    if (RegExp(r'^\s*[─━═│┃┌┐└┘├┤┬┴┼╭╮╰╯┏┓┗┛\s]+$').hasMatch(line)) continue;
    if (RegExp(r'^\s*[❯›>$]\s*$').hasMatch(line)) continue;
    if (RegExp(
      r'^\s*(?:\? for shortcuts|esc to interrupt|ctrl\+c to interrupt|\d+% context left)\s*$',
      caseSensitive: false,
    ).hasMatch(line)) {
      continue;
    }
    line = line
        .replaceFirst(RegExp(r'^\s*[│┃]\s?'), '')
        .replaceFirst(RegExp(r'\s*[│┃]$'), '');
    line = line.replaceFirst(RegExp(r'^\s*[●•]\s+'), '');
    lines.add(line);
  }
  return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

String speakableConclusion(String text) => text
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' Code block omitted. ')
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'^\s*#{1,6}\s+', multiLine: true), '')
    .replaceAll(RegExp(r'[`*_]'), '')
    .replaceAll(RegExp(r'^\s*[-+]\s+', multiLine: true), '')
    .trim();

class ConclusionVerdict {
  const ConclusionVerdict(this.status, this.reason, this.evidence);
  final String status;
  final String reason;
  final String evidence;
  static const unknown = ConclusionVerdict(
    'uncertain',
    'Could not establish completion.',
    '',
  );
  String get label => switch (status) {
    'reported_success' => '✓ Reported success',
    'needs_attention' => '⚠ Needs attention',
    _ => '? Uncertain',
  };
  static ConclusionVerdict parse(String raw, String source) {
    try {
      final map = jsonDecode(raw) as Map;
      final status = map['status'];
      final reason = map['reason'];
      final evidence = map['evidence'];
      if (![
            'reported_success',
            'needs_attention',
            'uncertain',
          ].contains(status) ||
          reason is! String ||
          reason.isEmpty ||
          reason.length > 180 ||
          evidence is! String ||
          evidence.length > 300) {
        return unknown;
      }
      if (status != 'uncertain' &&
          (evidence.trim().isEmpty || !source.contains(evidence))) {
        return unknown;
      }
      return ConclusionVerdict(status as String, reason, evidence);
    } catch (_) {
      return unknown;
    }
  }
}

/// A stable reading cursor. Earlier moves the starting point, not the live
/// terminal view, and stops at the bounded snapshot's beginning.
class ConclusionReading {
  ConclusionReading(this.paneId, this.title, this.source) {
    final clean = speakableConclusion(source);
    chunks = [];
    var remaining = clean;
    while (remaining.isNotEmpty) {
      var end = remaining.length > 1000 ? 1000 : remaining.length;
      if (end < remaining.length) {
        final sentence = remaining
            .substring(0, end)
            .lastIndexOf(RegExp(r'[.!?]\s|\n\n'));
        if (sentence > 300) {
          end = sentence + 1;
        } else {
          final space = remaining.lastIndexOf(' ', end);
          if (space > 300) end = space;
        }
      }
      chunks.add(remaining.substring(0, end).trim());
      remaining = remaining.substring(end).trim();
    }
    start = chunks.length > 2 ? chunks.length - 2 : 0;
  }
  final String paneId;
  final String title;
  final String source;
  late final List<String> chunks;
  late int start;
  bool get hasEarlier => start > 0;
  void earlier() {
    if (hasEarlier) start--;
  }

  String get text => chunks.skip(start).join('\n\n');
}
