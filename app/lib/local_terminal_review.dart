import 'dart:convert';
import 'package:flutter/services.dart';
import 'terminal_conclusion.dart';

/// No remote model: OCR and the conservative phrase classifier run on phone.
Future<String> reviewTerminalLocally(String source) async {
  const channel = MethodChannel('devota/terminal_review');
  final ocr = await channel.invokeMethod<String>('recognizeSnapshot', {
    'text': cleanTerminalConclusion(source),
  });
  final original = classifyTerminalText(source);
  final recognized = classifyTerminalText(ocr ?? '');
  // OCR must never introduce or erase a caveat to manufacture success.
  final verdict = original.status == recognized.status
      ? original
      : ConclusionVerdict.unknown;
  return jsonEncode({
    'status': verdict.status,
    'reason': verdict.reason,
    'evidence': verdict.evidence,
  });
}

ConclusionVerdict classifyTerminalText(String raw) {
  // A newer input prompt makes any earlier completion report obsolete.
  if (RegExp(r'^\s*[❯›>]\s+\S', multiLine: true).hasMatch(raw)) {
    return ConclusionVerdict.unknown;
  }
  final clean = cleanTerminalConclusion(raw);
  final lines = clean.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return ConclusionVerdict.unknown;
  final attention = RegExp(
    r'\b(?:not (?:done|complete|completed|finished|verified)|'
    r'could not|couldn.t|unable to|blocked|unfinished|unverified|'
    r'(?:tests?|checks?|build|macro|push|verification) (?:failed|fails)|'
    r'(?:failed|failing) (?:tests?|checks?|build)|'
    r'needs? (?:your |user )?(?:approval|confirmation|attention)|'
    r'(?:please|you (?:must|need to)) (?:confirm|approve|enable|install)|'
    r'(?:still|remains?) (?:pending|incomplete)|'
    r'(?:not|never) (?:committed|pushed|rebuilt))\b',
    caseSensitive: false,
  );
  for (final line in lines.reversed) {
    if (attention.hasMatch(line)) {
      return ConclusionVerdict(
        'needs_attention',
        'The latest report describes unfinished work or user action.',
        line.trim().substring(0, line.trim().length.clamp(0, 300)),
      );
    }
    for (final match in RegExp(
      r'\b(\d+)\s*(?:/|out of|of)\s*(\d+)\b',
    ).allMatches(line)) {
      if (int.parse(match[1]!) < int.parse(match[2]!)) {
        return ConclusionVerdict(
          'needs_attention',
          'The report contains a partial count.',
          line.trim().substring(0, line.trim().length.clamp(0, 300)),
        );
      }
    }
  }
  // Don't interpret future plans, instructions, negation or tool output as a
  // completed assistant report. Unknown is preferable to a false green label.
  if (RegExp(
    r'\b(?:I.ll|I will|working on|in progress|next step|'
    r'not|however|but|remaining|pending|skipped|failed|failure|error|'
    r'if|would|should|must|will|please|retry|unavailable)\b',
    caseSensitive: false,
  ).hasMatch(clean)) {
    return ConclusionVerdict.unknown;
  }
  final completion = RegExp(
    r'\b(?:all (?:\d+ )?(?:required )?(?:work|tasks?|items?) (?:is |are )?(?:complete|completed|done)|'
    r'(?:implemented|fixed|completed|finished)\b.{0,120}\b(?:verified|tested|checks passed)|'
    r'committed and pushed|changes (?:are )?(?:complete|completed))\b',
    caseSensitive: false,
  );
  for (final line in lines.reversed) {
    if (completion.hasMatch(line)) {
      return ConclusionVerdict(
        'reported_success',
        'The latest report explicitly states completion.',
        line.trim().substring(0, line.trim().length.clamp(0, 300)),
      );
    }
  }
  return ConclusionVerdict.unknown;
}

/// Bound review to the bottom of the pane, separating the last bullet-style
/// assistant message where terminal clients expose one. Listening retains
/// its independent history controls.
String terminalReviewExcerpt(String raw) {
  final markers = RegExp(
    r'^\s*[●]\s+',
    multiLine: true,
  ).allMatches(raw).toList();
  if (markers.length == 1) {
    raw = raw.substring(markers.single.start);
  } else if (markers.length > 1) {
    final between = raw.substring(
      markers[markers.length - 2].end,
      markers.last.start,
    );
    // Multiple bullet messages without a user-turn boundary may share caveats.
    // Keep them rather than hiding a failure from the same assistant report.
    if (RegExp(r'^\s*[❯›>]\s+\S', multiLine: true).hasMatch(between)) {
      raw = raw.substring(markers.last.start);
    }
  }
  var lines = raw.split('\n');
  if (lines.length > 40) lines = lines.sublist(lines.length - 40);
  var text = lines.join('\n').trim();
  if (text.length > 6000) {
    text = text.substring(text.length - 6000);
    final boundary = text.indexOf('\n');
    if (boundary >= 0) text = text.substring(boundary + 1);
  }
  return text;
}
