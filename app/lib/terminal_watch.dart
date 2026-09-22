import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'terminal_macro.dart';
import 'terminal_submission.dart';

typedef TerminalCommand = Future<String> Function(String command);
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

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
  TmuxWatchTransport(this.command);
  final TerminalCommand command;
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
  bool submissionUnconfirmed = false;
  int revision = 0;

  void observe(String value, DateTime now, Duration freshness) {
    if (content != value ||
        observedAt == null ||
        error != null ||
        now.difference(observedAt!) > freshness) {
      changedAt = now;
      revision++;
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
  bool _disposed = false;
  bool _busy = false;
  bool get busy => _busy;
  bool externalBusy = false;
  String? runningPane;
  String? progress;
  bool _stop = false;
  int get generation => _generation;

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
      '$_generation:${observations[binding.pane.id]?.revision ?? 0}';

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
    final status = runningPane == binding.pane.id
        ? progress ?? 'Running macro'
        : macro == null
        ? 'Macro unavailable'
        : state?.error ??
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
    return <String, Object>{
      'id': binding.pane.id,
      'title': binding.pane.label,
      'status': status,
      'macro': macro?.name ?? 'Unavailable',
      'token': token(binding),
      'run': canAct(binding),
      'enter': canAct(binding) && (state?.submissionUnconfirmed ?? false),
      'stop': runningPane == binding.pane.id && busy,
    };
  }).toList();

  void stop() {
    _stop = true;
  }

  Future<void> act(String paneId, String action, String expectedToken) async {
    if (_disposed || busy || externalBusy) return;
    final matching = bindings.where((b) => b.pane.id == paneId);
    if (matching.isEmpty) return;
    final binding = matching.first;
    if (token(binding) != expectedToken || !canAct(binding)) return;
    if (action != 'run' && action != 'enter') return;
    final state = observations[paneId]!;
    if (action == 'enter' && !state.submissionUnconfirmed) return;
    final transport = _transport!;
    final generation = _generation;
    final macro = macroFor(binding)!;
    _busy = true; // Lock synchronously, before preflight network operations.
    _stop = false;
    runningPane = paneId;
    progress = 'Checking terminal';
    _notify();
    try {
      final before = await transport.capture(binding.pane);
      _checkRun(generation);
      state.observe(before, now(), freshness);
      if (!state.settled(now(), quietPeriod, freshness)) return;
      state.revision++;
      if (action == 'enter') {
        await transport.key(binding.pane, 'enter');
        _checkRun(generation);
      } else {
        // Preflight every step before sending any input.
        for (final step in macro.steps) {
          if (step.type == TerminalMacroStepType.device ||
              (step.type == TerminalMacroStepType.tmux &&
                  step.value != binding.pane.window) ||
              (step.type == TerminalMacroStepType.terminalKey &&
                  (step.value == 'ctrl_b' ||
                      terminalKeySequence(step.value) == null))) {
            throw StateError(
              'Use command/key/wait steps. Window switching is handled by the binding.',
            );
          }
        }
        for (var i = 0; i < macro.steps.length; i++) {
          _checkRun(generation);
          final step = macro.steps[i];
          progress = '${macro.name} · step ${i + 1}/${macro.steps.length}';
          _notify();
          switch (step.type) {
            case TerminalMacroStepType.shell:
              if (step.value.trim().isNotEmpty) {
                await transport.paste(binding.pane, step.value);
                await _delay(terminalPasteSettleTime, generation);
                if (commandNeedsEnter(macro.steps, i)) {
                  await transport.key(binding.pane, 'enter');
                  state.submissionUnconfirmed = true;
                }
              }
            case TerminalMacroStepType.terminalKey:
              await transport.key(binding.pane, step.value);
              if (step.value == 'enter') state.submissionUnconfirmed = true;
            case TerminalMacroStepType.wait:
            case TerminalMacroStepType.tmux:
              break; // Matching window selection is already resolved to pane ID.
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
    } catch (error) {
      // Input may have reached the remote process even when its ACK was lost.
      // Never replay it on reconnect or claim success from socket writes.
      state.submissionUnconfirmed = true;
      state.error = error is StateError
          ? error.message.toString()
          : 'Input delivery uncertain';
    } finally {
      state.changedAt = now();
      state.revision++;
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
