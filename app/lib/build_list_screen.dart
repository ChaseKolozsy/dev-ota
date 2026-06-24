import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_service.dart';
import 'backup_tab.dart';
import 'connect_tab.dart';
import 'openai_key_dialog.dart';
import 'projects_tab.dart';
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
  static const double _appToolbarHeight = 36;
  static const double _tabStripHeight = 38;
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
  Set<String> _installedPackages = {};
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
  Map<String, int> _commandUseCounts = {};
  final _commandController = TextEditingController();
  final _agentUrlController = TextEditingController();
  final _agentTokenController = TextEditingController();
  final _githubRepoController = TextEditingController();
  final _githubWorkflowController = TextEditingController();
  final _githubRefController = TextEditingController();
  final _githubArtifactController = TextEditingController();
  bool _agentWholeDevice = false;
  bool _agentBusy = false;
  Map<String, dynamic>? _agentStatus;
  bool _githubBusy = false;
  String? _githubStatus;
  List<Map<String, dynamic>> _githubRuns = [];
  Timer? _backupDebounce;
  String? _serverRestoreAttemptedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 7, vsync: this);
    _loadServers();
    _loadIssues();
    _loadCommands();
    _loadAgentSettings();
    _loadGithubSettings();
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
    _githubRepoController.dispose();
    _githubWorkflowController.dispose();
    _githubRefController.dispose();
    _githubArtifactController.dispose();
    _backupDebounce?.cancel();
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
      _refreshInstalledPackages();
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

  String _buildPackageName(Map<String, dynamic> build) {
    return (build['packageName'] ?? '').toString().trim();
  }

  Future<void> _refreshInstalledPackages([
    Iterable<Map<String, dynamic>>? builds,
  ]) async {
    final source = builds ?? _builds;
    final packages = source
        .map(_buildPackageName)
        .where((packageName) => packageName.isNotEmpty)
        .toSet();
    if (packages.isEmpty) {
      if (mounted) setState(() => _installedPackages = {});
      return;
    }
    final installed = <String>{};
    for (final packageName in packages) {
      try {
        final ok = await _controlAgentChannel.invokeMethod<bool>(
          'isPackageInstalled',
          {'packageName': packageName},
        );
        if (ok == true) installed.add(packageName);
      } catch (_) {}
    }
    if (mounted) setState(() => _installedPackages = installed);
  }

  Future<void> _openInstalledBuildApp(Map<String, dynamic> build) async {
    final packageName = _buildPackageName(build);
    if (packageName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Build does not declare a package name')),
      );
      return;
    }
    try {
      final opened = await _controlAgentChannel.invokeMethod<bool>(
        'openPackage',
        {'packageName': packageName},
      );
      if (opened != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No launcher found for $packageName')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open failed: ${_briefErrorMessage(e)}')),
      );
    }
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
    await Future.delayed(const Duration(milliseconds: 500));
    await _refreshInstalledPackages();
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
    final countsJson = prefs.getString('command_usage_counts_json');
    if (countsJson != null && countsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(countsJson);
        if (decoded is Map) {
          _commandUseCounts = decoded.map(
            (key, value) => MapEntry(
              key.toString(),
              value is int ? value : int.tryParse(value.toString()) ?? 0,
            ),
          );
        }
      } catch (_) {
        _commandUseCounts = {};
      }
    }
    if (saved != null && mounted) {
      setState(() => _commands = saved);
    }
  }

  Future<void> _saveCommands() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('commands', _commands);
    await prefs.setString(
      'command_usage_counts_json',
      jsonEncode(_commandUseCounts),
    );
    _scheduleServerBackup();
  }

  List<String> get _rankedCommands {
    final indexed = _commands.asMap().entries.toList();
    indexed.sort((a, b) {
      final usage = (_commandUseCounts[b.value] ?? 0).compareTo(
        _commandUseCounts[a.value] ?? 0,
      );
      if (usage != 0) return usage;
      return a.key.compareTo(b.key);
    });
    return indexed.map((entry) => entry.value).toList();
  }

  List<String> get _quickCommands => _rankedCommands.take(12).toList();

  void _addCommand() {
    final text = _commandController.text.trim();
    if (text.isEmpty) return;
    setState(() => _commands.add(text));
    _commandController.clear();
    _saveCommands();
  }

  void _removeCommand(int index) {
    final command = _commands[index];
    setState(() {
      _commands.removeAt(index);
      if (!_commands.contains(command)) _commandUseCounts.remove(command);
    });
    _saveCommands();
  }

  void _removeCommandValue(String command) {
    final index = _commands.indexOf(command);
    if (index >= 0) _removeCommand(index);
  }

  void _recordCommandUse(String cmd) {
    if (cmd.trim().isEmpty) return;
    setState(() {
      _commandUseCounts[cmd] = (_commandUseCounts[cmd] ?? 0) + 1;
    });
    _saveCommands();
  }

  void _copyCommand(String cmd) {
    _recordCommandUse(cmd);
    Clipboard.setData(ClipboardData(text: cmd));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied'),
        duration: Duration(milliseconds: 900),
      ),
    );
  }

  void _pushCommandToServerClipboard(String cmd) {
    _recordCommandUse(cmd);
    _pushToServerClipboard(cmd, label: 'clipboard');
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
    _scheduleServerBackup();
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
    final initialValue = await _voice.loadApiKey() ?? '';
    if (!mounted) return null;
    final key = await OpenAiKeyDialog.show(context, initialValue: initialValue);
    if (key != null && key.isNotEmpty) {
      await _voice.saveApiKey(key);
      _scheduleServerBackup();
    }
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

  Future<void> _loadGithubSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _githubRepoController.text =
        prefs.getString('github_repo') ?? 'ChaseKolozsy/dev-ota';
    _githubWorkflowController.text =
        prefs.getString('github_workflow') ?? 'android.yml';
    _githubRefController.text = prefs.getString('github_ref') ?? 'main';
    _githubArtifactController.text =
        prefs.getString('github_artifact') ?? 'devota-android-debug-apks';
    if (mounted) setState(() {});
  }

  Future<void> _saveGithubSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('github_repo', _githubRepoController.text.trim());
    await prefs.setString(
      'github_workflow',
      _githubWorkflowController.text.trim(),
    );
    await prefs.setString('github_ref', _githubRefController.text.trim());
    await prefs.setString(
      'github_artifact',
      _githubArtifactController.text.trim(),
    );
    _scheduleServerBackup();
  }

  Future<void> _runGithubWorkflow() async {
    await _saveGithubSettings();
    if (!mounted) return;
    setState(() {
      _githubBusy = true;
      _githubStatus = 'Dispatching workflow...';
    });
    try {
      final resp = await _dio.post(
        '$_baseUrl/github/workflow/run',
        data: {
          'repo': _githubRepoController.text.trim(),
          'workflow': _githubWorkflowController.text.trim(),
          'ref': _githubRefController.text.trim(),
        },
        options: Options(sendTimeout: const Duration(seconds: 15)),
      );
      final data = Map<String, dynamic>.from(resp.data as Map);
      final runs = data['runs'] is List ? data['runs'] as List : const [];
      setState(() {
        _githubRuns = runs
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _githubStatus = 'Workflow dispatched.';
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _githubStatus =
              'Workflow dispatch failed: ${_briefErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _githubBusy = false);
    }
  }

  Future<void> _refreshGithubRuns() async {
    await _saveGithubSettings();
    if (!mounted) return;
    setState(() {
      _githubBusy = true;
      _githubStatus = 'Loading workflow runs...';
    });
    try {
      final resp = await _dio.get(
        '$_baseUrl/github/workflow/runs',
        queryParameters: {
          'repo': _githubRepoController.text.trim(),
          'workflow': _githubWorkflowController.text.trim(),
          'limit': '5',
        },
      );
      final data = Map<String, dynamic>.from(resp.data as Map);
      final runs = data['runs'] is List ? data['runs'] as List : const [];
      setState(() {
        _githubRuns = runs
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _githubStatus = 'Loaded ${_githubRuns.length} run(s).';
      });
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _githubStatus = 'Workflow list failed: ${_briefErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _githubBusy = false);
    }
  }

  Future<void> _downloadGithubArtifact({int? runId}) async {
    await _saveGithubSettings();
    if (!mounted) return;
    setState(() {
      _githubBusy = true;
      _githubStatus = 'Downloading artifact...';
    });
    try {
      final payload = <String, Object>{
        'repo': _githubRepoController.text.trim(),
        'workflow': _githubWorkflowController.text.trim(),
        'artifactName': _githubArtifactController.text.trim(),
      };
      if (runId != null) payload['runId'] = runId;
      final resp = await _dio.post(
        '$_baseUrl/github/workflow/download',
        data: payload,
        options: Options(receiveTimeout: const Duration(minutes: 3)),
      );
      final data = Map<String, dynamic>.from(resp.data as Map);
      final apks = data['apks'] is List ? data['apks'] as List : const [];
      setState(() {
        _githubStatus = 'Downloaded ${apks.length} APK artifact(s).';
      });
      await _fetchBuilds();
    } catch (e) {
      if (mounted) {
        setState(
          () => _githubStatus =
              'Artifact download failed: ${_briefErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _githubBusy = false);
    }
  }

  Future<void> _saveAgentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agent_ws_url', _agentUrlController.text.trim());
    await prefs.setString(
      'agent_pair_token',
      _agentTokenController.text.trim(),
    );
    await prefs.setBool('agent_whole_device', _agentWholeDevice);
    _scheduleServerBackup();
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

  void _scheduleServerBackup() {
    _backupDebounce?.cancel();
    _backupDebounce = Timer(const Duration(seconds: 2), () {
      _saveBackupToServerSilently();
    });
  }

  Future<void> _saveBackupToServerSilently() async {
    try {
      if (!await BackupService.hasLocalRestorableData()) return;
      await BackupService.saveToServer(_dio, _baseUrl);
    } catch (_) {
      // Server backup is opportunistic; local saves should never depend on it.
    }
  }

  Future<void> _restoreBackupFromServerIfEmpty() async {
    final server = _baseUrl;
    if (_serverRestoreAttemptedFor == server) return;
    _serverRestoreAttemptedFor = server;
    try {
      if (await BackupService.hasLocalRestorableData()) return;
      final restored = await BackupService.restoreFromServer(_dio, server);
      if (!restored || !mounted) return;
      await _reloadImportedSettings();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restored DevOTA backup from server')),
      );
    } catch (_) {
      // A missing/unreachable backup is normal on first setup.
    }
  }

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
    _restoreBackupFromServerIfEmpty();
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('servers', _servers);
    await prefs.setString('active_server', _activeServer);
    _scheduleServerBackup();
  }

  void _setActiveServer(String url) {
    if (!_servers.contains(url) || url == _activeServer) return;
    setState(() => _activeServer = url);
    _saveServers();
    _fetchBuilds();
    _restoreBackupFromServerIfEmpty();
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
    _restoreBackupFromServerIfEmpty();
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
      if (_activeServer != originalActive) {
        _fetchBuilds();
        _restoreBackupFromServerIfEmpty();
      }
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
      final resp = await _dio.get(
        '$_baseUrl/builds',
        queryParameters: {'t': DateTime.now().millisecondsSinceEpoch},
        options: Options(
          headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
        ),
      );
      final data = resp.data as List;
      final builds = data.cast<Map<String, dynamic>>();
      setState(() {
        _builds = builds;
        _loading = false;
      });
      _refreshInstalledPackages(builds);
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
      await Future.delayed(const Duration(milliseconds: 500));
      await _refreshInstalledPackages();
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: _appToolbarHeight,
        titleSpacing: 12,
        title: Text(
          'DevOTA',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              if (_tabController.index != 1) return const SizedBox.shrink();
              return SizedBox(
                width: _appToolbarHeight,
                height: _appToolbarHeight,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _loading ? null : _fetchBuilds,
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_tabStripHeight),
          child: SizedBox(
            height: _tabStripHeight,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorSize: TabBarIndicatorSize.label,
              labelPadding: const EdgeInsets.symmetric(horizontal: 8),
              labelStyle: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: theme.textTheme.labelSmall,
              tabs: const [
                _CompactTab(icon: Icons.wifi_tethering, label: 'Connect'),
                _CompactTab(icon: Icons.android, label: 'Builds'),
                _CompactTab(icon: Icons.view_kanban, label: 'Projects'),
                _CompactTab(icon: Icons.terminal, label: 'Terminal'),
                _CompactTab(icon: Icons.terminal, label: 'Commands'),
                _CompactTab(icon: Icons.hub, label: 'Agent'),
                _CompactTab(icon: Icons.sync, label: 'Backup'),
              ],
            ),
          ),
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
          ProjectsTab(dio: _dio, serverUrl: _baseUrl),
          SshTerminalTab(
            key: const PageStorageKey('ssh-terminal-tab'),
            dio: _dio,
            serverUrl: _baseUrl,
            quickCommands: _quickCommands,
            onCommandUsed: _recordCommandUse,
          ),
          _buildCommandsTab(),
          _buildAgentTab(),
          BackupTab(
            dio: _dio,
            serverUrl: _baseUrl,
            onImported: _reloadImportedSettings,
          ),
        ],
      ),
    );
  }

  Future<void> _reloadImportedSettings() async {
    await _loadServers();
    await _loadIssues();
    await _loadCommands();
    await _loadAgentSettings();
    await _loadGithubSettings();
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
              IconButton.filledTonal(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh builds',
                onPressed: _loading ? null : _fetchBuilds,
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
        _buildGithubActionsPanel(),
        Expanded(child: _buildBody()),
        _buildNotesSection(),
      ],
    );
  }

  Widget _buildGithubActionsPanel() {
    final subtitle = _githubStatus ?? 'Run workflow and download APK artifacts';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: ExpansionTile(
          leading: const Icon(Icons.cloud_download),
          title: const Text('GitHub Actions'),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 620;
                final fields = [
                  _buildGithubTextField(
                    controller: _githubRepoController,
                    label: 'Repo',
                    hint: 'owner/name',
                  ),
                  _buildGithubTextField(
                    controller: _githubWorkflowController,
                    label: 'Workflow',
                    hint: 'android.yml',
                  ),
                  _buildGithubTextField(
                    controller: _githubRefController,
                    label: 'Ref',
                    hint: 'main',
                  ),
                  _buildGithubTextField(
                    controller: _githubArtifactController,
                    label: 'Artifact',
                    hint: 'devota-android-debug-apks',
                  ),
                ];
                if (narrow) {
                  return Column(
                    children: [
                      for (var i = 0; i < fields.length; i++) ...[
                        fields[i],
                        if (i != fields.length - 1) const SizedBox(height: 8),
                      ],
                    ],
                  );
                }
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: fields[0]),
                        const SizedBox(width: 8),
                        Expanded(child: fields[1]),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: fields[2]),
                        const SizedBox(width: 8),
                        Expanded(child: fields[3]),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run'),
                  onPressed: _githubBusy ? null : _runGithubWorkflow,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Runs'),
                  onPressed: _githubBusy ? null : _refreshGithubRuns,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Latest'),
                  onPressed: _githubBusy
                      ? null
                      : () => _downloadGithubArtifact(),
                ),
              ],
            ),
            if (_githubBusy)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(),
              ),
            if (_githubRuns.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._githubRuns.take(3).map(_buildGithubRunTile),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGithubTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: label == 'Repo' ? TextInputType.url : TextInputType.text,
      textInputAction: TextInputAction.next,
      onChanged: (_) => _saveGithubSettings(),
    );
  }

  Widget _buildGithubRunTile(Map<String, dynamic> run) {
    final title = (run['displayTitle'] ?? 'Workflow run').toString();
    final status = (run['status'] ?? 'unknown').toString();
    final conclusion = run['conclusion']?.toString();
    final branch = run['headBranch']?.toString();
    final updated = run['updatedAt']?.toString();
    final runId = _asInt(run['databaseId']);
    final isSuccess = conclusion == 'success';
    final subtitleParts = [
      status,
      if (conclusion != null && conclusion.isNotEmpty) conclusion,
      if (branch != null && branch.isNotEmpty) branch,
      if (updated != null && updated.isNotEmpty) updated,
    ];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isSuccess
            ? Icons.check_circle
            : status == 'in_progress'
            ? Icons.pending
            : Icons.history,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitleParts.join('  •  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download),
        tooltip: 'Download artifact',
        onPressed: _githubBusy || !isSuccess || runId == null
            ? null
            : () => _downloadGithubArtifact(runId: runId),
      ),
    );
  }

  Widget _buildCommandsTab() {
    final rankedCommands = _rankedCommands;
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
          child: rankedCommands.isEmpty
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
                  itemCount: rankedCommands.length,
                  itemBuilder: (context, index) {
                    final cmd = rankedCommands[index];
                    final uses = _commandUseCounts[cmd] ?? 0;
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
                              if (uses > 0) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: 'Uses',
                                  child: Chip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text('$uses'),
                                  ),
                                ),
                              ],
                              IconButton(
                                icon: const Icon(Icons.copy, size: 20),
                                tooltip: 'Copy to phone clipboard',
                                onPressed: () => _copyCommand(cmd),
                              ),
                              IconButton(
                                icon: const Icon(Icons.computer, size: 20),
                                tooltip: 'Push to PC clipboard',
                                onPressed: () =>
                                    _pushCommandToServerClipboard(cmd),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                ),
                                tooltip: 'Delete',
                                onPressed: () => _removeCommandValue(cmd),
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
    final packageName = _buildPackageName(build);
    final isInstalled =
        packageName.isNotEmpty && _installedPackages.contains(packageName);

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
          if (isInstalled)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open installed app',
              onPressed: () => _openInstalledBuildApp(build),
            ),
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
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isInstalled)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open installed app',
              onPressed: () => _openInstalledBuildApp(build),
            ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Download and install',
            onPressed: () => _downloadAndInstall(build),
          ),
        ],
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
            '${isCached ? '  •  cached' : ''}'
            '${isInstalled ? '  •  installed' : ''}',
          ),
          if (packageName.isNotEmpty)
            Text(
              packageName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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

class _CompactTab extends StatelessWidget {
  const _CompactTab({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _BuildListScreenState._tabStripHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.fade),
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
