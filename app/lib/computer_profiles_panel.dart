import 'package:flutter/material.dart';
import 'terminal_profiles.dart';

class ComputerProfilesPanel extends StatelessWidget {
  const ComputerProfilesPanel({
    super.key,
    required this.profiles,
    required this.onSelect,
    required this.onSave,
    this.busy = false,
  });
  final TerminalProfiles profiles;
  final Future<void> Function(String) onSelect;
  final Future<void> Function(TerminalProfile, bool) onSave;
  final bool busy;

  Future<void> _edit(BuildContext context, {bool create = false}) async {
    final current = profiles.selected;
    final name = TextEditingController(text: create ? '' : current.name);
    final server = TextEditingController(text: create ? '' : current.serverUrl);
    final host = TextEditingController(text: create ? '' : current.host);
    final user = TextEditingController(text: current.username);
    final result = await showDialog<TerminalProfile>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(create ? 'New computer' : 'Edit computer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Computer name'),
              ),
              TextField(
                controller: server,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Build server URL',
                  hintText: 'http://computer-ip:8082',
                ),
              ),
              if (create) ...[
                TextField(
                  controller: host,
                  decoration: const InputDecoration(labelText: 'SSH host'),
                ),
                TextField(
                  controller: user,
                  decoration: const InputDecoration(labelText: 'SSH user'),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'SSH credentials are configured in Terminal. Agent settings are configured in Agent. Both belong to this computer.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              final url = server.text.trim().replaceAll(RegExp(r'/+$'), '');
              final parsed = Uri.tryParse(url);
              if (url.isNotEmpty &&
                  (parsed == null ||
                      !['http', 'https'].contains(parsed.scheme) ||
                      parsed.host.isEmpty)) {
                return;
              }
              Navigator.pop(
                ctx,
                create
                    ? TerminalProfile(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        name: name.text.trim(),
                        serverUrl: url,
                        host: host.text.trim().isEmpty
                            ? parsed?.host ?? ''
                            : host.text.trim(),
                        username: user.text.trim(),
                      )
                    : current.copyWith(name: name.text.trim(), serverUrl: url),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    server.dispose();
    host.dispose();
    user.dispose();
    if (result != null) await onSave(result, create);
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Computers', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('computer:${profiles.selectedId}'),
            initialValue: profiles.selectedId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Computer profile',
              border: OutlineInputBorder(),
            ),
            items: profiles.profiles
                .map(
                  (profile) => DropdownMenuItem(
                    value: profile.id,
                    child: Text(profile.name, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (id) {
                    if (id != null) onSelect(id);
                  },
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: busy ? null : () => _edit(context, create: true),
                icon: const Icon(Icons.add),
                label: const Text('New computer'),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => _edit(context),
                icon: const Icon(Icons.edit),
                label: const Text('Edit computer'),
              ),
            ],
          ),
          const Text(
            'Selecting a computer updates Builds, Terminal and Agent together. Open terminal sessions remain connected.',
          ),
          const SizedBox(height: 8),
          Text(
            profiles.selected.serverUrl.isEmpty
                ? 'Build server not configured'
                : profiles.selected.serverUrl,
          ),
        ],
      ),
    ),
  );
}
