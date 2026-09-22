import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'terminal_macro.dart';
import 'terminal_submission.dart';
import 'terminal_conclusion.dart';

typedef TerminalCommand = Future<String> Function(String command);
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// Notification bindings own routing. Only an initial numeric window selection
/// can be replaced; switching after input would change a multi-window macro.
String? notificationMacroError(TerminalMacro macro) {
  var inputStarted = false;
  for (final step in macro.steps) {
    if (step.type == TerminalMacroStepType.wait) continue;
    if (step.type == TerminalMacroStepType.tmux) {
      if (inputStarted) {
        return 'Not run: tmux switching after input is unsupported.';
      }
      if (!RegExp(r'^[0-9]$').hasMatch(step.value.trim())) {
        return 'Not run: only an initial numeric tmux window selection is supported.';
      }
      continue;
    }
    if (step.type == TerminalMacroStepType.device) {
      return 'Not run: device actions are unsupported here.';
    }
    if (step.type == TerminalMacroStepType.terminalKey &&
        (step.value == 'ctrl_b' || terminalKeySequence(step.value) == null)) {
      return 'Not run: unsupported terminal key ${step.value}.';
    }
    inputStarted = true;
  }
  return null;
}

class WatchedPane {
  const WatchedPane({
    required this.id,
    required this.identity,
    required this.label,
    required this.window,
  });
  final String id;
  final String identity;
  final String label;
  final String window;

  Map<String, dynamic> toJson() => {
    'id': id,
    'identity': identity,
    'label': label,
    'window': window,
  };
  factory WatchedPane.fromJson(Map<String, dynamic> json) => WatchedPane(
    id: json['id'] as String,
    identity: json['identity'] as String,
    label: json['label'] as String,
    window: json['window'] as String,
  );
}

class TerminalWatchBinding {
  TerminalWatchBinding({required this.pane, required this.macroId});
  final WatchedPane pane;
  final String macroId;
  Map<String, dynamic> toJson() => {'pane': pane.toJson(), 'macroId': macroId};
  factory TerminalWatchBinding.fromJson(Map<String, dynamic> json) =>
      TerminalWatchBinding(
        pane: WatchedPane.fromJson(
          Map<String, dynamic>.from(json['pane'] as Map),
        ),
        macroId: json['macroId'] as String,
      );
}

/// No screen/widget dependency: captures and keystrokes use separate SSH exec
/// channels, never the currently selected interactive terminal window.
class TmuxWatchTransport {
  TmuxWatchTransport(this.command, {this.reviewer});
  final TerminalCommand command;
  final Future<String> Function(String text)? reviewer;
  static const identityFormat = '#{pid}:#{session_created}:#{pane_pid}';

  Future<List<WatchedPane>> panes() async {
    final raw = await command(
      "tmux list-panes -a -F "
      "'#{pane_id}\t$identityFormat\t#{window_index}\t#{session_name}:#{window_index}.#{pane_index}'",
    );
    return raw.split('\n').where((line) => line.isNotEmpty).map((line) {
      final fields = line.split('\t');
      if (fields.length != 4 || !RegExp(r'^%\d+$').hasMatch(fields[0])) {
        throw StateError('Could not identify tmux panes');
      }
      return WatchedPane(
        id: fields[0],
        identity: fields[1],
        window: fields[2],
        label: fields[3],
      );
    }).toList();
  }

  String _guard(WatchedPane pane) {
    if (!RegExp(r'^%\d+$').hasMatch(pane.id)) throw StateError('Invalid pane');
    return 'test "\$(tmux display-message -p -t ${shellQuote(pane.id)} '
        '${shellQuote(identityFormat)})" = ${shellQuote(pane.identity)} && ';
  }

  Future<String> capture(WatchedPane pane) => command(
    '${_guard(pane)}'
    'tmux capture-pane -p -e -N -t ${shellQuote(pane.id)}',
  );

