import 'dart:async';
import 'package:flutter/material.dart';
import 'terminal_watch.dart';
import 'terminal_macro.dart';

class TerminalWatchScreen extends StatefulWidget {
  const TerminalWatchScreen({
    super.key,
    required this.watch,
    required this.loadPanes,
    required this.macros,
    required this.onSave,
  });
  final TerminalWatchController watch;
  final Future<List<WatchedPane>> Function() loadPanes;
  final List<TerminalMacro> macros;
  final Future<void> Function(List<TerminalWatchBinding>, int, bool) onSave;
  @override
  State<TerminalWatchScreen> createState() => _TerminalWatchScreenState();
}

class _TerminalWatchScreenState extends State<TerminalWatchScreen> {
  late final selections = <String, String>{
    for (final b in widget.watch.bindings) b.pane.id: b.macroId,
  };
  late int quiet = widget.watch.quietPeriod.inSeconds;
  late bool review = widget.watch.reviewEnabled;
  String? error;
  String? loadError;
  List<WatchedPane>? panes;
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final result = await widget.loadPanes().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted) return;
      setState(() => panes = result);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => loadError = e is TimeoutException
            ? 'SSH window discovery timed out. Check the connection and retry.'
            : '$e',
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notification macros')),
    body: loading || loadError != null
        ? ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (loading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
                const Text('Finding tmux windows over SSH…'),
              ] else ...[
                Text(
                  'Could not load terminal windows',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                SelectableText(loadError!),
                const SizedBox(height: 12),
                const Text(
                  'The interactive terminal and notification controls use separate SSH channels. '
                  'Notification controls need tmux on the SSH host, under the '
                  'same user and tmux server as your terminal windows. '
                  'A Windows shell, another SSH hop, or a custom tmux socket '
                  'can make those windows unavailable to this connection.',
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('Retry')),
              ],
            ],
          )
        : _controls(context),
  );

  Widget _controls(BuildContext context) => ListView(
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
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Check conclusions with the home model'),
        subtitle: const Text(
          'Reported success, needs attention, or uncertain. '
          'Checks the final message, not the underlying work. Listen uses Android speech.',
        ),
        value: review,
        onChanged: (value) => setState(() => review = value),
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
      if (panes!.isEmpty) ...[
        const Text(
          'No tmux panes found. Start a tmux session on this SSH host, then retry.',
        ),
        TextButton(onPressed: _load, child: const Text('Retry')),
      ],
      if (widget.macros.isEmpty)
        const Text(
          'No saved terminal macros. Create a terminal macro in the Macros tab, then reopen this screen.',
        ),
      for (final pane in panes!)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DropdownButtonFormField<String>(
            key: ValueKey(pane.id),
            initialValue: widget.macros.any((m) => m.id == selections[pane.id])
                ? selections[pane.id]
                : '',
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Window ${pane.label} (${pane.id})',
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('No notification')),
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
                final selected = panes!
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
                    review,
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
  );
}
