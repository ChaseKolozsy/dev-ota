import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_input_service.dart';

class BackupTab extends StatefulWidget {
  const BackupTab({super.key, required this.onImported});

  final Future<void> Function() onImported;

  @override
  State<BackupTab> createState() => _BackupTabState();
}

class _BackupTabState extends State<BackupTab> {
  static const _stringListPreferenceKeys = ['commands', 'issues', 'servers'];
  static const _stringPreferenceKeys = [
    'active_server',
    'agent_ws_url',
    'agent_pair_token',
    'ssh_host',
    'ssh_port',
    'ssh_username',
    'ssh_private_key_name',
    'github_repo',
    'github_workflow',
    'github_ref',
    'github_artifact',
  ];
  static const _boolPreferenceKeys = [
    'agent_whole_device',
    'ssh_use_private_key',
  ];

  final _storage = const FlutterSecureStorage();

  bool _includeSecrets = true;
  bool _busy = false;
  String? _status;

  bool _isExportableSecret(String key) {
    return key == VoiceInputService.apiKeyStorageKey ||
        key.startsWith('ssh_profile:') ||
        key.startsWith('ssh_terminal_generated_');
  }

  Future<Map<String, dynamic>> _buildBackup() async {
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
    if (_includeSecrets) {
      final values = await _storage.readAll();
      for (final entry in values.entries) {
        if (_isExportableSecret(entry.key)) {
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

  String _prettyJson(Map<String, dynamic> value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  Future<void> _copyBackup() async {
    await _run('Export copied.', () async {
      final backup = await _buildBackup();
      await Clipboard.setData(ClipboardData(text: _prettyJson(backup)));
    });
  }

  Future<void> _saveBackupFile() async {
    await _run('Backup file saved.', () async {
      final backup = await _buildBackup();
      final bytes = Uint8List.fromList(utf8.encode(_prettyJson(backup)));
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final path = await FilePicker.saveFile(
        fileName: 'devota-backup-$timestamp.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (path == null) {
        throw StateError('Save cancelled.');
      }
    });
  }

  Future<void> _importFromClipboard() async {
    await _run('Backup imported from clipboard.', () async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      await _importBackupText(data?.text ?? '');
    });
  }

  Future<void> _importFromFile() async {
    await _run('Backup imported from file.', () async {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      final file = picked?.files.isNotEmpty == true
          ? picked!.files.first
          : null;
      final bytes = file?.bytes;
      if (file == null || bytes == null) {
        throw StateError('Import cancelled.');
      }
      await _importBackupText(utf8.decode(bytes));
    });
  }

  Future<void> _importBackupText(String text) async {
    final decoded = json.decode(text);
    if (decoded is! Map) {
      throw const FormatException('Backup must be a JSON object.');
    }
    final backup = Map<String, dynamic>.from(decoded);
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

    if (_includeSecrets) {
      final secure = backup['secureStorage'];
      if (secure is Map) {
        for (final entry in secure.entries) {
          final key = entry.key.toString();
          final value = entry.value;
          if (value is String && _isExportableSecret(key)) {
            await _storage.write(key: key, value: value);
          }
        }
      }
    }

    await widget.onImported();
  }

  Future<void> _run(String success, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
      if (mounted) setState(() => _status = success);
    } catch (e) {
      if (mounted) setState(() => _status = e.toString());
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
        SwitchListTile(
          value: _includeSecrets,
          onChanged: _busy ? null : (v) => setState(() => _includeSecrets = v),
          title: const Text('Include secrets'),
          subtitle: const Text(
            'API keys, SSH private keys, passwords, and passphrases',
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy Export'),
              onPressed: _busy ? null : _copyBackup,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.save_alt),
              label: const Text('Save File'),
              onPressed: _busy ? null : _saveBackupFile,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.content_paste),
              label: const Text('Import Clipboard'),
              onPressed: _busy ? null : _importFromClipboard,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Import File'),
              onPressed: _busy ? null : _importFromFile,
            ),
          ],
        ),
        if (_status != null) ...[
          const SizedBox(height: 12),
          Text(
            _status!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }
}