  Future<String> history(WatchedPane pane, {int lines = 120}) => command(
    '${_guard(pane)}tmux capture-pane -p -J -S -${lines.clamp(20, 800)} -t ${shellQuote(pane.id)}',
  );

  Future<void> paste(WatchedPane pane, String text) async {
    // A private named buffer avoids overwriting the user's tmux paste buffer.
    // -p brackets the paste when the receiving application requests it.
    final buffer = 'devota-${DateTime.now().microsecondsSinceEpoch}';
    final encoded = base64Encode(utf8.encode(text));
    await command(
      '${_guard(pane)}'
      'printf %s ${shellQuote(encoded)} | base64 -d | '
      'tmux load-buffer -b ${shellQuote(buffer)} - && '
      '${_guard(pane)}tmux paste-buffer -d -p -b ${shellQuote(buffer)} '
      '-t ${shellQuote(pane.id)}',
    );
  }

  Future<void> key(WatchedPane pane, String value) async {
    final sequence = terminalKeySequence(value);
    if (sequence == null) throw StateError('Unknown key: $value');
    final bytes = utf8
        .encode(sequence)
        .map((b) => b.toRadixString(16))
        .join(' ');
    await command(
      '${_guard(pane)}tmux send-keys -H -t ${shellQuote(pane.id)} $bytes',
    );
  }
}

class PaneObservation {
  String? content;
  DateTime? changedAt;
  DateTime? observedAt;
  String? error;
  String? runError;
  bool submissionUnconfirmed = false;
  int revision = 0;
  ConclusionVerdict? verdict;
  int? reviewedRevision;
  int reviewAttempts = 0;
  DateTime? nextReviewAt;
  int? reviewingRevision;
  bool macroSent = false;
  String? submittedScreen;
  bool awaitingOutput = false;

  void observe(String value, DateTime now, Duration freshness) {
    if (awaitingOutput && value != submittedScreen) awaitingOutput = false;
    if (content != value ||
        observedAt == null ||
        error != null ||
        now.difference(observedAt!) > freshness) {
      changedAt = now;
      revision++;
      verdict = null;
    }
    content = value;
    observedAt = now;
    error = null;
  }

  bool settled(DateTime now, Duration quiet, Duration freshness) =>
      error == null &&
      observedAt != null &&
      changedAt != null &&
      now.difference(observedAt!) <= freshness &&
      now.difference(changedAt!) >= quiet;
}

class TerminalWatchController extends ChangeNotifier {
  TerminalWatchController({
    DateTime Function()? now,
    this.quietPeriod = const Duration(seconds: 10),
    this.freshness = const Duration(seconds: 8),
  }) : now = now ?? DateTime.now;
  final DateTime Function() now;
  Duration quietPeriod;
  final Duration freshness;
  List<TerminalWatchBinding> bindings = [];
  List<TerminalMacro> macros = [];
  final observations = <String, PaneObservation>{};
  TmuxWatchTransport? _transport;
  Timer? _timer;
  Future<void>? _polling;
  int _generation = 0;
  final String _instance = DateTime.now().microsecondsSinceEpoch.toString();
  bool _disposed = false;
  bool _busy = false;
  bool get busy => _busy;
  bool externalBusy = false;
  bool reviewEnabled = true;
  bool _reviewing = false;
  String? runningPane;
  String? progress;
  bool _stop = false;
  int get generation => _generation;

  void updateMacros(List<TerminalMacro> available) {
    if (jsonEncode(macros.map((m) => m.toJson()).toList()) ==
        jsonEncode(available.map((m) => m.toJson()).toList())) {
      return;
    }
    _generation++; // Invalidate buttons and stop a run whose definition changed.
    macros = List.of(available);
  }

