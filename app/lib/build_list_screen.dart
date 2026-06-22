import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_tab.dart';
import 'ssh_terminal_tab.dart';
import 'voice_input_service.dart';

class BuildListScreen extends StatefulWidget {
  const BuildListScreen({super.key});

  @override
  State<BuildListScreen> createState() => _BuildListScreenState();
}

class _BuildListScreenState extends State<BuildListScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const String _defaultServerUrl = 'http://127.0.0.1:8082';
  static const MethodChannel _controlAgentChannel = MethodChannel(
    'io.github.chasekolozsy.devota/control_agent',
  );
  late final TabController _tabController;
  List<String> _servers = [];
  String _activeServer = _defaultServerUrl;
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(minutes: 5),
    ),
  );
  List<Map<String, dynamic>> _builds = [];
  bool _loading = false;
  String? _error;
  final Map<String, double> _downloadProgress = {};
  final Map<String, bool> _downloading = {};
  final Map<String, String> _downloadStatus = {};
  final Map<String, Stopwatch> _downloadTimers = {};
  final _noteController = TextEditingController();
  late final _voice = VoiceInputService(_dio);
  List<String> _issues = [];
  bool _isRecording = false;
  bool _isTranscribing = false;
  // Cached APKs that have been downloaded but not yet deleted.
  // Keyed by sanitized build path so common names like app-debug.apk do not
  // collide across apps.
  Set<String> _cachedApks = {};
  Directory? _apkCacheDir;

  // Copy-paste command snippets shown on the Commands tab.
  List<String> _commands = [];
  final _commandController = TextEditingController();
  final _agentUrlController = TextEditingController();
  final _agentTokenController = TextEditingController();
  bool _agentWholeDevice = false;
  bool _agentBusy = false;
  Map<String, dynamic>? _agentStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 5, vsync: this);
    _loadServers();
    _loadIssues();
    _loadCommands();
    _loadAgentSettings();
    _refreshCachedApks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _noteController.dispose();
    _commandController.dispose();
    _agentUrlController.dispose();
    _agentTokenController.dispose();
    _voice.dispose();
    _dio.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user returns from the system installer (success OR cancel),
    // the downloaded APK is intentionally kept on disk so they can retry the
    // install without re-downloading. Deletion is now manual via the trash icon.
    if (state == AppLifecycleState.resumed) {
      _refreshCachedApks();
    }
  }

  Future<Directory> _getApkCacheDir() async {
    if (_apkCacheDir != null) return _apkCacheDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/apk_cache');
    if (!dir.existsSync()) await dir.create(recursive: true);
    _apkCacheDir = dir;
    return dir;
  }

  Future<void> _refreshCachedApks() async {
    final dir = await _getApkCacheDir();
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.apk'),
    );
    final names = files.map((f) {
      final segs = f.path.split(RegExp(r'[\\/]'));
      return segs.last;
    }).toSet();
    if (!mounted) return;
    setState(() => _cachedApks = names);
  }

  String _cacheFileName(Map<String, dynamic> build) {
    final path = (build['path'] as String?) ?? (build['filename'] as String);
    final safe = path.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.endsWith('.apk') ? safe : '$safe.apk';
  }

  Future<void> _installCachedApk(Map<String, dynamic> build) async {
    final filename = _cacheFileName(build);
    final dir = await _getApkCacheDir();
    final apkPath = '${dir.path}/$filename';
    if (!File(apkPath).existsSync()) {
      // Cache disappeared underneath us — fall back to a fresh download.
      await _refreshCachedApks();
      await _downloadAndInstall(build);
      return;
    }
    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open installer: ${result.message}')),
      );
    }
  }

  Future<void> _deleteCachedApk(Map<String, dynamic> build) async {
    final filename = _cacheFileName(build);
    final dir = await _getApkCacheDir();
    final f = File('${dir.path}/$filename');
    try {
      if (f.existsSync()) await f.delete();
    } catch (_) {}
    await _refreshCachedApks();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted $filename')));
    }
  }

  Future<void> _loadCommands() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('commands');
    if (saved != null && mounted) {
      setState(() => _commands = saved);
    }
  }

  Future<void> _saveCommands() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('commands', _commands);
  }

  void _addCommand() {
    final text = _commandController.text.trim();
    if (text.isEmpty) return;
    setState(() => _commands.add(text));
    _commandController.clear();
    _saveCommands();
  }

  void _removeCommand(int index) {
    setState(() => _commands.removeAt(index));
    _saveCommands();
  }

  void _copyCommand(String cmd) {
    Clipboard.setData(ClipboardData(text: cmd));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied'),
        duration: Duration(milliseconds: 900),
      ),
    );
  }

  String _issuesAsText() {
    return _issues
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value}')
        .join('\n');
  }

  Future<void> _loadIssues() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('issues');
    if (saved != null && mounted) {
      setState(() => _issues = saved);
    }
  }

  Future<void> _saveIssues() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('issues', _issues);
  }

  void _addIssue() {
    final text = _noteController.text.trim();
    if (text.isEmpty) return;
    setState(() => _issues.add(text));
    _noteController.clear();
    _saveIssues();
  }

  void _removeIssue(int index) {
    setState(() => _issues.removeAt(index));
    _saveIssues();
  }

  void _copyAllIssues() {
    if (_issues.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _issuesAsText()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${_issues.length} issue(s) copied')),
    );
  }

  void _clearAllIssues() {
    setState(() => _issues.clear());
    _saveIssues();
  }

  Future<String?> _promptOpenAiKey() async {
    final controller = TextEditingController(
      text: await _voice.loadApiKey() ?? '',
    );
    if (!mounted) {
      controller.dispose();
      return null;
    }
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('OpenAI API Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'sk-...',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (key != null && key.isNotEmpty) await _voice.saveApiKey(key);
    return key;
  }

  Future<void> _toggleIssueRecording() async {
    if (_isRecording) {
      final path = await _voice.stopRecording();
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _isTranscribing = true;
      });
      try {
        final key = await _voice.loadApiKey();
        if (key == null || key.isEmpty) return;
        final text = path == null ? '' : await _voice.transcribe(path, key);
        if (text.isNotEmpty) {
          final existing = _noteController.text;
          _noteController.text = existing.isEmpty ? text : '$existing $text';
          _noteController.selection = TextSelection.fromPosition(
            TextPosition(offset: _noteController.text.length),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Transcription failed: $e')));
        }
      } finally {
        await VoiceInputService.deleteRecording(path);
        if (mounted) setState(() => _isTranscribing = false);
      }
      return;
    }

    var key = await _voice.loadApiKey();
    if (key == null || key.isEmpty) {
      key = await _promptOpenAiKey();
      if (key == null || key.isEmpty) return;
    }
    final ok = await _voice.requestMicrophone();
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
      }
      return;
    }
    await _voice.startRecording('issue_voice_note.m4a');
    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _loadAgentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _agentUrlController.text = prefs.getString('agent_ws_url') ?? '';
    _agentTokenController.text = prefs.getString('agent_pair_token') ?? '';
    _agentWholeDevice = prefs.getBool('agent_whole_device') ?? false;
    if (mounted) setState(() {});
    _refreshAgentStatus();
  }

  Future<void> _saveAgentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agent_ws_url', _agentUrlController.text.trim());
    await prefs.setString(
      'agent_pair_token',
      _agentTokenController.text.trim(),
    );
    await prefs.setBool('agent_whole_device', _agentWholeDevice);
  }

  Future<void> _startAgent() async {
    final url = _agentUrlController.text.trim();
    final token = _agentTokenController.text.trim();
    if (url.isEmpty || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent URL and token are required')),
      );
      return;
    }
    setState(() => _agentBusy = true);
    try {
      await _saveAgentSettings();
      await _controlAgentChannel.invokeMethod('startAgent', {
        'url': url,
        'token': token,
        'allowWholeDevice': _agentWholeDevice,
      });
      await Future.delayed(const Duration(milliseconds: 350));
      await _refreshAgentStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Agent start failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  Future<void> _stopAgent() async {
    setState(() => _agentBusy = true);
    try {
      await _controlAgentChannel.invokeMethod('stopAgent');
      await Future.delayed(const Duration(milliseconds: 250));
      await _refreshAgentStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Agent stop failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  Future<void> _refreshAgentStatus() async {
    try {
      final raw = await _controlAgentChannel.invokeMapMethod<String, dynamic>(
        'getAgentStatus',
      );
      if (!mounted) return;
      setState(
        () =>
            _agentStatus = raw == null ? null : Map<String, dynamic>.from(raw),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _agentStatus = {'error': e.toString()});
    }
  }

  Future<void> _openAccessibilitySettings() async {
    await _controlAgentChannel.invokeMethod('openAccessibilitySettings');
  }

  Future<void> _pushToServerClipboard(
    String text, {
    String label = 'clipboard',
  }) async {
    try {
      final resp = await _dio.post(
        '$_baseUrl/clipboard',
        data: text,
        options: Options(
          headers: {'Content-Type': 'text/plain; charset=utf-8'},
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sent to PC $label'),
            duration: const Duration(milliseconds: 1100),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PC clipboard returned ${resp.statusCode}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PC clipboard push failed: ${_briefErrorMessage(e)}'),
        ),
      );
    }
  }

  String get _baseUrl => _activeServer.trim().replaceAll(RegExp(r'/+$'), '');

  Future<void> _loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('servers') ?? [];
    if (saved.isEmpty) {
      // First run on this install: seed with the default so the UI has at
      // least one entry. Saved immediately so subsequent launches skip this.
      saved.add(_defaultServerUrl);
    }
    final active = prefs.getString('active_server') ?? saved.first;
    if (!mounted) return;
    setState(() {
      _servers = saved;
      _activeServer = saved.contains(active) ? active : saved.first;
    });
    await _saveServers();
    _fetchBuilds();
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('servers', _servers);
    await prefs.setString('active_server', _activeServer);
  }

  void _setActiveServer(String url) {
    if (!_servers.contains(url) || url == _activeServer) return;
    setState(() => _activeServer = url);
    _saveServers();
    _fetchBuilds();
  }

  void _addAndSelectServer(String url) {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) return;
    setState(() {
      if (!_servers.contains(clean)) _servers.add(clean);
      _activeServer = clean;
    });
    _saveServers();
    _fetchBuilds();
  }

  Future<void> _showManageServersDialog() async {
    final originalActive = _activeServer;
    final result = await showDialog<_ManageServersResult>(
      context: context,
      builder: (ctx) => _ManageServersDialog(
        initialServers: List<String>.from(_servers),
        initialActive: _activeServer,
        defaultServerUrl: _defaultServerUrl,
      ),
    );
    if (result == null || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _servers = result.servers;
        _activeServer = result.servers.contains(result.active)
            ? result.active
            : result.servers.first;
      });
      _saveServers();
      if (_activeServer != originalActive) _fetchBuilds();
    });
  }

  Future<void> _fetchBuilds() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Refresh also wipes the local APK cache. Yesterday's APK and
    // today's APK can share the filename `app-debug.apk`, and the
    // installer's "install from cache" path skips the redownload —
    // so without nuking the cache here, the user clicks "install"
    // after a refresh and still gets the old build. The whole reason
    // they tapped refresh is to get the latest.
    await _clearApkCache();
    try {
      final resp = await _dio.get('$_baseUrl/builds');
      final data = resp.data as List;
      setState(() {
        _builds = data.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = _briefErrorMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _clearApkCache() async {
    try {
      final dir = await _getApkCacheDir();
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.endsWith('.apk') || f.path.endsWith('.apk.gz')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    await _refreshCachedApks();
  }

  String _briefErrorMessage(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionError:
          return 'Cannot reach server.';
        case DioExceptionType.connectionTimeout:
          return 'Connection timed out.';
        case DioExceptionType.receiveTimeout:
          return 'Server did not respond in time.';
        case DioExceptionType.sendTimeout:
          return 'Send timed out.';
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          return code != null ? 'Server returned HTTP $code.' : 'Bad response.';
        case DioExceptionType.cancel:
          return 'Request cancelled.';
        case DioExceptionType.badCertificate:
          return 'Bad TLS certificate.';
        case DioExceptionType.unknown:
          break;
      }
      return e.message ?? 'Network error.';
    }
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _downloadAndInstall(Map<String, dynamic> build) async {
    final path = build['path'] as String;
    final cacheFileName = _cacheFileName(build);

    if (_downloading[path] == true) return;

    final stopwatch = Stopwatch()..start();
    _downloadTimers[path] = stopwatch;

    setState(() {
      _downloading[path] = true;
      _downloadProgress[path] = 0;
      _downloadStatus[path] = 'Downloading... 0s';
    });

    try {
      final cacheDir = await _getApkCacheDir();
      final gzPath = '${cacheDir.path}/$cacheFileName.gz';
      final apkPath = '${cacheDir.path}/$cacheFileName';

      // Download compressed .gz
      await _dio.download(
        '$_baseUrl/download/$path',
        gzPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final elapsed = stopwatch.elapsed.inSeconds;
            setState(() {
              _downloadProgress[path] = received / total * 0.9;
              _downloadStatus[path] = 'Downloading... ${elapsed}s';
            });
          }
        },
      );

      final downloadSecs = stopwatch.elapsed.inSeconds;

      // Decompress .gz -> .apk
      setState(() {
        _downloadStatus[path] =
            'Decompressing... (downloaded in ${downloadSecs}s)';
        _downloadProgress[path] = 0.9;
      });

      final gzFile = File(gzPath);
      final apkFile = File(apkPath);
      final gzBytes = await gzFile.readAsBytes();
      final decompressed = gzip.decode(gzBytes);
      await apkFile.writeAsBytes(decompressed);
      await gzFile.delete();

      stopwatch.stop();
      final totalSecs = stopwatch.elapsed.inSeconds;

      setState(() {
        _downloading[path] = false;
        _downloadProgress.remove(path);
        _downloadStatus.remove(path);
        _downloadTimers.remove(path);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Done in ${totalSecs}s (download: ${downloadSecs}s, decompress: ${totalSecs - downloadSecs}s)',
            ),
          ),
        );
      }

      await _refreshCachedApks();
      final result = await OpenFilex.open(
        apkPath,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open installer: ${result.message}'),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _downloading[path] = false;
        _downloadProgress.remove(path);
        _downloadStatus.remove(path);
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DevOTA'),
        actions: [
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              if (_tabController.index != 1) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _fetchBuilds,
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.wifi_tethering), text: 'Connect'),
            Tab(icon: Icon(Icons.android), text: 'Builds'),
            Tab(icon: Icon(Icons.terminal), text: 'Terminal'),
            Tab(icon: Icon(Icons.terminal), text: 'Commands'),
            Tab(icon: Icon(Icons.hub), text: 'Agent'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          ConnectTab(
            channel: _controlAgentChannel,
            servers: _servers,
            activeServer: _activeServer,
            onServerSelected: _addAndSelectServer,
          ),
          _buildBuildsTab(),
          SshTerminalTab(dio: _dio),
          _buildCommandsTab(),
          _buildAgentTab(),
        ],
      ),
    );
  }

  Widget _buildBuildsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Server',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _servers.contains(_activeServer)
                          ? _activeServer
                          : null,
                      isExpanded: true,
                      isDense: true,
                      items: _servers
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(
                                s,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) _setActiveServer(v);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.dns),
                tooltip: 'Manage servers',
                onPressed: _showManageServersDialog,
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
        _buildNotesSection(),
      ],
    );
  }

  Widget _buildCommandsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _commandController,
                  decoration: const InputDecoration(
                    labelText: 'New command',
                    hintText: 'e.g. claude --dangerously-skip-permissions',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(fontFamily: 'monospace'),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addCommand(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.add),
                onPressed: _addCommand,
                tooltip: 'Add command',
              ),
            ],
          ),
        ),
        Expanded(
          child: _commands.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No commands yet.\nAdd one above, then tap to copy.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  itemCount: _commands.length,
                  itemBuilder: (context, index) {
                    final cmd = _commands[index];
                    return Card(
                      child: InkWell(
                        onTap: () => _copyCommand(cmd),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: SelectableText(
                                  cmd,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 20),
                                tooltip: 'Copy to phone clipboard',
                                onPressed: () => _copyCommand(cmd),
                              ),
                              IconButton(
                                icon: const Icon(Icons.computer, size: 20),
                                tooltip: 'Push to PC clipboard',
                                onPressed: () => _pushToServerClipboard(
                                  cmd,
                                  label: 'clipboard',
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                ),
                                tooltip: 'Delete',
                                onPressed: () => _removeCommand(index),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildAgentTab() {
    final status = _agentStatus ?? const <String, dynamic>{};
    final accessibility = status['accessibility'] is Map
        ? Map<String, dynamic>.from(status['accessibility'] as Map)
        : const <String, dynamic>{};
    final running = status['running'] == true;
    final connected = status['connected'] == true;
    final accessibilityEnabled = accessibility['enabled'] == true;
    final lastError = status['lastError']?.toString();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _agentUrlController,
          decoration: const InputDecoration(
            labelText: 'Agent WebSocket URL',
            hintText: 'ws://<computer-ip>:8083/phone',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          onChanged: (_) => _saveAgentSettings(),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _agentTokenController,
          decoration: const InputDecoration(
            labelText: 'Pair token',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onChanged: (_) => _saveAgentSettings(),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Whole-device control'),
          subtitle: const Text('Requires the MCP server env flag too'),
          value: _agentWholeDevice,
          onChanged: (v) {
            setState(() => _agentWholeDevice = v);
            _saveAgentSettings();
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
              onPressed: _agentBusy ? null : _startAgent,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
              onPressed: _agentBusy ? null : _stopAgent,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.accessibility_new),
              label: const Text('Accessibility'),
              onPressed: _openAccessibilitySettings,
            ),
            IconButton.filledTonal(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh status',
              onPressed: _refreshAgentStatus,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusRow(
                  'Service',
                  running ? 'running' : 'stopped',
                  running ? Icons.check_circle : Icons.radio_button_unchecked,
                ),
                _statusRow(
                  'Relay',
                  connected ? 'connected' : 'disconnected',
                  connected ? Icons.link : Icons.link_off,
                ),
                _statusRow(
                  'Accessibility',
                  accessibilityEnabled ? 'enabled' : 'disabled',
                  accessibilityEnabled
                      ? Icons.visibility
                      : Icons.visibility_off,
                ),
                if (accessibility['activePackage'] != null)
                  _statusRow(
                    'Package',
                    accessibility['activePackage'].toString(),
                    Icons.apps,
                  ),
                if (lastError != null && lastError.isNotEmpty)
                  _statusRow('Error', lastError, Icons.error_outline),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  String _buildAppId(Map<String, dynamic> build) {
    return (build['appId'] ?? build['kind'] ?? 'builds').toString();
  }

  String _buildAppLabel(Map<String, dynamic> build) {
    final label = build['appLabel'] ?? build['label'];
    if (label != null && label.toString().trim().isNotEmpty) {
      return label.toString();
    }
    return _buildAppId(build);
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Map<String, List<Map<String, dynamic>>> _groupBuildsByApp() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final build in _builds) {
      grouped.putIfAbsent(_buildAppId(build), () => []).add(build);
    }
    return grouped;
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'Connection failed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    if (_builds.isEmpty) {
      return const Center(
        child: Text(
          'No APK builds found.\nCheck devota.yaml and build the target app.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final grouped = _groupBuildsByApp();
    final appIds = grouped.keys.toList()
      ..sort(
        (a, b) => _buildAppLabel(
          grouped[a]!.first,
        ).compareTo(_buildAppLabel(grouped[b]!.first)),
      );
    return ListView.builder(
      itemCount: appIds.length,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemBuilder: (context, index) {
        final appBuilds = grouped[appIds[index]]!;
        final label = _buildAppLabel(appBuilds.first);
        final latest = appBuilds.first;
        return Card(
          child: ExpansionTile(
            leading: const Icon(Icons.apps),
            title: Text(label),
            subtitle: Text(
              '${appBuilds.length} build${appBuilds.length == 1 ? '' : 's'}'
              '  •  latest ${latest['modified']}',
            ),
            initiallyExpanded: index == 0,
            children: appBuilds.map(_buildBuildTile).toList(),
          ),
        );
      },
    );
  }

  Widget _buildBuildTile(Map<String, dynamic> build) {
    final path = build['path'] as String;
    final filename = build['filename'] as String;
    final isDownloading = _downloading[path] == true;
    final progress = _downloadProgress[path];
    final status = _downloadStatus[path];
    final size = _asInt(build['size']) ?? 0;
    final compressedSize = _asInt(build['compressed_size']);
    final isCached = _cachedApks.contains(_cacheFileName(build));

    Widget trailing;
    if (isDownloading) {
      trailing = const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (isCached) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.install_mobile),
            tooltip: 'Install cached APK',
            onPressed: () => _installCachedApk(build),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete cached APK',
            onPressed: () => _deleteCachedApk(build),
          ),
        ],
      );
    } else {
      trailing = IconButton(
        icon: const Icon(Icons.download),
        tooltip: 'Download and install',
        onPressed: () => _downloadAndInstall(build),
      );
    }

    return ListTile(
      leading: Icon(
        isCached ? Icons.android : Icons.android_outlined,
        color: isCached ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(filename),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_formatSize(size)}'
            '${compressedSize != null ? '  ->  ${_formatSize(compressedSize)} gz' : ''}'
            '  •  ${build['modified']}'
            '${isCached ? '  •  cached' : ''}',
          ),
          if (isDownloading && status != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 2),
                  Text(status, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
        ],
      ),
      trailing: trailing,
    );
  }

  Widget _buildNotesSection() {
    final media = MediaQuery.of(context);
    final usable = media.size.height - media.viewInsets.bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: usable * 0.4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
            child: Row(
              children: [
                Text('Issues', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 4),
                Text(
                  '(${_issues.length})',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: 'Copy all to phone clipboard',
                  onPressed: _issues.isEmpty ? null : _copyAllIssues,
                ),
                IconButton(
                  icon: const Icon(Icons.computer, size: 20),
                  tooltip: 'Push all to PC clipboard',
                  onPressed: _issues.isEmpty
                      ? null
                      : () => _pushToServerClipboard(
                          _issuesAsText(),
                          label: 'clipboard',
                        ),
                ),
                IconButton(
                  icon: const Icon(Icons.key, size: 20),
                  tooltip: 'Set OpenAI key',
                  onPressed: _promptOpenAiKey,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep, size: 20),
                  tooltip: 'Clear all',
                  onPressed: _issues.isEmpty
                      ? null
                      : () {
                          showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Clear all issues?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _clearAllIssues();
                                  },
                                  child: const Text('Clear'),
                                ),
                              ],
                            ),
                          );
                        },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _noteController,
                    decoration: const InputDecoration(
                      hintText: 'Describe an issue...',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 4,
                    minLines: 3,
                    textInputAction: TextInputAction.newline,
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filled(
                      icon: Icon(
                        _isRecording ? Icons.stop : Icons.mic,
                        color: _isRecording ? Colors.red : null,
                      ),
                      tooltip: _isRecording ? 'Stop recording' : 'Voice input',
                      onPressed: _isTranscribing ? null : _toggleIssueRecording,
                    ),
                    const SizedBox(height: 4),
                    IconButton.filled(
                      icon: _isTranscribing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                      onPressed: _isTranscribing ? null : _addIssue,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_issues.isNotEmpty)
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                itemCount: _issues.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${index + 1}. ',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Expanded(child: Text(_issues[index])),
                        GestureDetector(
                          onTap: () => _removeIssue(index),
                          child: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          if (_issues.isEmpty)
            const Padding(padding: EdgeInsets.only(bottom: 12)),
        ],
      ),
    );
  }
}

