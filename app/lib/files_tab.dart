import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Lists files an agent has staged in the DevOTA build server's file-transfer
/// directory and downloads them into the phone's public Downloads folder.
class FilesTab extends StatefulWidget {
  const FilesTab({super.key, required this.dio, required this.serverUrl});

  final Dio dio;
  final String serverUrl;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  static const MethodChannel _channel = MethodChannel(
    'io.github.chasekolozsy.devota/control_agent',
  );

  List<Map<String, dynamic>> _files = [];
  String? _serverDir;
  bool _loading = false;
  String? _error;

  final Map<String, double> _downloadProgress = {};
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  String get _baseUrl => widget.serverUrl;

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.dio.get<Map<String, dynamic>>(
        '$_baseUrl/files',
        options: Options(responseType: ResponseType.json),
      );
      final data = response.data ?? const {};
      final rawFiles = (data['files'] as List?) ?? const [];
      final files = rawFiles
          .whereType<Map>()
          .map((item) => item.map((key, value) => MapEntry('$key', value)))
          .toList();
      if (!mounted) return;
      setState(() {
        _files = files;
        _serverDir = data['dir'] as String?;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _briefError(e);
      });
    }
  }

  Future<void> _download(Map<String, dynamic> file) async {
    final name = file['name'] as String?;
    if (name == null || _downloadProgress.containsKey(name)) return;
    final mimeType = (file['contentType'] as String?) ?? 'application/octet-stream';

    setState(() => _downloadProgress[name] = 0);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/file_transfer');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final tempPath = '${dir.path}/$name';
      await widget.dio.download(
        '$_baseUrl/files/download/${Uri.encodeComponent(name)}',
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _downloadProgress[name] = received / total);
          }
        },
      );

      String savedLabel = 'Downloads/$name';
      try {
        final result = await _channel.invokeMethod<dynamic>('saveToDownloads', {
          'filename': name,
          'sourcePath': tempPath,
          'mimeType': mimeType,
        });
        if (result is String && result.isNotEmpty) {
          savedLabel = result;
        }
      } on MissingPluginException {
        // Not running on Android (e.g. tests); the temp copy still exists.
        savedLabel = tempPath;
      }

      if (!mounted) return;
      setState(() => _downloadProgress.remove(name));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved to $savedLabel'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => OpenFilex.open(tempPath, type: mimeType),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloadProgress.remove(name));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: ${_briefError(e)}')),
      );
    }
  }

  Future<void> _delete(Map<String, dynamic> file) async {
    final name = file['name'] as String?;
    if (name == null || _deleting.contains(name)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('Remove "$name" from the build server?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleting.add(name));
    try {
      await widget.dio.delete<dynamic>(
        '$_baseUrl/files/${Uri.encodeComponent(name)}',
      );
      if (!mounted) return;
      setState(() => _deleting.remove(name));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting.remove(name));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: ${_briefError(e)}')),
      );
    }
  }

  String _briefError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status != null) return 'HTTP $status';
      return error.message ?? 'network error';
    }
    return error.toString();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  IconData _iconFor(String? contentType, String name) {
    final type = contentType ?? '';
    if (type.startsWith('image/')) return Icons.image_outlined;
    if (type.startsWith('video/')) return Icons.movie_outlined;
    if (type.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (type.startsWith('text/') || type.contains('json')) {
      return Icons.description_outlined;
    }
    if (name.endsWith('.zip') ||
        name.endsWith('.tar') ||
        name.endsWith('.gz') ||
        name.endsWith('.tgz')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'File transfers',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _serverDir == null
                ? 'Agents can drop files into the build server’s file-transfer '
                    'directory (or POST /files/upload). They show up here to download.'
                : 'Drop files into:\n$_serverDir',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: _buildBody(theme),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _files.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(
            Icons.cloud_off,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Could not reach the build server\n$_error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }
    if (_files.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(
            Icons.download_for_offline_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'No files waiting.\nAsk an agent to send you one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _files.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = _files[index];
        final name = (file['name'] as String?) ?? 'file';
        final size = (file['size'] as num?)?.toInt() ?? 0;
        final modified = (file['modified'] as String?) ?? '';
        final contentType = file['contentType'] as String?;
        final progress = _downloadProgress[name];
        final deleting = _deleting.contains(name);

        return ListTile(
          leading: Icon(_iconFor(contentType, name)),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: progress != null
              ? Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: LinearProgressIndicator(value: progress),
                )
              : Text(
                  '${_formatSize(size)}${modified.isNotEmpty ? '  ·  $modified' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Download to phone',
                onPressed: progress != null ? null : () => _download(file),
                icon: const Icon(Icons.download),
              ),
              IconButton(
                tooltip: 'Delete from server',
                onPressed: deleting ? null : () => _delete(file),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        );
      },
    );
  }
}