  void connect(TmuxWatchTransport? transport) {
    _generation++;
    _transport = transport;
    _timer?.cancel();
    for (final state in observations.values) {
      state.observedAt = null;
      state.error = 'Disconnected / unknown';
      state.revision++;
    }
    if (transport != null) {
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(poll()),
      );
      unawaited(poll());
    }
    _notify();
  }

  Future<List<WatchedPane>> availablePanes() async {
    final transport = _transport;
    if (transport == null) throw StateError('Connect SSH first');
    return transport.panes();
  }

  void configure(
    List<TerminalWatchBinding> next,
    List<TerminalMacro> available,
  ) {
    if (busy) throw StateError('Wait for the current macro');
    _generation++;
    bindings = List.of(next);
    macros = List.of(available);
    observations.clear();
    _notify();
    unawaited(poll());
  }

  TerminalMacro? macroFor(TerminalWatchBinding binding) {
    for (final macro in macros) {
      if (macro.id == binding.macroId) return macro;
    }
    return null;
  }

  String token(TerminalWatchBinding binding) =>
      '$_instance:$_generation:${observations[binding.pane.id]?.revision ?? 0}';

  Future<void> poll() {
    if (_transport == null || _disposed) return Future.value();
    if (_polling != null) return _polling!;
    final operation = _poll();
    _polling = operation;
    return operation.whenComplete(() => _polling = null);
  }

  Future<void> _poll() async {
    final transport = _transport;
    final generation = _generation;
    if (transport == null || _disposed) return;
    await Future.wait(
      bindings.map((binding) async {
        final state = observations.putIfAbsent(
          binding.pane.id,
          PaneObservation.new,
        );
        try {
          final content = await transport.capture(binding.pane);
          if (generation != _generation || _disposed) return;
          state.observe(content, now(), freshness);
        } catch (_) {
          if (generation != _generation || _disposed) return;
          state.error = 'Disconnected / pane unavailable';
          state.observedAt = null;
          state.revision++;
        }
      }),
    );
    _notify();
    unawaited(_reviewNext());
  }

  bool canAct(TerminalWatchBinding binding) =>
      !busy &&
      !externalBusy &&
      _transport != null &&
      macroFor(binding) != null &&
      (observations[binding.pane.id]?.settled(now(), quietPeriod, freshness) ??
          false);

  List<Map<String, Object>> get cards => bindings.map((binding) {
    final state = observations[binding.pane.id];
    final settled = state?.settled(now(), quietPeriod, freshness) ?? false;
    final macro = macroFor(binding);
    var status = runningPane == binding.pane.id
        ? progress ?? 'Running macro'
        : macro == null
        ? 'Macro unavailable'
        : state?.error ??
              state?.runError ??
              (state?.observedAt == null ||
                      now().difference(state!.observedAt!) > freshness
                  ? 'Disconnected / unknown'
                  : settled
                  ? (state.submissionUnconfirmed
                        ? 'Settled · submission unconfirmed'
                        : 'Settled · no content changes')
                  : state.submissionUnconfirmed
                  ? 'Changing · submission unconfirmed'
                  : 'Changing');
    if (reviewEnabled &&
        settled &&
        state?.runError == null &&
        state?.verdict != null &&
        runningPane != binding.pane.id) {
      status = '${state!.verdict!.label} · ${state.verdict!.reason}';
      if (state.verdict!.retryable) {
        status = state.nextReviewAt != null
            ? '↻ Check retry ${state.reviewAttempts + 1}/3 pending · ${state.verdict!.reason}'
            : '⚠ Check unavailable after 3 attempts · outcome unknown';
      }
    } else if (runningPane != binding.pane.id &&
        state?.macroSent == true &&
        state?.runError == null &&
        state?.error == null) {
      status = 'Macro sent · $status';
    }
    if (reviewEnabled &&
        settled &&
        state?.runError == null &&
        !busy &&
        !externalBusy &&
        state?.reviewingRevision == state?.revision &&
        state?.reviewingRevision != null) {
      status = 'Checking outcome · attempt ${state!.reviewAttempts}/3';
    }
    return <String, Object>{
      'id': binding.pane.id,
      'title': binding.pane.label,
      'status': status,
      'macro': macro?.name ?? 'Unavailable',
      'token': token(binding),
      'run': canAct(binding),
      'enter': canAct(binding) && (state?.submissionUnconfirmed ?? false),
      'stop': runningPane == binding.pane.id && busy,
      'listen': canAct(binding),
    };
  }).toList();

  Future<String> conclusion(
    String paneId,
    String expectedToken, {
    int lines = 120,
  }) async {
    final binding = bindings.firstWhere((b) => b.pane.id == paneId);
    if (token(binding) != expectedToken || !canAct(binding)) {
      throw StateError('Terminal changed');
    }
    final generation = _generation;
    final transport = _transport!;
    final before = await transport.capture(binding.pane);
    final state = observations[paneId]!;
    if (before != state.content) throw StateError('Terminal changed');
    final raw = await transport.history(binding.pane, lines: lines);
    final after = await transport.capture(binding.pane);
    if (_disposed ||
        _generation != generation ||
        token(binding) != expectedToken ||
        after != before) {
      throw StateError('Terminal changed');
    }
    final clean = cleanTerminalConclusion(raw);
    if (clean.length <= 24000) return clean;
    final tail = clean.substring(clean.length - 24000);
    final boundary = tail.indexOf('\n');
    return boundary >= 0 ? tail.substring(boundary + 1) : tail;
  }

  Future<void> _reviewNext() async {
    final transport = _transport;
    if (_disposed ||
        _reviewing ||
        !reviewEnabled ||
        busy ||
        externalBusy ||
        transport == null ||
        transport.reviewer == null) {
      return;
    }
    for (final binding in bindings) {
      final state = observations[binding.pane.id];
      if (state == null || !canAct(binding) || state.awaitingOutput) {
        continue;
      }
      if (state.reviewedRevision == state.revision) {
        if (state.nextReviewAt == null || now().isBefore(state.nextReviewAt!)) {
          continue;
        }
      } else {
        state.reviewAttempts = 0;
      }
      final generation = _generation;
      final revision = state.revision;
      state.reviewedRevision = revision;
      state.reviewAttempts++;
      state.nextReviewAt = null;
      state.reviewingRevision = revision;
      _reviewing = true;
      _notify();
      try {
        var source = await conclusion(binding.pane.id, token(binding));
        if (source.length > 10000) {
          source = source.substring(source.length - 10000);
          final boundary = source.indexOf('\n');
          if (boundary >= 0) source = source.substring(boundary + 1);
        }
        final result = ConclusionVerdict.parse(
          await transport.reviewer!(source),
          source,
        );
        if (!_disposed &&
            generation == _generation &&
            state.revision == revision &&
            !busy &&
            !externalBusy &&
            reviewEnabled) {
          _storeReview(state, result);
        }
      } catch (_) {
        if (!_disposed &&
            generation == _generation &&
            state.revision == revision &&
            reviewEnabled &&
            !busy &&
            !externalBusy) {
          _storeReview(state, ConclusionVerdict.unavailable);
        }
      } finally {
        _reviewing = false;
        state.reviewingRevision = null;
        _notify();
      }
      return; // One bounded job at a time; the next poll considers other panes.
    }
  }

  void _storeReview(PaneObservation state, ConclusionVerdict result) {
    state.verdict = result;
    // At most three read-only checks per unchanged revision; never retry input.
    state.nextReviewAt = result.retryable && state.reviewAttempts < 3
        ? now().add(Duration(seconds: state.reviewAttempts == 1 ? 30 : 90))
        : null;
  }

  void stop() {
    _stop = true;
  }

  Future<void> act(String paneId, String action, String expectedToken) async {
    if (_disposed || busy || externalBusy) return;
    final matching = bindings.where((b) => b.pane.id == paneId);
    if (matching.isEmpty) return;
    final binding = matching.first;
    if (token(binding) != expectedToken || !canAct(binding)) {
      rejectAction(
        paneId,
        'Not sent: button expired or terminal changed. Use the current button once settled.',
      );
      return;
    }
    if (action != 'run' && action != 'enter') return;
    final state = observations[paneId]!;
    if (action == 'enter' && !state.submissionUnconfirmed) return;
    final transport = _transport!;
    final generation = _generation;
    final macro = macroFor(binding)!;
    _busy = true; // Lock synchronously, before preflight network operations.
    _stop = false;
    state.runError = null;
    state.verdict = null;
    if (action == 'run') state.macroSent = false;
    runningPane = paneId;
    progress = 'Checking terminal';
    _notify();
    var inputAttempted = false;
    try {
      if (action == 'run') {
        final compatibilityError = notificationMacroError(macro);
        if (compatibilityError != null) throw StateError(compatibilityError);
      }
      final tappedContent = state.content;
      final before = await transport.capture(binding.pane);
      _checkRun(generation);
      // The user tapped a fresh, settled snapshot. A slow read must not turn
      // an identical confirmation into a false "still changing" rejection.
      // Still reject if either the fresh read or concurrent polling saw change.
      final changed = before != tappedContent || state.content != tappedContent;
      state.observe(before, now(), freshness);
      if (changed) {
        throw StateError(
          'Not sent: terminal text changed during the check. Wait for it to settle, then tap again.',
        );
      }
      state.revision++;
      state.submittedScreen = before;
      state.awaitingOutput = true;
      if (action == 'enter') {
        inputAttempted = true;
        await transport.key(binding.pane, 'enter');
        _checkRun(generation);
      } else {
        for (var i = 0; i < macro.steps.length; i++) {
          _checkRun(generation);
          final step = macro.steps[i];
          progress = '${macro.name} · step ${i + 1}/${macro.steps.length}';
          _notify();
          switch (step.type) {
            case TerminalMacroStepType.shell:
              if (step.value.trim().isNotEmpty) {
                inputAttempted = true;
                await transport.paste(binding.pane, step.value);
                await _delay(terminalPasteSettleTime, generation);
                if (commandNeedsEnter(macro.steps, i)) {
                  await transport.key(binding.pane, 'enter');
                  state.submissionUnconfirmed = true;
                }
              }
            case TerminalMacroStepType.terminalKey:
              inputAttempted = true;
              await transport.key(binding.pane, step.value);
              if (step.value == 'enter') state.submissionUnconfirmed = true;
            case TerminalMacroStepType.wait:
            case TerminalMacroStepType.tmux:
              break; // Initial selection is overridden by the bound pane ID.
            case TerminalMacroStepType.device:
              throw StateError('Device macro is not a terminal macro');
          }
          await _delay(
            Duration(milliseconds: (step.delaySeconds * 1000).round()),
            generation,
          );
        }
      }
      state.error = null;
      if (action == 'run') state.macroSent = true;
    } catch (error) {
      // Input may have reached the remote process even when its ACK was lost.
      // Never replay it on reconnect or claim success from socket writes.
      if (inputAttempted) state.submissionUnconfirmed = true;
      state.runError = error is StateError
          ? error.message.toString()
          : 'Input delivery uncertain';
    } finally {
      state.changedAt = now();
      state.revision++;
      state.verdict = null;
      _busy = false;
      runningPane = null;
      progress = null;
      _notify();
    }
  }

  void _checkRun(int generation) {
    if (_disposed || _stop || generation != _generation || _transport == null) {
      throw StateError('Stopped · input may have been sent');
    }
  }

  void rejectAction(String paneId, String message) {
    if (_disposed || busy || externalBusy) return;
    final state = observations[paneId];
    if (state == null) return;
    state.runError = message;
    _notify();
  }

  Future<void> _delay(Duration duration, int generation) async {
    var remaining = duration.inMilliseconds;
    while (remaining > 0) {
      _checkRun(generation);
      final slice = remaining > 100 ? 100 : remaining;
      await Future<void>.delayed(Duration(milliseconds: slice));
      remaining -= slice;
    }
    _checkRun(generation);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
