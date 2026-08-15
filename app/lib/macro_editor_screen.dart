import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'terminal_macro.dart';

/// Full-screen macro editing.
///
/// Macro editing used to live in a modal bottom sheet sized to a fraction of
/// the screen. The soft keyboard then covered whatever field had focus, so a
/// human could not see what they were typing, and selecting text for copy or
/// paste was hopeless. Everything here is a plain route with a resizing
/// [Scaffold], so the framework keeps the focused field above the keyboard,
/// and any command can be opened in [MacroCommandEditorScreen] - a full page
/// of monospace text with clipboard controls that sit above the keyboard.

double parseMacroDelaySeconds(String value) {
  final parsed = double.tryParse(value.trim()) ?? 0;
  if (!parsed.isFinite || parsed <= 0) return 0;
  return parsed;
}

String formatMacroDelaySeconds(double value) {
  if (value <= 0) return '';
  if (value == value.truncateToDouble()) return value.toStringAsFixed(0);
  return value.toString();
}

IconData macroStepTypeIcon(TerminalMacroStepType type) {
  return switch (type) {
    TerminalMacroStepType.shell => Icons.terminal,
    TerminalMacroStepType.terminalKey => Icons.keyboard,
    TerminalMacroStepType.tmux => Icons.tab,
    TerminalMacroStepType.wait => Icons.timer_outlined,
    TerminalMacroStepType.device => Icons.smartphone,
  };
}

Future<bool> _confirmDiscard(BuildContext context, String message) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Discard changes?'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return discard ?? false;
}

/// Mutable working copy of one step. Text lives in long-lived controllers so
/// typing never rebuilds the whole list and never resets the caret or an
/// in-progress selection.
class _StepDraft {
  _StepDraft.fromStep(TerminalMacroStep step)
    : id = step.id.isEmpty ? newTerminalMacroId('step') : step.id,
      type = step.type,
      optionValue =
          step.type == TerminalMacroStepType.shell ||
              step.type == TerminalMacroStepType.device
          ? defaultTerminalMacroStepValue(step.type)
          : step.value,
      valueController = TextEditingController(
        text:
            step.type == TerminalMacroStepType.shell ||
                step.type == TerminalMacroStepType.device
            ? step.value
            : '',
      ),
      delayController = TextEditingController(
        text: formatMacroDelaySeconds(step.delaySeconds),
      );

  final String id;
  TerminalMacroStepType type;
  String optionValue;
  final TextEditingController valueController;
  final TextEditingController delayController;
  final FocusNode valueFocusNode = FocusNode();

  TerminalMacroStep toStep() {
    return TerminalMacroStep(
      id: id,
      type: type,
      value:
          type == TerminalMacroStepType.shell ||
              type == TerminalMacroStepType.device
          ? valueController.text.trimRight()
          : optionValue,
      delaySeconds: parseMacroDelaySeconds(delayController.text),
    );
  }

  /// Switching type keeps the command text around: a human who flips a step to
  /// `Key` by mistake should not lose the command they just typed.
  void changeType(TerminalMacroStepType next) {
    if (next == type) return;
    type = next;
    if (next != TerminalMacroStepType.shell &&
        next != TerminalMacroStepType.device) {
      optionValue = defaultTerminalMacroStepValue(next);
    }
    if (next == TerminalMacroStepType.device &&
        valueController.text.trim().isEmpty) {
      valueController.text = defaultTerminalMacroStepValue(next);
    }
    if (next == TerminalMacroStepType.wait &&
        parseMacroDelaySeconds(delayController.text) == 0) {
      delayController.text = formatMacroDelaySeconds(
        defaultTerminalMacroStepDelay(next),
      );
    }
  }

  void dispose() {
    valueController.dispose();
    delayController.dispose();
    valueFocusNode.dispose();
  }
}

enum _StepAction {
  insertShell,
  insertKey,
  insertTmux,
  insertWait,
  insertDevice,
  moveUp,
  moveDown,
  duplicate,
  delete,
}

class MacroEditorScreen extends StatefulWidget {
  const MacroEditorScreen({
    super.key,
    required this.macro,
    this.savedCommands = const <String>[],
    this.isNew = false,
  });

  final TerminalMacro macro;
  final List<String> savedCommands;
  final bool isNew;

