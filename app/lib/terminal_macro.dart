import 'package:flutter/foundation.dart';

enum TerminalMacroStepType { shell, terminalKey, tmux, wait, device }

class MacroStepOption {
  const MacroStepOption(this.value, this.label);

  final String value;
  final String label;
}

const terminalMacroTerminalKeyOptions = [
  MacroStepOption('enter', 'Enter'),
  MacroStepOption('backspace', 'Backspace'),
  MacroStepOption('ctrl_b', 'Ctrl-B'),
  MacroStepOption('ctrl_c', 'Ctrl-C'),
  MacroStepOption('tab', 'Tab'),
  MacroStepOption('esc', 'Esc'),
  MacroStepOption('slash', '/'),
  MacroStepOption('0', '0'),
  MacroStepOption('1', '1'),
  MacroStepOption('2', '2'),
  MacroStepOption('3', '3'),
  MacroStepOption('4', '4'),
  MacroStepOption('5', '5'),
  MacroStepOption('6', '6'),
  MacroStepOption('7', '7'),
  MacroStepOption('8', '8'),
  MacroStepOption('9', '9'),
  MacroStepOption('home', 'Home'),
  MacroStepOption('end', 'End'),
  MacroStepOption('page_up', 'PgUp'),
  MacroStepOption('page_down', 'PgDn'),
  MacroStepOption('up', 'Up'),
  MacroStepOption('down', 'Down'),
  MacroStepOption('left', 'Left'),
  MacroStepOption('right', 'Right'),
];

const terminalMacroTmuxOptions = [
  MacroStepOption('\x02', 'Prefix'),
  MacroStepOption('0', 'Window 0'),
  MacroStepOption('1', 'Window 1'),
  MacroStepOption('2', 'Window 2'),
  MacroStepOption('3', 'Window 3'),
  MacroStepOption('4', 'Window 4'),
  MacroStepOption('5', 'Window 5'),
  MacroStepOption('6', 'Window 6'),
  MacroStepOption('7', 'Window 7'),
  MacroStepOption('8', 'Window 8'),
  MacroStepOption('9', 'Window 9'),
  MacroStepOption('c', 'New'),
  MacroStepOption('p', 'Prev'),
  MacroStepOption('n', 'Next'),
  MacroStepOption('w', 'List'),
  MacroStepOption('[', 'Scroll'),
  MacroStepOption('%', 'Split |'),
  MacroStepOption('"', 'Split -'),
  MacroStepOption('d', 'Detach'),
];

String terminalMacroStepTypeLabel(TerminalMacroStepType type) {
  return switch (type) {
    TerminalMacroStepType.shell => 'Command',
    TerminalMacroStepType.terminalKey => 'Key',
    TerminalMacroStepType.tmux => 'tmux',
    TerminalMacroStepType.wait => 'Wait',
    TerminalMacroStepType.device => 'Device action',
  };
}

String? terminalMacroTmuxSequence(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final windowIndex = int.tryParse(trimmed);
  if (windowIndex != null) {
    if (trimmed.length == 1 && windowIndex >= 0) {
      return '\x02$trimmed';
    }
    return null;
  }
  return '\x02$value';
}

String defaultTerminalMacroStepValue(TerminalMacroStepType type) {
  return switch (type) {
    TerminalMacroStepType.shell => '',
    TerminalMacroStepType.terminalKey => 'enter',
    TerminalMacroStepType.tmux => 'c',
    TerminalMacroStepType.wait => '',
    TerminalMacroStepType.device =>
      '{"action":"openSettings","args":{},"capture":true}',
  };
}

double defaultTerminalMacroStepDelay(TerminalMacroStepType type) {
  return type == TerminalMacroStepType.wait ? 1 : 0;
}

String terminalMacroStepValueLabel(TerminalMacroStep step) {
  final options = switch (step.type) {
    TerminalMacroStepType.terminalKey => terminalMacroTerminalKeyOptions,
    TerminalMacroStepType.tmux => terminalMacroTmuxOptions,
    _ => const <MacroStepOption>[],
  };
  for (final option in options) {
    if (option.value == step.value) return option.label;
  }
  return step.value;
}

TerminalMacroStepType terminalMacroStepTypeFromName(String value) {
  return TerminalMacroStepType.values.firstWhere(
    (type) => type.name == value,
    orElse: () => TerminalMacroStepType.shell,
  );
}

class TerminalMacroStep {
  const TerminalMacroStep({
    required this.id,
    required this.type,
    required this.value,
    required this.delaySeconds,
  });

  final String id;
  final TerminalMacroStepType type;
  final String value;
  final double delaySeconds;

  TerminalMacroStep copyWith({
    String? id,
    TerminalMacroStepType? type,
    String? value,
    double? delaySeconds,
  }) {
    return TerminalMacroStep(
      id: id ?? this.id,
      type: type ?? this.type,
      value: value ?? this.value,
      delaySeconds: delaySeconds ?? this.delaySeconds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'value': value,
      'delaySeconds': delaySeconds,
    };
  }

  factory TerminalMacroStep.fromJson(Map<String, dynamic> json) {
    final type = terminalMacroStepTypeFromName(json['type']?.toString() ?? '');
    final rawDelay = json['delaySeconds'];
    final delay = rawDelay is num
        ? rawDelay.toDouble()
        : double.tryParse(rawDelay?.toString() ?? '') ?? 0;
    return TerminalMacroStep(
      id: json['id']?.toString() ?? newTerminalMacroId('step'),
      type: type,
      value: json['value']?.toString() ?? defaultTerminalMacroStepValue(type),
      delaySeconds: delay < 0 ? 0 : delay,
    );
  }
}

