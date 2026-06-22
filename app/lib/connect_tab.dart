import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NetworkHelper {
  const NetworkHelper({
    required this.label,
    required this.packageName,
    required this.description,
    required this.icon,
  });

  final String label;
  final String packageName;
  final String description;
  final IconData icon;
}

class ConnectTab extends StatefulWidget {
  const ConnectTab({
    super.key,
    required this.channel,
    required this.servers,
    required this.activeServer,
    required this.onServerSelected,
  });

  final MethodChannel channel;
  final List<String> servers;
  final String activeServer;
  final ValueChanged<String> onServerSelected;

  @override
  State<ConnectTab> createState() => _ConnectTabState();
}

class _ConnectTabState extends State<ConnectTab> {
  static const helpers = [
    NetworkHelper(
      label: 'ZeroTier',
      packageName: 'com.zerotier.one',
      description: 'Mesh VPN for remote phone-to-computer development.',
      icon: Icons.hub,
    ),
    NetworkHelper(
      label: 'Tailscale',
      packageName: 'com.tailscale.ipn',
      description: 'WireGuard-based mesh VPN with identity-managed devices.',
      icon: Icons.security,
    ),
    NetworkHelper(
      label: 'WireGuard',
      packageName: 'com.wireguard.android',
      description: 'Official WireGuard tunnel manager.',
      icon: Icons.vpn_lock,
    ),
  ];

  final Map<String, bool> _installed = {};
  List<Map<String, dynamic>> _discovered = [];
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _refreshHelpers();
  }

  Future<void> _refreshHelpers() async {
    for (final helper in helpers) {
      try {
        final installed = await widget.channel.invokeMethod<bool>(
          'isPackageInstalled',
          {'packageName': helper.packageName},
        );
        if (mounted) {
          setState(() => _installed[helper.packageName] = installed == true);
        }
      } catch (_) {
        if (mounted) {
          setState(() => _installed[helper.packageName] = false);
        }
      }
    }
  }

  Future<void> _openHelper(NetworkHelper helper) async {
    final installed = _installed[helper.packageName] == true;
    final method = installed ? 'openPackage' : 'openAppStore';
    await widget.channel.invokeMethod(method, {
      'packageName': helper.packageName,
    });
    await Future.delayed(const Duration(milliseconds: 500));
    _refreshHelpers();
  }

  Future<void> _discover() async {
    setState(() {
      _busy = true;
      _status = 'Scanning LAN for DevOTA servers...';
    });
    try {
      final raw = await widget.channel.invokeListMethod<dynamic>(
        'discoverDevotaServers',
        {'timeoutMs': 4500},
      );
      final servers = (raw ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      setState(() {
        _discovered = servers;
        _status = servers.isEmpty
            ? 'No LAN servers found.'
            : 'Found ${servers.length} server(s).';
      });
    } catch (e) {
      setState(() => _status = 'Discovery failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Server discovery', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.activeServer,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.radar),
                      label: const Text('Scan'),
                      onPressed: _busy ? null : _discover,
                    ),
                  ],
                ),
                if (_status != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _status!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                for (final server in _discovered)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(server['name']?.toString() ?? 'DevOTA'),
                    subtitle: Text(server['url']?.toString() ?? ''),
                    trailing: TextButton(
                      onPressed: () {
                        final url = server['url']?.toString();
                        if (url != null && url.isNotEmpty) {
                          widget.onServerSelected(url);
                        }
                      },
                      child: const Text('Use'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Network helpers', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final helper in helpers)
          Card(
            child: ListTile(
              leading: Icon(helper.icon),
              title: Text(helper.label),
              subtitle: Text(helper.description),
              trailing: FilledButton.tonal(
                onPressed: () => _openHelper(helper),
                child: Text(
                  _installed[helper.packageName] == true ? 'Open' : 'Install',
                ),
              ),
            ),
          ),
      ],
    );
  }
}
