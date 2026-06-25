import 'package:flutter/foundation.dart';

enum TerminalMacroStepType { shell, terminalKey, tmux, wait }

class MacroStepOption {
  const MacroStepOption(this.value, this.label);

  final String value;
  final String label;
}

const terminalMacroTerminalKeyOptions = [
  MacroStepOption('enter', 'Enter'),
  MacroStepOption('ctrl_b', 'Ctrl-B'),
  MacroStepOption('ctrl_c', 'Ctrl-C'),
  MacroStepOption('tab', 'Tab'),
  MacroStepOption('esc', 'Esc'),
  MacroStepOption('slash', '/'),
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
  };
}

String defaultTerminalMacroStepValue(TerminalMacroStepType type) {
  return switch (type) {
    TerminalMacroStepType.shell => '',
    TerminalMacroStepType.terminalKey => 'enter',
    TerminalMacroStepType.tmux => 'c',
    TerminalMacroStepType.wait => '',
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
  });

  final String id;
  final String name;
  final List<TerminalMacroStep> steps;

  TerminalMacro copyWith({
    String? id,
    String? name,
    List<TerminalMacroStep>? steps,
  }) {
    return TerminalMacro(
      id: id ?? this.id,
      name: name ?? this.name,
      steps: steps ?? this.steps,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'steps': steps.map((step) => step.toJson()).toList(),
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
      steps: steps,
    );
  }
}

String newTerminalMacroId(String prefix) {
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}

class TerminalMacroController extends ChangeNotifier {
  Future<void> Function(TerminalMacro macro)? _runner;
  bool Function()? _canRun;
  bool Function()? _isRunning;

  bool get canRun => _canRun?.call() ?? false;
  bool get isRunning => _isRunning?.call() ?? false;
  bool get isAttached => _runner != null;

  void attach({
    required Future<void> Function(TerminalMacro macro) runner,
    required bool Function() canRun,
    required bool Function() isRunning,
  }) {
    _runner = runner;
    _canRun = canRun;
    _isRunning = isRunning;
    notifyListeners();
  }

  void detach() {
    _runner = null;
    _canRun = null;
    _isRunning = null;
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
