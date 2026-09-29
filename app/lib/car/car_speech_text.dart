/// Text shaping for everything car mode says aloud (proposal §6, S7, S8).
library;

/// Replaces token-like secrets with the word "redacted" before speech:
/// API keys (`sk-…`, `ghp_…`, `xox…`), `password=` / `token=` values, SSH
/// key blocks, and long base64 or hex runs.
String carRedact(String text) {
  var out = text.replaceAll(
    RegExp(
      r'-----BEGIN [A-Z ]*(?:PRIVATE KEY|CERTIFICATE)-----[\s\S]*?-----END [A-Z ]*(?:PRIVATE KEY|CERTIFICATE)-----',
    ),
    ' redacted key ',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'\b(password|passwd|pwd|secret|token|api[_-]?key|authorization)(\s*[:=]\s*)\S+',
      caseSensitive: false,
    ),
    (m) => '${m[1]} redacted',
  );
  out = out.replaceAll(
    RegExp(r'\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{12,}'),
    'redacted',
  );
  out = out.replaceAll(
    RegExp(r'\b(?:ghp|gho|ghu|ghs|github_pat|xox[abpr]|AKIA)[A-Za-z0-9_\-]{8,}'),
    'redacted',
  );
  out = out.replaceAll(RegExp(r'\b[0-9a-fA-F]{32,}\b'), 'redacted');
  out = out.replaceAll(RegExp(r'[A-Za-z0-9+/=_\-]{40,}'), 'redacted');
  return out;
}

int carWordCount(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

/// Caps a read-back (§6): when the text is longer than [maxWords], speak the
/// first 25 words (or fewer when the cap is lower) plus "…and N more words".
String carReadback(String text, {int maxWords = 40}) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length <= maxWords) return words.join(' ');
  final head = maxWords < 25 ? maxWords : 25;
  final rest = words.length - head;
  return '${words.take(head).join(' ')} … and $rest more words';
}

/// Whisper tends to invent a short phrase on silence. A near-empty clip
/// whose transcript is one of these is treated as "heard nothing".
bool carLooksLikeSilenceHallucination(String text, int durationMs) {
  final t = text.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '').trim();
  if (t.isEmpty) return true;
  const phrases = {
    'thank you',
    'thanks',
    'thank you very much',
    'thanks for watching',
    'thank you for watching',
    'you',
    'bye',
    'okay',
    'so',
  };
  return durationMs < 2500 && phrases.contains(t);
}

/// If a dictation starts with the spoken prefix "command" or "computer"
/// (§8.5), returns the remainder (possibly empty); otherwise null.
String? carCommandPrefixRemainder(String transcript) {
  final match = RegExp(
    r'^\s*(?:command|computer)\b[\s,.:;!-]*(.*)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(transcript);
  if (match == null) return null;
  return match[1]!.trim();
}
