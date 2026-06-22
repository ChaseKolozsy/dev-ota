import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_input_service.dart';

class BackupService {
  static const _stringListPreferenceKeys = ['commands', 'issues', 'servers'];
  static const _stringPreferenceKeys = [
    'active_server',
    'agent_ws_url',
    'agent_pair_token',
    'ssh_host',
    'ssh_port',
    'ssh_username',
    'ssh_private_key_name',
    'command_usage_counts_json',
    'github_repo',
    'github_workflow',
    'github_ref',
    'github_artifact',
  ];
  static const _boolPreferenceKeys = [
    'agent_whole_device',
    'ssh_use_private_key',
  ];
  static const _serverPath = '/backup/profile';

  static final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static bool isExportableSecret(String key) {
    return key == VoiceInputService.apiKeyStorageKey ||
        key.startsWith('ssh_profile:') ||
        key.startsWith('ssh_terminal_generated_');
  }

  static Future<Map<String, dynamic>> buildBackup({
    bool includeSecrets = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final shared = <String, Object?>{};

    for (final key in _stringListPreferenceKeys) {
      final value = prefs.getStringList(key);
      if (value != null) shared[key] = value;
    }
    for (final key in _stringPreferenceKeys) {
      final value = prefs.getString(key);
      if (value != null) shared[key] = value;
    }
    for (final key in _boolPreferenceKeys) {
      final value = prefs.getBool(key);
      if (value != null) shared[key] = value;
    }

    final secure = <String, String>{};
    if (includeSecrets) {
      final values = await _storage.readAll();
      for (final entry in values.entries) {
        if (isExportableSecret(entry.key)) {
          secure[entry.key] = entry.value;
        }
      }
    }

    return {
      'format': 'devota-backup',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'sharedPreferences': shared,
      'secureStorage': secure,
    };
  }

  static Future<void> importBackup(
    Map<String, dynamic> backup, {
    bool includeSecrets = true,
  }) async {
    if (backup['format'] != 'devota-backup') {
      throw const FormatException('Not a DevOTA backup.');
    }

    final prefs = await SharedPreferences.getInstance();
    final shared = backup['sharedPreferences'];
    if (shared is Map) {
      for (final entry in shared.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (_stringListPreferenceKeys.contains(key) && value is List) {
          await prefs.setStringList(
            key,
            value.map((item) => item.toString()).toList(),
          );
        } else if (_stringPreferenceKeys.contains(key) && value != null) {
          await prefs.setString(key, value.toString());
        } else if (_boolPreferenceKeys.contains(key) && value is bool) {
          await prefs.setBool(key, value);
        }
      }
    }

    if (includeSecrets) {
      final secure = backup['secureStorage'];
      if (secure is Map) {
        for (final entry in secure.entries) {
          final key = entry.key.toString();
          final value = entry.value;
          if (value is String && isExportableSecret(key)) {
            await _storage.write(key: key, value: value);
          }
        }
      }
    }
  }

  static Future<void> importBackupText(
    String text, {
    bool includeSecrets = true,
  }) async {
    final decoded = json.decode(text);
    if (decoded is! Map) {
      throw const FormatException('Backup must be a JSON object.');
    }
    await importBackup(
      Map<String, dynamic>.from(decoded),
      includeSecrets: includeSecrets,
    );
  }

  static String prettyJson(Map<String, dynamic> value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  static String _baseUrl(String serverUrl) {
    return serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
  }

  static Future<bool> saveToServer(
    Dio dio,
    String serverUrl, {
    bool includeSecrets = true,
  }) async {
    final base = _baseUrl(serverUrl);
    if (base.isEmpty) return false;
    final backup = await buildBackup(includeSecrets: includeSecrets);
    final resp = await dio.post(
      '$base$_serverPath',
      data: backup,
      options: Options(
        headers: {'Content-Type': 'application/json'},
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    return resp.statusCode == 200;
  }

  static Future<bool> restoreFromServer(
    Dio dio,
    String serverUrl, {
    bool includeSecrets = true,
  }) async {
    final base = _baseUrl(serverUrl);
    if (base.isEmpty) return false;
    try {
      final resp = await dio.get(
        '$base$_serverPath',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return false;
      await importBackup(
        Map<String, dynamic>.from(resp.data as Map),
        includeSecrets: includeSecrets,
      );
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return false;
      rethrow;
    }
  }

  static Future<bool> hasLocalRestorableData() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _stringListPreferenceKeys) {
      final value = prefs.getStringList(key);
      if (key != 'servers' && value != null && value.isNotEmpty) return true;
    }
    for (final key in _stringPreferenceKeys) {
      if (key == 'active_server') continue;
      final value = prefs.getString(key);
      if (value != null && value.trim().isNotEmpty) return true;
    }
    for (final key in _boolPreferenceKeys) {
      if (prefs.getBool(key) != null) return true;
    }
    final secure = await _storage.readAll();
    return secure.keys.any(isExportableSecret);
  }
}
