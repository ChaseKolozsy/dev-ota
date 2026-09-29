/// Voice control vocabulary for the Terminal tab.
///
/// Commands are the names of the buttons on screen. The Terminal tab hands
/// over one [VoiceTarget] per button (pad keys, arrows, the tmux row, the
/// macros row and the cmds row), each carrying the label and tooltip that
/// button shows and the very callback its onPressed runs. Nothing here keeps a
/// parallel list of commands: the spoken forms are derived from those labels
/// at the moment an utterance arrives, so custom pad keys, macros and cmds are
/// commands as soon as they are on screen.
///
/// A command must be the WHOLE utterance. "page up" is a command; "scroll the
/// page up a bit" is dictation.
library;

import 'package:flutter/foundation.dart';

enum VoiceTargetKind { padKey, arrow, tmux, macro, command }

/// One button the owner can name.
class VoiceTarget {
  const VoiceTarget({
    required this.kind,
    required this.id,
    required this.label,
    required this.run,
    this.tooltip,
    this.abbreviation,
    this.enabled = true,
    this.confirm = false,
  });

  final VoiceTargetKind kind;

  /// Pad key id, arrow id, tmux usage id, macro id, or the command text.
  final String id;

  /// What the button shows (pad key name, tmux label, macro name, command).
  final String label;

  /// The button's tooltip, when it has one.
  final String? tooltip;

  /// A pad key's short pill text (`PgUp`, `C-c`).
  final String? abbreviation;

  /// False when the button is disabled on screen (its bar is switched off).
  final bool enabled;

  /// Exit and Ctrl-C ask "Say yes to confirm" before running.
  final bool confirm;

  /// Exactly what the button's onPressed does.
  final VoidCallback run;

  /// Every spoken form of this button, best first: rank 0 is the text the
  /// button itself shows, rank 1 a form derived from it (tooltip, "run X").
  List<({String phrase, int rank})> get phrases {
    final out = <({String phrase, int rank})>[];
    void add(String? raw, int rank) {
      if (raw == null) return;
      final phrase = normalizeSpoken(raw);
      if (phrase.isEmpty) return;
      if (out.any((p) => p.phrase == phrase)) return;
      out.add((phrase: phrase, rank: rank));
    }

    add(label, 0);
    switch (kind) {
      case VoiceTargetKind.padKey:
        add(abbreviation, 1);
        add(tooltip, 1);
      case VoiceTargetKind.arrow:
        add(tooltip, 1);
        add('arrow $label', 1);
        add('$label arrow', 1);
      case VoiceTargetKind.tmux:
        add(tooltip, 1);
        final t = tooltip == null ? null : _withoutWord(tooltip!, 'tmux');
        add(t, 1);
      case VoiceTargetKind.macro:
      case VoiceTargetKind.command:
        add(tooltip, 1);
        add('run $label', 1);
        final plain = normalizeSpoken(label);
        if (plain.startsWith('slash ')) {
          final bare = plain.substring('slash '.length);
          add(bare, 1);
          add('run $bare', 1);
        }
    }
    return out;
  }

  @override
  String toString() => '${kind.name}:$id';
}

String _withoutWord(String text, String word) =>
    text.split(RegExp(r'\s+')).where((w) => w.toLowerCase() != word).join(' ');

/// Spoken forms of the short key names printed on buttons.
const _tokenExpansions = <String, String>{
  'ctrl': 'control',
  'esc': 'escape',
  'pgup': 'page up',
  'pgdn': 'page down',
  'bksp': 'backspace',
};

/// Lower-case words only, so a label and what the recognizer heard compare
/// equal: "Ctrl-C" / "control-c" / "Control C" -> "control c",
/// "/compact" -> "slash compact", "copy/scroll" -> "copy scroll".
String normalizeSpoken(String raw) {
  var s = raw.trim().toLowerCase();
  // Emacs-style pad pills: C-c, C-z -> control c.
  s = s.replaceAllMapped(
    RegExp(r'(^|\s)c-([a-z0-9])(?=$|\s)'),
    (m) => '${m[1]}control ${m[2]}',
  );
  s = s.replaceAllMapped(RegExp(r'(^|\s)/'), (m) => '${m[1]}slash ');
  s = s.replaceAll(RegExp(r"[^a-z0-9\s]+"), ' ');
  final words = s
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => _tokenExpansions[w] ?? w);
  return words.join(' ');
}