class _ManageServersResult {
  const _ManageServersResult({required this.servers, required this.active});
  final List<String> servers;
  final String active;
}

/// Self-contained dialog for managing the saved server list.
///
/// The dialog has its own State class (not StatefulBuilder), keeps a private
/// copy of the server list, and returns the final state via Navigator.pop.
/// The parent applies the result post-frame. This separation avoids the
/// cross-tree setState pattern that previously tripped Flutter's
/// `dependents.isEmpty` assertion on dialog dismount.
class _ManageServersDialog extends StatefulWidget {
  const _ManageServersDialog({
    required this.initialServers,
    required this.initialActive,
    required this.defaultServerUrl,
  });

  final List<String> initialServers;
  final String initialActive;
  final String defaultServerUrl;

  @override
  State<_ManageServersDialog> createState() => _ManageServersDialogState();
}

class _ManageServersDialogState extends State<_ManageServersDialog> {
  late List<String> _servers;
  late String _active;
  late final String _originalActive;
  late final List<String> _originalServers;
  final _addController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _servers = List<String>.from(widget.initialServers);
    _active = widget.initialActive;
    _originalActive = widget.initialActive;
    _originalServers = List<String>.from(widget.initialServers);
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  bool get _changed =>
      _active != _originalActive ||
      _servers.length != _originalServers.length ||
      !_servers.every(_originalServers.contains);

