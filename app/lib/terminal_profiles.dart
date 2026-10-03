import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TerminalProfile {
  final String id;
  final String name;
  final String host;
  final String port;
  final String username;
  final bool usePrivateKey;
  final String? privateKeyName;
  final String serverUrl;
  final String agentUrl;
  final bool agentWholeDevice;

  const TerminalProfile({
    required this.id,
    required this.name,
    this.host = '',
    this.port = '22',
    this.username = '',
    this.usePrivateKey = false,
    this.privateKeyName,
    this.serverUrl = '',
    this.agentUrl = '',
    this.agentWholeDevice = false,
  });

  TerminalProfile copyWith({
    String? name,
    String? host,
    String? port,
    String? username,
    bool? usePrivateKey,
    String? privateKeyName,
    String? serverUrl,
    String? agentUrl,
    bool? agentWholeDevice,
  }) => TerminalProfile(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    usePrivateKey: usePrivateKey ?? this.usePrivateKey,
    privateKeyName: privateKeyName ?? this.privateKeyName,
    serverUrl: serverUrl ?? this.serverUrl,
    agentUrl: agentUrl ?? this.agentUrl,
    agentWholeDevice: agentWholeDevice ?? this.agentWholeDevice,
  );

  String secretKey(String field) => 'ssh_profile:id:$id:$field';

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'usePrivateKey': usePrivateKey,
    'privateKeyName': privateKeyName,
    'serverUrl': serverUrl,
    'agentUrl': agentUrl,
    'agentWholeDevice': agentWholeDevice,
  };

  factory TerminalProfile.fromJson(Map<String, dynamic> value) =>
      TerminalProfile(
        id: value['id'] as String,
        name: value['name'] as String,
        host: value['host'] as String,
        port: value['port'] as String,
        username: value['username'] as String,
        usePrivateKey: value['usePrivateKey'] as bool,
        privateKeyName: value['privateKeyName'] as String?,
        serverUrl: value['serverUrl'] as String? ?? '',
        agentUrl: value['agentUrl'] as String? ?? '',
        agentWholeDevice: value['agentWholeDevice'] as bool? ?? false,
      );
}

/// Metadata lives in preferences; passwords and keys stay in secure storage.
class TerminalProfiles {
  static const profilesKey = 'ssh_profiles_json';
  static const selectedKey = 'ssh_selected_profile_id';
  static const unifiedKey = 'computer_profiles_migrated';
  final List<TerminalProfile> profiles;
  String selectedId;
  Future<void> _writes = Future.value();

  TerminalProfiles(this.profiles, this.selectedId);

  TerminalProfile get selected =>
      profiles.firstWhere((p) => p.id == selectedId);

