/// The passive-listening state machine (docs/passive-voice-control.md):
/// per-window drafts, the selected target window, confirmations, and what
/// each command does. Pure Dart; the terminal, speech and UI are injected so
/// the whole machine runs against fakes in tests.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../terminal_macro.dart';
import 'voice_grammar.dart';

/// Short earcons the phone plays after an utterance.
enum VoiceTone { command, dictation, error }

class VoiceWindow {
  const VoiceWindow(this.paneId, this.label);
  final String paneId;
  final String label;
}

/// What the controller may do to terminal windows. Every call returns null
/// on success or a short spoken reason; nothing is retried.
abstract class VoiceTerminal {
  /// Bound windows in notification order ("window 1" is the first).
  List<VoiceWindow> get windows;

  /// All macros in Macros-tab order ("macro 1" is the first).
  List<TerminalMacro> get macros;
  Future<String?> submitText(String paneId, String text);
  Future<String?> sendBytes(String paneId, String bytes);
  Future<String?> backspace(String paneId, int count);
  Future<String?> scroll(String paneId, int lines, {required bool up});
  Future<String?> scrollBottom(String paneId);
  Future<String?> runMacro(String paneId, TerminalMacro macro);
}

/// The app around the controller.
abstract class VoiceHost {
  /// Speaks outside an utterance reply (for example a failure that arrives
  /// after the command was acknowledged).
  void speak(String text);
  bool get appVisible;
  void openKeyboard();
  void closeKeyboard();
  void stopListening();
}

/// The immediate answer to one utterance: a tone and optional speech.
class VoiceReply {
  const VoiceReply(this.tone, [this.speech]);
  final VoiceTone? tone;
  final String? speech;
  Map<String, Object?> toJson() => {'tone': tone?.name, 'speak': speech};
}

typedef VoiceTimerFactory =
    Timer Function(Duration duration, void Function() callback);

class _Pending {
  _Pending(this.command, this.paneId, this.run, this.timer);
  final VoiceCommand command;
  final String paneId;
  final Future<void> Function() run;
  final Timer timer;
}

/// Drafts larger than this stop growing (and say so).
const voiceDraftLimit = 8000;

/// Backspace counts above this ask first when they go to the pane.
const voiceBackspaceConfirmOver = 30;