const _units = <String, int>{
  'a': 1,
  'an': 1,
  'one': 1,
  'won': 1,
  'two': 2,
  'to': 2,
  'too': 2,
  'three': 3,
  'four': 4,
  'for': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
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

const _tens = <String, int>{
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

/// "20", "twenty", "twenty five", "a hundred", "one hundred and five".
/// Null when [words] is not exactly one number.
@visibleForTesting
int? parseCount(List<String> words) {
  if (words.isEmpty) return null;
  if (words.length == 1) {
    final digits = int.tryParse(words.single);
    if (digits != null) return digits;
  }
  var current = 0;
  var seen = false;
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (w == 'and' && seen && i < words.length - 1) continue;
    final digits = int.tryParse(w);
    if (digits != null && !seen) {
      current = digits;
    } else if (_units.containsKey(w)) {
      if (current % 10 != 0 && current != 0) return null;
      current += _units[w]!;
    } else if (_tens.containsKey(w)) {
      if (current % 100 != 0) return null;
      current += _tens[w]!;
    } else if (w == 'hundred') {
      current = (current == 0 ? 1 : current) * 100;
    } else {
      return null;
    }
    seen = true;
  }
  return seen ? current : null;
}

/// "exit" and "/exit" on a macro or cmds button ask for confirmation, like
/// Ctrl-C does.
bool isExitLabel(String label) {
  final spoken = normalizeSpoken(label);
  return spoken == 'exit' || spoken == 'slash exit';
}

sealed class VoiceMatch {
  const VoiceMatch();
}

/// A button, by name.
class TargetMatch extends VoiceMatch {
  const TargetMatch(this.target);
  final VoiceTarget target;
}

/// "send" / "submit": the composer's send arrow.
class SendMatch extends VoiceMatch {
  const SendMatch();
}

class StopListeningMatch extends VoiceMatch {
  const StopListeningMatch();
}

class YesMatch extends VoiceMatch {
  const YesMatch();
}

class NoMatch extends VoiceMatch {
  const NoMatch();
}

enum ComposerEdit { clear, backspace, deleteWords }

/// Edits the Type command box, never the terminal.
class ComposerEditMatch extends VoiceMatch {
  const ComposerEditMatch(this.edit, [this.count = 0]);
  final ComposerEdit edit;
  final int count;
}

/// Anything else: text for the Type command box, exactly as heard.
class DictationMatch extends VoiceMatch {
  const DictationMatch(this.text);
  final String text;
}

/// Decides what one whole utterance is.
class VoiceCommandMatcher {
  const VoiceCommandMatcher();

  static const _send = {'send', 'submit', 'submit to ssh'};
  static const _stop = {'stop listening', 'stop voice control'};
  static const _yes = {'yes', 'yeah', 'yep', 'confirm'};
  static const _no = {'no', 'nope', 'cancel'};

  /// The command each spoken phrase names. A phrase two buttons share at the
  /// same rank (tmux "Split |" and "Split -" are both "split") names neither;
  /// their longer tooltip forms still work.
  Map<String, VoiceTarget> vocabulary(List<VoiceTarget> targets) {
    final best = <String, ({int rank, List<VoiceTarget> targets})>{};
    for (final target in targets) {
      for (final p in target.phrases) {
        final seen = best[p.phrase];
        if (seen == null || p.rank < seen.rank) {
          best[p.phrase] = (rank: p.rank, targets: [target]);
        } else if (p.rank == seen.rank &&
            !seen.targets.any(
              (t) => t.kind == target.kind && t.id == target.id,
            )) {
          seen.targets.add(target);
        }
      }
    }
    return {
      for (final e in best.entries)
        if (e.value.targets.length == 1) e.key: e.value.targets.single,
    };
  }

  VoiceMatch match(String utterance, List<VoiceTarget> targets) {
    final text = utterance.trim();
    final spoken = normalizeSpoken(text);
    if (spoken.isEmpty) return DictationMatch(text);
    if (_stop.contains(spoken)) return const StopListeningMatch();
    if (_yes.contains(spoken)) return const YesMatch();
    if (_no.contains(spoken)) return const NoMatch();
    if (_send.contains(spoken)) return const SendMatch();
    final edit = _composerEdit(spoken);
    if (edit != null) return edit;
    final target = vocabulary(targets)[spoken];
    if (target != null) return TargetMatch(target);
    return DictationMatch(text);
  }

  ComposerEditMatch? _composerEdit(String spoken) {
    if (spoken == 'clear') return const ComposerEditMatch(ComposerEdit.clear);
    var words = spoken.split(' ');
    if (words.first == 'backspace' && words.length > 1) {
      var rest = words.sublist(1);
      if (rest.last == 'times' || rest.last == 'characters') {
        rest = rest.sublist(0, rest.length - 1);
      }
      final n = parseCount(rest);
      if (n != null && n > 0) {
        return ComposerEditMatch(ComposerEdit.backspace, n);
      }
      return null;
    }
    if (words.first == 'delete' && words.length > 1) {
      words = words.sublist(1);
      if (words.first == 'the') words = words.sublist(1);
      if (words.isNotEmpty && words.first == 'last') words = words.sublist(1);
      if (words.isEmpty) return null;
      final unit = words.last;
      if (unit != 'word' && unit != 'words') return null;
      final countWords = words.sublist(0, words.length - 1);
      final n = countWords.isEmpty ? 1 : parseCount(countWords);
      if (n != null && n > 0) {
        return ComposerEditMatch(ComposerEdit.deleteWords, n);
      }
    }
    return null;
  }
}

/// "backspace N" on the Type command box: drops the last [count] characters.
String backspaceText(String text, int count) =>
    count >= text.length ? '' : text.substring(0, text.length - count);

/// "delete N words" on the Type command box: drops the last [count] words and
/// the space before them.
String deleteLastWords(String text, int count) {
  var out = text.trimRight();
  for (var i = 0; i < count && out.isNotEmpty; i++) {
    final cut = out.lastIndexOf(RegExp(r'\s'));
    out = cut < 0 ? '' : out.substring(0, cut).trimRight();
  }
  return out;
}