  static Future<TerminalProfiles> load(
    SharedPreferences prefs,
    FlutterSecureStorage storage,
  ) async {
    final saved = prefs.getString(profilesKey);
    if (saved != null) {
      final rows = jsonDecode(saved) as List;
      final profiles = rows
          .map(
            (row) =>
                TerminalProfile.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList();
      if (profiles.isEmpty ||
          profiles.map((p) => p.id).toSet().length != profiles.length) {
        throw const FormatException('Invalid saved terminal profiles');
      }
      final selected = prefs.getString(selectedKey);
      return TerminalProfiles(
        profiles,
        profiles.any((p) => p.id == selected) ? selected! : profiles.first.id,
      );
    }

    final existing = TerminalProfile(
      id: 'existing',
      name: 'Existing computer',
      host: prefs.getString('ssh_host') ?? '',
      port: prefs.getString('ssh_port') ?? '22',
      username: prefs.getString('ssh_username') ?? '',
      usePrivateKey: prefs.getBool('ssh_use_private_key') ?? false,
      privateKeyName: prefs.getString('ssh_private_key_name'),
    );
    final port = int.tryParse(existing.port) ?? 22;
    final prefix =
        'ssh_profile:${existing.host.isEmpty ? 'default' : existing.host}:$port';
    // Copy before committing metadata so an interrupted migration can retry.
    for (final field in ['password', 'passphrase', 'private_key']) {
      final value = await storage.read(key: '$prefix:$field');
      if (value != null) {
        await storage.write(key: existing.secretKey(field), value: value);
      }
    }
    final result = TerminalProfiles([existing], existing.id);
    await result.save(prefs, storage);
    return result;
  }

  /// Merge the legacy independent lists by computer host, preserving IDs and secrets.
  static Future<TerminalProfiles> loadComputers(
    SharedPreferences prefs,
    FlutterSecureStorage storage, {
    String defaultServerUrl = '',
  }) async {
    final result = await load(prefs, storage);
    if (prefs.getBool(unifiedKey) == true) return result;
    final servers = List<String>.from(prefs.getStringList('servers') ?? []);
    final activeServer = prefs.getString('active_server') ?? defaultServerUrl;
    if (activeServer.isNotEmpty && !servers.contains(activeServer)) {
      servers.insert(0, activeServer);
    }
    final savedAgents = prefs.getString('agent_profiles_json');
    final agents = savedAgents == null
        ? <Map<String, dynamic>>[
            {
              'id': 'existing',
              'name': 'Existing agent',
              'url': prefs.getString('agent_ws_url') ?? '',
              'token': prefs.getString('agent_pair_token') ?? '',
              'wholeDevice': prefs.getBool('agent_whole_device') ?? false,
            },
          ]
        : (jsonDecode(savedAgents) as List)
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList();
    String hostOf(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final usedAgents = <String>{};
    final usedServers = <String>{};
    for (var index = 0; index < result.profiles.length; index++) {
      final profile = result.profiles[index];
      final host = profile.host.toLowerCase();
      final agent = agents
          .where(
            (agent) =>
                !usedAgents.contains(agent['id']) &&
                ((host.isNotEmpty &&
                        hostOf(agent['url'] as String? ?? '') == host) ||
                    (host.isEmpty && agent['id'] == 'existing')),
          )
          .firstOrNull;
      final server =
          servers
              .where(
                (server) =>
                    hostOf(server) == host &&
                    Uri.tryParse(server)?.port != 8083,
              )
              .firstOrNull ??
          (host.isEmpty ? activeServer : '');
      if (server.isNotEmpty) usedServers.add(server);
      var agentUrl = agent?['url'] as String? ?? '';
      if (agentUrl.startsWith('http://')) {
        agentUrl = agentUrl.replaceFirst('http://', 'ws://');
      }
      if (agentUrl.startsWith('https://')) {
        agentUrl = agentUrl.replaceFirst('https://', 'wss://');
      }
      final migrated = profile.copyWith(
        serverUrl: server,
        agentUrl: agentUrl,
        agentWholeDevice: agent?['wholeDevice'] as bool? ?? false,
      );
      result.profiles[index] = migrated;
      if (agent != null) {
        usedAgents.add(agent['id'] as String);
        await storage.write(
          key: migrated.secretKey('agent_token'),
          value: agent['token'] as String? ?? '',
        );
      }
    }
    // Retain unmatched agents and servers as named computers rather than discarding data.
    for (final agent in agents.where(
      (agent) =>
          !usedAgents.contains(agent['id']) &&
          (agent['url'] as String? ?? '').isNotEmpty,
    )) {
      final url = agent['url'] as String;
      final host = hostOf(url);
      final server =
          servers
              .where(
                (server) =>
                    hostOf(server) == host &&
                    Uri.tryParse(server)?.port != 8083,
              )
              .firstOrNull ??
          '';
      final profile = TerminalProfile(
        id: 'agent:${agent['id']}',
        name: agent['name'] as String? ?? host,
        host: host,
        serverUrl: server,
        agentUrl: url.replaceFirst(RegExp('^http'), 'ws'),
        agentWholeDevice: agent['wholeDevice'] as bool? ?? false,
      );
      if (server.isNotEmpty) usedServers.add(server);
      result.profiles.add(profile);
      await storage.write(
        key: profile.secretKey('agent_token'),
        value: agent['token'] as String? ?? '',
      );
    }
    for (final server in servers.where(
      (server) => !usedServers.contains(server),
    )) {
      final host = hostOf(server);
      // Existing host aliases stay in the legacy server list; avoid turning an agent port into a build server.
      if (host.isEmpty ||
          Uri.tryParse(server)?.port == 8083 ||
          result.profiles.any((p) => p.host.toLowerCase() == host)) {
        continue;
      }
      result.profiles.add(
        TerminalProfile(
          id: 'server:${Uri.encodeComponent(server)}',
          name: host,
          host: host,
          serverUrl: server,
        ),
      );
    }
    await result.save(prefs, storage);
    await prefs.setBool(unifiedKey, true);
    return result;
  }

  void updateSelected(TerminalProfile profile) {
    assert(profile.id == selectedId);
    updateProfile(profile);
  }

  void updateProfile(TerminalProfile profile) {
    profiles[profiles.indexWhere((p) => p.id == profile.id)] = profile;
  }

  Future<void> save(
    SharedPreferences prefs,
    FlutterSecureStorage storage, {
    String? password,
    String? passphrase,
    String? credentialProfileId,
  }) {
    final encoded = jsonEncode(profiles.map((p) => p.toJson()).toList());
    final active = selected;
    final credentials = credentialProfileId == null
        ? active
        : profiles.firstWhere((p) => p.id == credentialProfileId);
    final write = _writes.then((_) async {
      if (password != null) {
        await storage.write(
          key: credentials.secretKey('password'),
          value: password,
        );
      }
      if (passphrase != null) {
        await storage.write(
          key: credentials.secretKey('passphrase'),
          value: passphrase,
        );
      }
      await prefs.setString(profilesKey, encoded);
      await prefs.setString(selectedKey, active.id);
      if (active.serverUrl.isNotEmpty) {
        final servers = List<String>.from(prefs.getStringList('servers') ?? []);
        if (!servers.contains(active.serverUrl)) servers.add(active.serverUrl);
        await prefs.setStringList('servers', servers);
        await prefs.setString('active_server', active.serverUrl);
      } else if (prefs.getBool(unifiedKey) == true) {
        await prefs.setString('active_server', '');
      }
      if (prefs.getBool(unifiedKey) == true) {
        await prefs.setString('agent_ws_url', active.agentUrl);
        await prefs.setString(
          'agent_pair_token',
          await storage.read(key: active.secretKey('agent_token')) ?? '',
        );
        await prefs.setBool('agent_whole_device', active.agentWholeDevice);
      }
      await prefs.setString('ssh_host', active.host);
      await prefs.setString('ssh_port', active.port);
      await prefs.setString('ssh_username', active.username);
      await prefs.setBool('ssh_use_private_key', active.usePrivateKey);
      if (active.privateKeyName == null) {
        await prefs.remove('ssh_private_key_name');
      } else {
        await prefs.setString('ssh_private_key_name', active.privateKeyName!);
      }
    });
    _writes = write.catchError((Object error) {});
    return write;
  }
}