class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.terminal,
    required this.host,
    VoiceTimerFactory? timer,
    this.confirmTimeout = const Duration(seconds: 12),
  }) : _timer = timer ?? Timer.new;

  final VoiceTerminal terminal;
  final VoiceHost host;
  final VoiceTimerFactory _timer;
  final Duration confirmTimeout;

  final _drafts = <String, String>{};
  String? _targetPaneId;
  _Pending? _pending;
  bool _enterWarned = false;
  final _sending = <String>{};
  bool _disposed = false;

  /// The last thing heard and what it became, for the screen.
  String? lastHeard;
  String? lastOutcome;

  bool get confirming => _pending != null;
  String? get pendingPrompt =>
      _pending == null ? null : _confirmPrompt(_pending!.command);

  /// The selected window: the chosen one while it stays bound, else the
  /// first bound window.
  VoiceWindow? get target {
    final windows = terminal.windows;
    if (windows.isEmpty) return null;
    for (final w in windows) {
      if (w.paneId == _targetPaneId) return w;
    }
    return windows.first;
  }

  int? get targetNumber {
    final t = target;
    if (t == null) return null;
    return terminal.windows.indexWhere((w) => w.paneId == t.paneId) + 1;
  }

  String draftFor(String paneId) => _drafts[paneId] ?? '';
  String get draft => target == null ? '' : draftFor(target!.paneId);

  /// One line for the notification and the screen.
  String get statusLine {
    final t = target;
    if (t == null) return 'No window bound';
    final words = _wordCount(draft);
    return 'Window $targetNumber · ${t.label} · '
        '${words == 0 ? 'draft empty' : 'draft $words word${words == 1 ? '' : 's'}'}';
  }

  /// Handles one recognized utterance and returns the tone (and any speech)
  /// to play before listening resumes.
  VoiceReply handle(String transcript) {
    final text = transcript.trim();
    if (text.isEmpty || _disposed) return const VoiceReply(null);
    lastHeard = text;
    final reply = _handle(text);
    notifyListeners();
    return reply;
  }

  VoiceReply _handle(String text) {
    String? cancelled;
    final pending = _pending;
    var command = parseVoiceCommand(text, confirming: pending != null);
    if (pending != null) {
      _clearPending();
      if (command?.kind == VoiceCommandKind.confirmYes) {
        lastOutcome = 'Confirmed: ${pending.command.echo}';
        unawaited(pending.run());
        return const VoiceReply(VoiceTone.command);
      }
      if (command?.kind == VoiceCommandKind.confirmNo) {
        lastOutcome = 'Cancelled';
        return const VoiceReply(VoiceTone.command, 'Cancelled');
      }
      // Anything else cancels the confirmation and is handled as usual.
      cancelled = 'Cancelled.';
    }
    if (command == null) return _dictate(text, cancelled);
    if (command.kind != VoiceCommandKind.enter) _enterWarned = false;
    if (command.kind == VoiceCommandKind.macroName) {
      final macro = _macroByName(command.text ?? '');
      // An unknown name is not a command: "macro economics" is dictation.
      if (macro == null) return _dictate(text, cancelled);
      command = VoiceCommand(
        VoiceCommandKind.macroName,
        'Macro ${macro.name}',
        text: macro.id,
      );
    }
    final reply = _command(command);
    if (cancelled == null) return reply;
    return VoiceReply(
      reply.tone,
      [cancelled, reply.speech].whereType<String>().join(' '),
    );
  }

  VoiceReply _dictate(String text, String? prefix) {
    _enterWarned = false;
    final t = target;
    if (t == null) {
      lastOutcome = 'No window bound';
      return VoiceReply(VoiceTone.error, _join(prefix, 'No window is bound.'));
    }
    final current = draftFor(t.paneId);
    final next = current.isEmpty ? text : '$current $text';
    if (next.length > voiceDraftLimit) {
      lastOutcome = 'Draft is full';
      return VoiceReply(VoiceTone.error, _join(prefix, 'The draft is full.'));
    }
    _drafts[t.paneId] = next;
    lastOutcome = 'Added to draft';
    return VoiceReply(VoiceTone.dictation, prefix);
  }

  String? _join(String? a, String b) => a == null ? b : '$a $b';

  VoiceReply _command(VoiceCommand command) {
    lastOutcome = command.echo;
    final t = target;
    switch (command.kind) {
      case VoiceCommandKind.stopListening:
        host.stopListening();
        return const VoiceReply(VoiceTone.command);
      case VoiceCommandKind.openKeyboard:
      case VoiceCommandKind.closeKeyboard:
        if (!host.appVisible) {
          return const VoiceReply(VoiceTone.error, "DevOTA isn't open.");
        }
        command.kind == VoiceCommandKind.openKeyboard
            ? host.openKeyboard()
            : host.closeKeyboard();
        return const VoiceReply(VoiceTone.command);
      case VoiceCommandKind.listMacros:
        final macros = terminal.macros;
        if (macros.isEmpty) {
          return const VoiceReply(VoiceTone.command, 'No macros.');
        }
        return VoiceReply(
          VoiceTone.command,
          [
            for (var i = 0; i < macros.length && i < 9; i++)
              '${i + 1}, ${macros[i].name}.',
          ].join(' '),
        );
      case VoiceCommandKind.confirmYes:
      case VoiceCommandKind.confirmNo:
        // Only parsed while confirming, which is handled above.
        return const VoiceReply(null);
      default:
        break;
    }
    if (t == null) {
      return const VoiceReply(VoiceTone.error, 'No window is bound.');
    }
    final pane = t.paneId;
    final number = targetNumber!;
    switch (command.kind) {
      case VoiceCommandKind.window:
        final n = command.count!;
        final windows = terminal.windows;
        if (n > windows.length) {
          return VoiceReply(VoiceTone.error, 'There is no window $n.');
        }
        _targetPaneId = windows[n - 1].paneId;
        return VoiceReply(VoiceTone.command, 'Window $n.');
      case VoiceCommandKind.whichWindow:
        final words = _wordCount(draft);
        return VoiceReply(
          VoiceTone.command,
          'Window $number of ${terminal.windows.length}. '
          '${words == 0 ? 'The draft is empty.' : 'The draft has $words word${words == 1 ? '' : 's'}.'}',
        );
      case VoiceCommandKind.readBack:
        final d = draft;
        return VoiceReply(
          VoiceTone.command,
          d.isEmpty ? 'The draft is empty.' : d,
        );
      case VoiceCommandKind.clearDraft:
        if (draft.isEmpty) {
          return const VoiceReply(VoiceTone.command, 'The draft is empty.');
        }
        return _confirm(command, pane, () async {
          _drafts.remove(pane);
          lastOutcome = 'Draft cleared';
          _changed();
        });
      case VoiceCommandKind.submit:
        final d = draft;
        if (d.isEmpty) {
          return _send(command, pane, () => terminal.sendBytes(pane, '\r'));
        }
        if (_sending.contains(pane)) {
          return const VoiceReply(VoiceTone.error, 'Still sending.');
        }
        _sending.add(pane);
        unawaited(() async {
          String? failure;
          try {
            failure = await terminal.submitText(pane, d);
          } catch (_) {
            failure = 'delivery uncertain';
          } finally {
            _sending.remove(pane);
          }
          if (_disposed) return;
          if (failure == null) {
            // Keep anything dictated while the send was in flight.
            final now = draftFor(pane);
            final rest = now.startsWith(d)
                ? now.substring(d.length).trim()
                : now;
            rest.isEmpty ? _drafts.remove(pane) : _drafts[pane] = rest;
            lastOutcome = 'Sent to window $number';
          } else {
            lastOutcome = 'Not sent: $failure';
            host.speak('Not sent: $failure. The draft is kept.');
          }
          _changed();
        }());
        return const VoiceReply(VoiceTone.command);
      case VoiceCommandKind.enter:
        if (draft.isNotEmpty && !_enterWarned) {
          _enterWarned = true;
          return const VoiceReply(
            VoiceTone.command,
            'You have a draft. Say submit to send it, or enter again for '
            'Enter only.',
          );
        }
        _enterWarned = false;
        return _send(command, pane, () => terminal.sendBytes(pane, '\r'));
      case VoiceCommandKind.keys:
        final bytes = command.bytes!;
        Future<String?> run() => terminal.sendBytes(pane, bytes);
        return command.needsConfirm
            ? _confirm(command, pane, () => _deliver(command, run))
            : _send(command, pane, run);
      case VoiceCommandKind.backspace:
        final n = command.count!;
        final d = draft;
        if (d.isNotEmpty) {
          // A draft is DevOTA's own text: backspace edits it, not the pane.
          final next = n >= d.length ? '' : d.substring(0, d.length - n);
          next.isEmpty ? _drafts.remove(pane) : _drafts[pane] = next;
          lastOutcome = 'Deleted $n from the draft';
          return const VoiceReply(VoiceTone.command);
        }
        Future<String?> run() => terminal.backspace(pane, n);
        return n > voiceBackspaceConfirmOver
            ? _confirm(command, pane, () => _deliver(command, run))
            : _send(command, pane, run);
      case VoiceCommandKind.slash:
        final word = command.text!;
        Future<String?> run() => terminal.submitText(pane, '/$word');
        return command.needsConfirm
            ? _confirm(command, pane, () => _deliver(command, run))
            : _send(command, pane, run);
      case VoiceCommandKind.macroNumber:
        final n = command.count!;
        final macros = terminal.macros;
        if (n > macros.length) {
          return VoiceReply(VoiceTone.error, 'There is no macro $n.');
        }
        final macro = macros[n - 1];
        if (macro.isDeviceMacro) {
          return VoiceReply(
            VoiceTone.error,
            'Macro $n is a device macro. It does not run by voice.',
          );
        }
        final named = VoiceCommand(
          VoiceCommandKind.macroNumber,
          'Macro $n, ${macro.name}',
          count: n,
          needsConfirm: true,
        );
        return _confirm(
          named,
          pane,
          () => _deliver(named, () => terminal.runMacro(pane, macro)),
        );
      case VoiceCommandKind.macroName:
        final macro = terminal.macros.firstWhere((m) => m.id == command.text);
        if (macro.isDeviceMacro) {
          return VoiceReply(
            VoiceTone.error,
            '${macro.name} is a device macro. It does not run by voice.',
          );
        }
        return _send(command, pane, () => terminal.runMacro(pane, macro));
      case VoiceCommandKind.scrollUp:
      case VoiceCommandKind.scrollDown:
        return _send(
          command,
          pane,
          () => terminal.scroll(
            pane,
            command.count!,
            up: command.kind == VoiceCommandKind.scrollUp,
          ),
        );
      case VoiceCommandKind.scrollBottom:
        return _send(command, pane, () => terminal.scrollBottom(pane));
      default:
        return const VoiceReply(null);
    }
  }

  VoiceReply _send(
    VoiceCommand command,
    String pane,
    Future<String?> Function() run,
  ) {
    unawaited(_deliver(command, run));
    return const VoiceReply(VoiceTone.command);
  }

  Future<void> _deliver(
    VoiceCommand command,
    Future<String?> Function() run,
  ) async {
    String? failure;
    try {
      failure = await run();
    } catch (_) {
      failure = 'delivery uncertain';
    }
    if (_disposed) return;
    if (failure != null) {
      lastOutcome = '${command.echo}: not sent, $failure';
      host.speak('Not sent: $failure.');
      _changed();
    }
  }

  VoiceReply _confirm(
    VoiceCommand command,
    String pane,
    Future<void> Function() run,
  ) {
    _clearPending();
    final timer = _timer(confirmTimeout, () {
      if (_disposed || _pending == null) return;
      _pending = null;
      lastOutcome = 'Cancelled: no answer';
      host.speak('Cancelled.');
      _changed();
    });
    _pending = _Pending(command, pane, () async {
      // The confirmation named a window; never send it to another one.
      if (!terminal.windows.any((w) => w.paneId == pane)) {
        host.speak('Not sent: window changed.');
        return;
      }
      await run();
    }, timer);
    lastOutcome = 'Waiting for yes: ${command.echo}';
    return VoiceReply(VoiceTone.command, _confirmPrompt(command));
  }

  String _confirmPrompt(VoiceCommand command) {
    final number = targetNumber;
    final where = number == null ? '' : ' in window $number';
    return '${command.echo}$where? Say yes to confirm.';
  }

  void _clearPending() {
    _pending?.timer.cancel();
    _pending = null;
  }

  /// Cancels a pending confirmation without speaking (listening stopped).
  void cancelPending() {
    if (_pending == null) return;
    _clearPending();
    _changed();
  }

  TerminalMacro? _macroByName(String spoken) {
    final said = _squash(spoken);
    if (said.isEmpty) return null;
    final macros = terminal.macros;
    final exact = macros.where((m) => _squash(m.name) == said).toList();
    if (exact.length == 1) return exact.single;
    if (exact.length > 1) return null;
    final close = macros
        .where((m) => _similarity(_squash(m.name), said) >= 0.8)
        .toList();
    return close.length == 1 ? close.single : null;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearPending();
    super.dispose();
  }
}

int _wordCount(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

String _squash(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// 1 - normalised Levenshtein distance.
double _similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  final longest = a.length > b.length ? a.length : b.length;
  return 1 - prev[b.length] / longest;
}
