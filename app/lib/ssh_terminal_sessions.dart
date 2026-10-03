import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ssh_terminal_tab.dart';
import 'terminal_profiles.dart';

/// Each visited profile owns a retained terminal widget and its SSH transport.
class SshTerminalSessions extends StatefulWidget {
  const SshTerminalSessions({super.key, required this.terminal});
  final SshTerminalTab terminal;

  @override
  State<SshTerminalSessions> createState() => _SshTerminalSessionsState();
}

class _SshTerminalSessionsState extends State<SshTerminalSessions>
    with AutomaticKeepAliveClientMixin {
  TerminalProfiles? _profiles;
  final _opened = <String>[];
  final _connected = <String, bool>{};
  String? _error;
  bool _switching = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles =
          widget.terminal.profiles ??
          await TerminalProfiles.load(
            await SharedPreferences.getInstance(),
            const FlutterSecureStorage(),
          );
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _opened.add(profiles.selectedId);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not load terminal profiles: $error');
      }
    }
  }

  @override
  void didUpdateWidget(covariant SshTerminalSessions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.terminal.profiles != null) {
      _profiles = widget.terminal.profiles;
      _opened.removeWhere(
        (id) => !_profiles!.profiles.any((profile) => profile.id == id),
      );
      if (!_opened.contains(_profiles!.selectedId)) {
        _opened.add(_profiles!.selectedId);
      }
    }
  }

  Future<void> _select(String id, TerminalProfile? create) async {
    if (_switching) return;
    if (widget.terminal.onSelectProfile != null) {
      await widget.terminal.onSelectProfile!(id, create);
      if (mounted) {
        setState(() {
          if (!_opened.contains(id)) _opened.add(id);
        });
      }
      return;
    }
    setState(() => _switching = true);
    final profiles = _profiles!;
    final previous = profiles.selectedId;
    final wasOpened = _opened.contains(id);
    try {
      if (create != null) profiles.profiles.add(create);
      profiles.selectedId = id;
      if (!wasOpened) _opened.add(id);
      await profiles.save(
        await SharedPreferences.getInstance(),
        const FlutterSecureStorage(),
      );
      if (!mounted) return;
      setState(() {});
    } catch (error) {
      profiles.selectedId = previous;
      if (!wasOpened) _opened.remove(id);
      if (create != null) profiles.profiles.remove(create);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Session switch failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _connectionChanged(String id, bool connected) {
    if (!mounted || _connected[id] == connected) return;
    // A child can report status while its initial widget is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _connected[id] = connected);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final profiles = _profiles;
    if (profiles == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Text(_error!),
      );
    }
    final template = widget.terminal;
    return IndexedStack(
      index: _opened.indexOf(profiles.selectedId),
      children: _opened.map((id) {
        final active = id == profiles.selectedId;
        return SshTerminalTab(
          key: ValueKey('terminal:$id'),
          profileId: id,
          profiles: profiles,
          active: active,
          sessionSelector: _buildSessionSelector(profiles, id),
          onSelectProfile: _select,
          onProfilesChanged: () {
            if (mounted) setState(() {});
          },
          onConnectionChanged: (connected) => _connectionChanged(id, connected),
          dio: template.dio,
          serverUrl:
              profiles.profiles
                  .firstWhere((profile) => profile.id == id)
                  .serverUrl
                  .isNotEmpty
              ? profiles.profiles
                    .firstWhere((profile) => profile.id == id)
                    .serverUrl
              : template.serverUrl,
          quickCommands: template.quickCommands,
          quickMacros: template.quickMacros,
          notificationMacros: template.notificationMacros,
          macroController: active ? template.macroController : null,
          fullscreen: template.fullscreen,
          onFullscreenChanged: template.onFullscreenChanged,
          onCommandUsed: template.onCommandUsed,
          onMacroUsed: template.onMacroUsed,
          onMacroReorder: template.onMacroReorder,
          onZeroTierRecovery: template.onZeroTierRecovery,
          // Forward the test transport to each retained terminal.
          // ignore: invalid_use_of_visible_for_testing_member
          testHooks: template.testHooks,
        );
      }).toList(),
    );
  }

  Widget _buildSessionSelector(TerminalProfiles profiles, String id) {
    return SizedBox(
      height: 30,
      width: 200,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey('session:$id'),
          value: id,
          isDense: true,
          isExpanded: true,
          iconSize: 16,
          style: Theme.of(context).textTheme.labelSmall,
          items: profiles.profiles
              .map(
                (profile) => DropdownMenuItem(
                  value: profile.id,
                  child: Text(
                    '${profile.name}${_connected[profile.id] == true ? ' · connected' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged:
              _switching || widget.terminal.macroController?.isRunning == true
              ? null
              : (value) {
                  if (value != null && value != profiles.selectedId) {
                    _select(value, null);
                  }
                },
        ),
      ),
    );
  }
}