  @override
  State<MacroEditorScreen> createState() => _MacroEditorScreenState();
}

class _MacroEditorScreenState extends State<MacroEditorScreen> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.macro.name,
  );
  late final TextEditingController _priorityController = TextEditingController(
    text: widget.macro.priority.toString(),
  );
  final ScrollController _scrollController = ScrollController();
  final List<_StepDraft> _drafts = [];
  late String _originalJson;

  @override
  void initState() {
    super.initState();
    final steps = widget.macro.steps.isEmpty
        ? [newTerminalMacroStep(TerminalMacroStepType.shell)]
        : widget.macro.steps;
    _drafts.addAll(steps.map(_StepDraft.fromStep));
    _originalJson = _snapshotJson();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priorityController.dispose();
    _scrollController.dispose();
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  TerminalMacro _currentMacro() {
    return widget.macro.copyWith(
      name: _nameController.text.trim(),
      priority: int.tryParse(_priorityController.text.trim()) ?? 0,
      steps: _drafts.map((draft) => draft.toStep()).toList(),
    );
  }

  String _snapshotJson() => jsonEncode(_currentMacro().toJson());

  bool get _isDirty => _snapshotJson() != _originalJson;

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _addStep(TerminalMacroStep step, {int? afterIndex}) {
    setState(() {
      final draft = _StepDraft.fromStep(step);
      if (afterIndex == null || afterIndex >= _drafts.length - 1) {
        _drafts.add(draft);
      } else {
        _drafts.insert(afterIndex + 1, draft);
      }
    });
    if (afterIndex == null) _scrollToBottom();
  }

  void _moveStep(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _drafts.length) return;
    setState(() {
      final draft = _drafts.removeAt(index);
      _drafts.insert(target, draft);
    });
  }

  void _duplicateStep(int index) {
    final copy = _drafts[index].toStep().copyWith(
      id: newTerminalMacroId('step'),
    );
    _addStep(copy, afterIndex: index);
  }

  void _removeStep(int index) {
    if (_drafts.length == 1) return;
    final messenger = ScaffoldMessenger.of(context);
    final snapshot = _drafts[index].toStep();
    setState(() => _drafts.removeAt(index).dispose());
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Step ${index + 1} removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => setState(
            () => _drafts.insert(
              index.clamp(0, _drafts.length),
              _StepDraft.fromStep(snapshot),
            ),
          ),
        ),
      ),
    );
  }

  void _handleStepAction(int index, _StepAction action) {
    switch (action) {
      case _StepAction.insertShell:
        _addStep(
          newTerminalMacroStep(TerminalMacroStepType.shell),
          afterIndex: index,
        );
      case _StepAction.insertKey:
        _addStep(
          newTerminalMacroStep(TerminalMacroStepType.terminalKey),
          afterIndex: index,
        );
      case _StepAction.insertTmux:
        _addStep(
          newTerminalMacroStep(TerminalMacroStepType.tmux),
          afterIndex: index,
        );
      case _StepAction.insertWait:
        _addStep(
          newTerminalMacroStep(TerminalMacroStepType.wait),
          afterIndex: index,
        );
      case _StepAction.insertDevice:
        _addStep(
          newTerminalMacroStep(TerminalMacroStepType.device),
          afterIndex: index,
        );
      case _StepAction.moveUp:
        _moveStep(index, -1);
      case _StepAction.moveDown:
        _moveStep(index, 1);
      case _StepAction.duplicate:
        _duplicateStep(index);
      case _StepAction.delete:
        _removeStep(index);
    }
  }

  Future<void> _openCommandEditor(_StepDraft draft, int index) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => MacroCommandEditorScreen(
          initialText: draft.valueController.text,
          stepLabel: 'Step ${index + 1}',
          savedCommands: widget.savedCommands,
        ),
      ),
    );
    if (result == null || !mounted) return;
    draft.valueController.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }

  void _save() {
    FocusManager.instance.primaryFocus?.unfocus();
    final steps = _drafts
        .map((draft) => draft.toStep())
        .where(
          (step) =>
              step.type != TerminalMacroStepType.shell ||
              step.value.trim().isNotEmpty,
        )
        .toList();
    if (steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one runnable step.')),
      );
      return;
    }
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      if (step.type != TerminalMacroStepType.device) continue;
      try {
        final decoded = jsonDecode(step.value);
        if (decoded is! Map ||
            (decoded['action']?.toString().trim().isEmpty ?? true)) {
          throw const FormatException('action is required');
        }
      } catch (error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Step ${index + 1} has invalid device JSON: $error'),
          ),
        );
        return;
      }
    }
    final name = _nameController.text.trim();
    final priority = int.tryParse(_priorityController.text.trim()) ?? 0;
    Navigator.of(context).pop(
      widget.macro.copyWith(
        name: name.isEmpty ? 'Macro' : name,
        priority: priority,
        steps: steps,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<TerminalMacro?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (!_isDirty) {
          navigator.pop();
          return;
        }
        final discard = await _confirmDiscard(
          context,
          'This macro has unsaved edits.',
        );
        if (discard && navigator.mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isNew ? 'New macro' : 'Edit macro'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Save'),
                onPressed: _save,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Macro name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _priorityController,
                decoration: const InputDecoration(
                  labelText: 'Priority',
                  helperText:
                      'Higher numbers appear first. Ties keep their saved order.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^-?\d*$')),
                ],
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 12),
              for (var index = 0; index < _drafts.length; index++)
                _buildStepCard(theme, index),
              const SizedBox(height: 4),
              _buildAddStepBar(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepCard(ThemeData theme, int index) {
    final draft = _drafts[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PopupMenuButton<TerminalMacroStepType>(
                    tooltip: 'Step type',
                    onSelected: (type) =>
                        setState(() => draft.changeType(type)),
                    itemBuilder: (ctx) => TerminalMacroStepType.values
                        .map(
                          (type) => PopupMenuItem(
                            value: type,
                            child: _MenuRow(
                              macroStepTypeIcon(type),
                              terminalMacroStepTypeLabel(type),
                            ),
                          ),
                        )
                        .toList(),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.colorScheme.outline),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(macroStepTypeIcon(draft.type), size: 16),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              terminalMacroStepTypeLabel(draft.type),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: draft.delayController,
                    decoration: const InputDecoration(
                      labelText: 'Delay',
                      suffixText: 's',
                      hintText: '0',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    scrollPadding: const EdgeInsets.symmetric(vertical: 140),
                  ),
                ),
                PopupMenuButton<_StepAction>(
                  tooltip: 'Step options',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) => _handleStepAction(index, action),
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: _StepAction.moveUp,
                      enabled: index > 0,
                      child: const _MenuRow(Icons.arrow_upward, 'Move up'),
                    ),
                    PopupMenuItem(
                      value: _StepAction.moveDown,
                      enabled: index < _drafts.length - 1,
                      child: const _MenuRow(Icons.arrow_downward, 'Move down'),
                    ),
                    PopupMenuItem(
                      value: _StepAction.duplicate,
                      child: const _MenuRow(Icons.copy, 'Duplicate'),
                    ),
                    PopupMenuItem(
                      value: _StepAction.delete,
                      enabled: _drafts.length > 1,
                      child: const _MenuRow(Icons.delete_outline, 'Delete'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      enabled: false,
                      height: 32,
                      child: Text(
                        'Insert below',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _StepAction.insertShell,
                      child: _MenuRow(Icons.terminal, 'Command'),
                    ),
                    const PopupMenuItem(
                      value: _StepAction.insertKey,
                      child: _MenuRow(Icons.keyboard, 'Key'),
                    ),
                    const PopupMenuItem(
                      value: _StepAction.insertTmux,
                      child: _MenuRow(Icons.tab, 'tmux'),
                    ),
                    const PopupMenuItem(
                      value: _StepAction.insertWait,
                      child: _MenuRow(Icons.timer_outlined, 'Wait'),
                    ),
                    const PopupMenuItem(
                      value: _StepAction.insertDevice,
                      child: _MenuRow(Icons.smartphone, 'Device action'),
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 8),
              child: _buildStepBody(theme, draft, index),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepBody(ThemeData theme, _StepDraft draft, int index) {
    switch (draft.type) {
      case TerminalMacroStepType.shell:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: draft.valueController,
              focusNode: draft.valueFocusNode,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              textCapitalization: TextCapitalization.none,
              // Keep a comfortable gap between the caret and the keyboard when
              // the framework scrolls this field into view.
              scrollPadding: const EdgeInsets.symmetric(vertical: 160),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
              ),
              decoration: const InputDecoration(
                labelText: 'Command',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.all(12),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: draft.valueController,
              builder: (context, value, _) {
                final text = value.text;
                final lines = '\n'.allMatches(text).length + 1;
                final long = text.length > 60 || lines > 1;
                return Row(
                  children: [
                    Flexible(
                      child: TextButton.icon(
                        icon: const Icon(Icons.open_in_full, size: 16),
                        label: const Text(
                          'Edit full screen',
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _openCommandEditor(draft, index),
                      ),
                    ),
                    const Spacer(),
                    if (text.isNotEmpty)
                      Flexible(
                        child: Text(
                          long
                              ? '${text.length} chars · $lines lines'
                              : '${text.length} chars',
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        );
      case TerminalMacroStepType.terminalKey:
        return _buildOptionDropdown(
          key: ValueKey('${draft.id}-key'),
          label: 'Terminal key',
          value: draft.optionValue,
          options: terminalMacroTerminalKeyOptions,
          onChanged: (value) => draft.optionValue = value,
        );
      case TerminalMacroStepType.tmux:
        return _buildOptionDropdown(
          key: ValueKey('${draft.id}-tmux'),
          label: 'tmux command',
          value: draft.optionValue,
          options: terminalMacroTmuxOptions,
          onChanged: (value) => draft.optionValue = value,
        );
      case TerminalMacroStepType.wait:
        return Row(
          children: [
            Icon(
              Icons.hourglass_bottom,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Pauses the macro for the delay set above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      case TerminalMacroStepType.device:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: draft.valueController,
              focusNode: draft.valueFocusNode,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'Device action JSON',
                helperText:
                    'Agent-compatible action, args, expectations, and capture policy.',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_full, size: 16),
                label: const Text('Edit JSON full screen'),
                onPressed: () => _openCommandEditor(draft, index),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildOptionDropdown({
    required Key key,
    required String label,
    required String value,
    required List<MacroStepOption> options,
    required ValueChanged<String> onChanged,
  }) {
    // Macros written by an agent over MCP can carry a value that is not in the
    // picker. Keep it selectable instead of silently rewriting it.
    final known = options.any((option) => option.value == value);
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      isDense: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        if (!known)
          DropdownMenuItem(value: value, child: Text('$value  (custom)')),
        ...options.map(
          (option) =>
              DropdownMenuItem(value: option.value, child: Text(option.label)),
        ),
      ],
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }

  Widget _buildAddStepBar(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Add step', style: theme.textTheme.labelMedium),
            OutlinedButton.icon(
              icon: const Icon(Icons.terminal),
              label: const Text('Command'),
              onPressed: () =>
                  _addStep(newTerminalMacroStep(TerminalMacroStepType.shell)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.keyboard),
              label: const Text('Key'),
              onPressed: () => _addStep(
                newTerminalMacroStep(TerminalMacroStepType.terminalKey),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.tab),
              label: const Text('tmux'),
              onPressed: () =>
                  _addStep(newTerminalMacroStep(TerminalMacroStepType.tmux)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.timer),
              label: const Text('Wait'),
              onPressed: () =>
                  _addStep(newTerminalMacroStep(TerminalMacroStepType.wait)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.smartphone),
              label: const Text('Device'),
              onPressed: () =>
                  _addStep(newTerminalMacroStep(TerminalMacroStepType.device)),
            ),
            if (widget.savedCommands.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Add saved command',
                onSelected: (command) => _addStep(
                  newTerminalMacroStep(TerminalMacroStepType.shell, command),
                ),
                itemBuilder: (ctx) => widget.savedCommands
                    .map(
                      (command) => PopupMenuItem(
                        value: command,
                        child: Text(
                          command,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                child: const Chip(
                  avatar: Icon(Icons.add),
                  label: Text('Saved'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

/// A whole page for one command.
///
/// The text area takes every pixel the keyboard leaves, so what is being typed
/// stays visible, and the clipboard controls sit directly above the keyboard so
/// copying or pasting never requires fighting selection handles in a two-line
/// box.
class MacroCommandEditorScreen extends StatefulWidget {
  const MacroCommandEditorScreen({
    super.key,
    required this.initialText,
    this.stepLabel = 'Command',
    this.savedCommands = const <String>[],
  });

  final String initialText;
  final String stepLabel;
  final List<String> savedCommands;

  @override
  State<MacroCommandEditorScreen> createState() =>
      _MacroCommandEditorScreenState();
}

class _MacroCommandEditorScreenState extends State<MacroCommandEditorScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  final FocusNode _focusNode = FocusNode();
  final UndoHistoryController _undoController = UndoHistoryController();

  @override
  void initState() {
    super.initState();
    // An empty step is here to be typed into. A step that already has text is
    // here to be read first, so let the tap decide where the caret lands.
    if (widget.initialText.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _undoController.dispose();
    super.dispose();
  }

  bool get _isDirty => _controller.text != widget.initialText;

  void _replaceAll(String text, {String? undoLabel}) {
    final previous = _controller.text;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (undoLabel == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(undoLabel),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _controller.value = TextEditingValue(
            text: previous,
            selection: TextSelection.collapsed(offset: previous.length),
          ),
        ),
      ),
    );
  }

  void _selectAll() {
    _focusNode.requestFocus();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Command copied')));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text;
    if (pasted == null || pasted.isEmpty || !mounted) return;
    final selection = _controller.selection;
    final text = _controller.text;
    if (!selection.isValid) {
      _replaceAll(text + pasted);
      return;
    }
    final next = text.replaceRange(selection.start, selection.end, pasted);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: selection.start + pasted.length,
      ),
    );
  }

  void _insertSaved(String command) {
    final selection = _controller.selection;
    final text = _controller.text;
    if (!selection.isValid) {
      _replaceAll(text.isEmpty ? command : '$text$command');
      return;
    }
    final next = text.replaceRange(selection.start, selection.end, command);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: selection.start + command.length,
      ),
    );
  }

  Future<void> _cancel() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await _confirmDiscard(
      context,
      'This command has unsaved edits.',
    );
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<String?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Discard',
            onPressed: _cancel,
          ),
          title: Text(widget.stepLabel),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Done'),
                onPressed: () =>
                    Navigator.of(context).pop(_controller.text.trimRight()),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    undoController: _undoController,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    autocorrect: false,
                    enableSuggestions: false,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    textCapitalization: TextCapitalization.none,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.4,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                      hintText: 'Command text sent to the terminal',
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) {
                    final lines = '\n'.allMatches(value.text).length + 1;
                    return Text(
                      '${value.text.length} chars · $lines line'
                      '${lines == 1 ? '' : 's'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                _buildToolbar(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          ValueListenableBuilder<UndoHistoryValue>(
            valueListenable: _undoController,
            builder: (context, value, _) => Row(
              children: [
                _ToolButton(
                  icon: Icons.undo,
                  label: 'Undo',
                  onPressed: value.canUndo ? _undoController.undo : null,
                ),
                _ToolButton(
                  icon: Icons.redo,
                  label: 'Redo',
                  onPressed: value.canRedo ? _undoController.redo : null,
                ),
              ],
            ),
          ),
          _ToolButton(
            icon: Icons.select_all,
            label: 'Select all',
            onPressed: _selectAll,
          ),
          _ToolButton(icon: Icons.copy_all, label: 'Copy', onPressed: _copyAll),
          _ToolButton(
            icon: Icons.content_paste,
            label: 'Paste',
            onPressed: _paste,
          ),
          _ToolButton(
            icon: Icons.backspace_outlined,
            label: 'Clear',
            onPressed: () => _replaceAll('', undoLabel: 'Command cleared'),
          ),
          if (widget.savedCommands.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Insert saved command',
              onSelected: _insertSaved,
              itemBuilder: (ctx) => widget.savedCommands
                  .map(
                    (command) => PopupMenuItem(
                      value: command,
                      child: Text(
                        command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Icon(Icons.playlist_add, size: 18),
                    const SizedBox(width: 6),
                    Text('Saved', style: theme.textTheme.labelLarge),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: TextButton.icon(
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onPressed,
      ),
    );
  }
}