class TerminalMacro {
  const TerminalMacro({
    required this.id,
    required this.name,
    required this.steps,
    this.priority = 0,
    this.failureDiagnostics,
  });

  final String id;
  final String name;
  final List<TerminalMacroStep> steps;
  final int priority;
  final Map<String, dynamic>? failureDiagnostics;

  bool get isDeviceMacro =>
      steps.any((step) => step.type == TerminalMacroStepType.device);

  TerminalMacro copyWith({
    String? id,
    String? name,
    List<TerminalMacroStep>? steps,
    int? priority,
    Map<String, dynamic>? failureDiagnostics,
  }) {
    return TerminalMacro(
      id: id ?? this.id,
      name: name ?? this.name,
      steps: steps ?? this.steps,
      priority: priority ?? this.priority,
      failureDiagnostics: failureDiagnostics ?? this.failureDiagnostics,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'priority': priority,
      'steps': steps.map((step) => step.toJson()).toList(),
      if (failureDiagnostics != null) 'failureDiagnostics': failureDiagnostics,
    };
  }

  factory TerminalMacro.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'];
    final steps = rawSteps is List
        ? rawSteps
              .whereType<Map>()
              .map(
                (step) =>
                    TerminalMacroStep.fromJson(Map<String, dynamic>.from(step)),
              )
              .toList()
        : <TerminalMacroStep>[];
    return TerminalMacro(
      id: json['id']?.toString() ?? newTerminalMacroId('macro'),
      name: json['name']?.toString() ?? 'Macro',
      priority: json['priority'] is num
          ? (json['priority'] as num).toInt()
          : int.tryParse(json['priority']?.toString() ?? '') ?? 0,
      steps: steps,
      failureDiagnostics: json['failureDiagnostics'] is Map
          ? Map<String, dynamic>.from(json['failureDiagnostics'] as Map)
          : null,
    );
  }
}

/// Ranks macros without letting use-count updates move buttons during a run.
/// Higher user-selected priorities appear first; ties preserve saved order.
List<TerminalMacro> rankTerminalMacros(List<TerminalMacro> macros) {
  final indexed = macros.asMap().entries.toList();
  indexed.sort((a, b) {
    final priority = b.value.priority.compareTo(a.value.priority);
    if (priority != 0) return priority;
    return a.key.compareTo(b.key);
  });
  return indexed.map((entry) => entry.value).toList();
}

String newTerminalMacroId(String prefix) {
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}

TerminalMacroStep newTerminalMacroStep(
  TerminalMacroStepType type, [
  String? value,
]) {
  return TerminalMacroStep(
    id: newTerminalMacroId('step'),
    type: type,
    value: value ?? defaultTerminalMacroStepValue(type),
    delaySeconds: defaultTerminalMacroStepDelay(type),
  );
}

/// Live state of a macro run. Surfaced through [TerminalMacroController] so any
/// screen can show that the session is busy — a stray tap on a tmux or command
/// button mid-sequence lands in the middle of the macro's own input and
/// corrupts it, so every input surface has to be able to see this.
class MacroRunProgress {
  const MacroRunProgress({
    required this.macroName,
    required this.stepIndex,
    required this.stepCount,
    this.stopping = false,
  });

  final String macroName;

  /// 1-based step being executed; 0 before the first step starts.
  final int stepIndex;
  final int stepCount;

  /// The user asked to stop and the run is unwinding at the next safe point.
  final bool stopping;

  double? get fraction =>
      stepCount > 0 ? (stepIndex / stepCount).clamp(0.0, 1.0) : null;

  String get stepLabel =>
      stepCount > 0 ? 'step $stepIndex of $stepCount' : 'starting';
}

class TerminalMacroController extends ChangeNotifier {
  Future<void> Function(TerminalMacro macro)? _runner;
  bool Function()? _canRun;
  bool Function()? _isRunning;
  MacroRunProgress? Function()? _progress;
  VoidCallback? _stop;

  bool get canRun => _canRun?.call() ?? false;
  bool get isRunning => _isRunning?.call() ?? false;
  bool get isAttached => _runner != null;

  /// Non-null only while a macro is actually running.
  MacroRunProgress? get progress => isRunning ? _progress?.call() : null;

  bool get canStop => isRunning && _stop != null;

  /// Asks the runner to stop at the next step boundary (delays are sliced, so
  /// this takes effect quickly even mid-wait).
  void requestStop() {
    if (isRunning) _stop?.call();
  }

  void attach({
    required Future<void> Function(TerminalMacro macro) runner,
    required bool Function() canRun,
    required bool Function() isRunning,
    MacroRunProgress? Function()? progress,
    VoidCallback? stop,
  }) {
    _runner = runner;
    _canRun = canRun;
    _isRunning = isRunning;
    _progress = progress;
    _stop = stop;
    notifyListeners();
  }

  void detach() {
    _runner = null;
    _canRun = null;
    _isRunning = null;
    _progress = null;
    _stop = null;
    notifyListeners();
  }

  void notifyStateChanged() {
    notifyListeners();
  }

  Future<void> run(TerminalMacro macro) async {
    final runner = _runner;
    if (runner == null) {
      throw StateError('Terminal is not ready yet.');
    }
    await runner(macro);
  }
}