  void _doAdd() {
    final url = _addController.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isEmpty || _servers.contains(url)) return;
    setState(() {
      _servers.add(url);
      _addController.clear();
    });
  }

  void _doActivate(String url) {
    if (!_servers.contains(url) || url == _active) return;
    setState(() => _active = url);
  }

  void _doRemove(String url) {
    if (_servers.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot remove the only saved server')),
      );
      return;
    }
    setState(() {
      _servers.remove(url);
      if (_active == url) _active = _servers.first;
    });
  }

  void _doReset() {
    setState(() {
      _servers
        ..clear()
        ..add(widget.defaultServerUrl);
      _active = widget.defaultServerUrl;
    });
  }

  void _close() {
    Navigator.of(context).pop(
      _changed
          ? _ManageServersResult(
              servers: List<String>.from(_servers),
              active: _active,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Manage servers', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addController,
                      decoration: const InputDecoration(
                        hintText: 'http://host:port',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _doAdd(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add',
                    onPressed: _doAdd,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _servers.length,
                  itemBuilder: (context, index) {
                    final url = _servers[index];
                    final isActive = url == _active;
                    return ListTile(
                      leading: Icon(
                        isActive ? Icons.check_circle : Icons.dns_outlined,
                        color: isActive ? theme.colorScheme.primary : null,
                      ),
                      title: Text(
                        url,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isActive
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      onTap: () => _doActivate(url),
                      trailing: IconButton.filledTonal(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: _servers.length > 1
                            ? 'Remove this server'
                            : 'Cannot remove the only server',
                        color: theme.colorScheme.error,
                        onPressed: _servers.length > 1
                            ? () => _doRemove(url)
                            : null,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _doReset,
                    child: const Text('Reset to default'),
                  ),
                  TextButton(onPressed: _close, child: const Text('Done')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
