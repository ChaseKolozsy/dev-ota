import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backup_service.dart';

class BackupTab extends StatefulWidget {
  const BackupTab({
    super.key,
    required this.dio,
    required this.serverUrl,
    required this.onImported,
  });

  final Dio dio;
  final String serverUrl;
  final Future<void> Function() onImported;

  @override
  State<BackupTab> createState() => _BackupTabState();
}

class _BackupTabState extends State<BackupTab> {
  bool _includeSecrets = true;
  bool _busy = false;
  String? _status;

  Future<void> _copyBackup() async {
    await _run('Export copied.', () async {
      final backup = await BackupService.buildBackup(
        includeSecrets: _includeSecrets,
      );
      await Clipboard.setData(
        ClipboardData(text: BackupService.prettyJson(backup)),
      );
    });
  }

  Future<void> _saveBackupFile() async {
    await _run('Backup file saved.', () async {
      final backup = await BackupService.buildBackup(
        includeSecrets: _includeSecrets,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(BackupService.prettyJson(backup)),
      );
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

  Future<void> _saveBackupToServer() async {
    await _run('Backup saved to server.', () async {
      final ok = await BackupService.saveToServer(
        widget.dio,
        widget.serverUrl,
        includeSecrets: _includeSecrets,
      );
      if (!ok) throw StateError('Server did not accept backup.');
    });
  }

  Future<void> _restoreBackupFromServer() async {
    await _run('Backup restored from server.', () async {
      final ok = await BackupService.restoreFromServer(
        widget.dio,
        widget.serverUrl,
        includeSecrets: _includeSecrets,
      );
      if (!ok) throw StateError('No server backup found.');
      await widget.onImported();
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
    await BackupService.importBackupText(text, includeSecrets: _includeSecrets);
    await widget.onImported();
    try {
      await BackupService.saveToServer(
        widget.dio,
        widget.serverUrl,
        includeSecrets: _includeSecrets,
      );
    } catch (_) {
      // Manual import still succeeds when the server is unavailable.
    }
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
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Save Server'),
              onPressed: _busy ? null : _saveBackupToServer,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.cloud_download),
              label: const Text('Restore Server'),
              onPressed: _busy ? null : _restoreBackupFromServer,
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
