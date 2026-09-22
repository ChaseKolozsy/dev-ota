import 'package:flutter/material.dart';
import 'terminal_watch.dart';
import 'terminal_macro.dart';

class TerminalWatchScreen extends StatefulWidget {
  const TerminalWatchScreen({
    super.key,
    required this.watch,
    required this.panes,
    required this.macros,
    required this.onSave,
  });
  final TerminalWatchController watch;
  final List<WatchedPane> panes;
  final List<TerminalMacro> macros;
  final Future<void> Function(List<TerminalWatchBinding>, int) onSave;
  @override
  State<TerminalWatchScreen> createState() => _TerminalWatchScreenState();
}

class _TerminalWatchScreenState extends State<TerminalWatchScreen> {
  late final selections = <String, String>{
    for (final b in widget.watch.bindings) b.pane.id: b.macroId,
  };
  late int quiet = widget.watch.quietPeriod.inSeconds;
  String? error;
  bool saving = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notification macros')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Choose up to three terminal windows. Each gets its own status, '
          'macro button and Send Enter recovery button in the notification shade. '
          'Keep the SSH session connected in the background.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Settled means the pane content stopped changing, not that an '
          'agent finished. Submission remains unconfirmed without an agent signal.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Use Command, Key and Wait steps. A tmux step selecting the '
          'same window is supported; other window-switching steps and Ctrl-B are not.',
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: quiet,
          decoration: const InputDecoration(labelText: 'Quiet period'),
          items: [5, 10, 15, 30]
              .map((n) => DropdownMenuItem(value: n, child: Text('$n seconds')))
              .toList(),
          onChanged: (value) => setState(() => quiet = value ?? 10),
        ),
        const SizedBox(height: 16),
        if (widget.panes.isEmpty)
          const Text('No tmux panes found. Start a tmux session first.'),
        for (final pane in widget.panes)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: DropdownButtonFormField<String>(
              key: ValueKey(pane.id),
              initialValue:
                  widget.macros.any((m) => m.id == selections[pane.id])
                  ? selections[pane.id]
                  : '',
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Window ${pane.label} (${pane.id})',
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('No notification'),
                ),
                ...widget.macros.map(
                  (m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (value) => setState(() {
                if (value == null || value.isEmpty) {
                  selections.remove(pane.id);
                } else {
                  selections[pane.id] = value;
                }
              }),
            ),
          ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        FilledButton(
          onPressed: saving
              ? null
              : () async {
                  final selected = widget.panes
                      .where((p) => selections.containsKey(p.id))
                      .toList();
                  if (selected.length > 3) {
                    setState(() => error = 'Choose at most three panes.');
                    return;
                  }
                  setState(() {
                    saving = true;
                    error = null;
                  });
                  try {
                    await widget.onSave(
                      selected
                          .map(
                            (p) => TerminalWatchBinding(
                              pane: p,
                              macroId: selections[p.id]!,
                            ),
                          )
                          .toList(),
                      quiet,
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        error = '$e';
                        saving = false;
                      });
                    }
                  }
                },
          child: const Text('Save notification controls'),
        ),
      ],
    ),
  );
}
