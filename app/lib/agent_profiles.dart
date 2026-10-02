import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AgentProfile {
  final String id;
  final String name;
  final String url;
  final String token;
  final bool wholeDevice;

  const AgentProfile({
    required this.id,
    required this.name,
    this.url = '',
    this.token = '',
    this.wholeDevice = false,
  });

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'token': token,
    'wholeDevice': wholeDevice,
  };

  factory AgentProfile.fromJson(Map<String, dynamic> value) => AgentProfile(
    id: value['id'] as String,
    name: value['name'] as String,
    url: value['url'] as String,
    token: value['token'] as String,
    wholeDevice: value['wholeDevice'] as bool,
  );
}

/// Keeps the legacy selected-agent keys for backups and older app versions.
class AgentProfiles {
  static const profilesKey = 'agent_profiles_json';
  static const selectedKey = 'agent_selected_profile_id';
  final List<AgentProfile> profiles;
  String selectedId;
  Future<void> _writes = Future.value();

  AgentProfiles(this.profiles, this.selectedId);

  AgentProfile get selected => profiles.firstWhere((p) => p.id == selectedId);

  static Future<AgentProfiles> load(SharedPreferences prefs) async {
    final saved = prefs.getString(profilesKey);
    if (saved != null) {
      final rows = jsonDecode(saved) as List;
      final profiles = rows
          .map(
            (row) =>
                AgentProfile.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList();
      if (profiles.isEmpty ||
          profiles.map((p) => p.id).toSet().length != profiles.length) {
        throw const FormatException('Invalid saved agent profiles');
      }
      final selected = prefs.getString(selectedKey);
      return AgentProfiles(
        profiles,
        profiles.any((p) => p.id == selected) ? selected! : profiles.first.id,
      );
    }
    final existing = AgentProfile(
      id: 'existing',
      name: 'Existing agent',
      url: prefs.getString('agent_ws_url') ?? '',
      token: prefs.getString('agent_pair_token') ?? '',
      wholeDevice: prefs.getBool('agent_whole_device') ?? false,
    );
    final result = AgentProfiles([existing], existing.id);
    await result.save(prefs);
    return result;
  }

  void updateSelected({
    required String url,
    required String token,
    required bool wholeDevice,
    String? name,
  }) {
    final index = profiles.indexWhere((p) => p.id == selectedId);
    profiles[index] = AgentProfile(
      id: selectedId,
      name: name ?? profiles[index].name,
      url: url,
      token: token,
      wholeDevice: wholeDevice,
    );
  }

  Future<void> save(SharedPreferences prefs) {
    final encoded = jsonEncode(profiles.map((p) => p.toJson()).toList());
    final active = selected;
    final write = _writes.then((_) async {
      await prefs.setString(profilesKey, encoded);
      await prefs.setString(selectedKey, active.id);
      await prefs.setString('agent_ws_url', active.url);
      await prefs.setString('agent_pair_token', active.token);
      await prefs.setBool('agent_whole_device', active.wholeDevice);
    });
    _writes = write.catchError((Object error) {});
    return write;
  }
}
