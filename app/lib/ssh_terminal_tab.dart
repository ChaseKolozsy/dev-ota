import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'backup_service.dart';
import 'openai_key_dialog.dart';
import 'terminal_macro.dart';
import 'voice_input_service.dart';

class _TerminalKeyBarItem {
  const _TerminalKeyBarItem({
    required this.originalIndex,
    required this.useCount,
    required this.build,
  });

  final int originalIndex;
  final int useCount;
  final Widget Function() build;
}

class SshTerminalTab extends StatefulWidget {
  const SshTerminalTab({
    super.key,
    required this.dio,
    required this.serverUrl,
    this.quickCommands = const [],
    this.quickMacros = const [],
    this.macroController,
    this.fullscreen = false,
    this.onFullscreenChanged,
    this.onCommandUsed,
    this.onMacroUsed,
  });

  final Dio dio;
  final String serverUrl;
  final List<String> quickCommands;
  final List<TerminalMacro> quickMacros;
  final TerminalMacroController? macroController;
  final bool fullscreen;
  final ValueChanged<bool>? onFullscreenChanged;
  final ValueChanged<String>? onCommandUsed;
  final ValueChanged<TerminalMacro>? onMacroUsed;

  @override
  State<SshTerminalTab> createState() => _SshTerminalTabState();
}

class _SshTerminalTabState extends State<SshTerminalTab>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin<SshTerminalTab> {
  final _storage = const FlutterSecureStorage();
  late final _voice = VoiceInputService(widget.dio);
  late final _terminal = Terminal(maxLines: 10000);
  final _terminalController = TerminalController(
    pointerInputs: const PointerInputs({PointerInput.tap, PointerInput.scroll}),
  );
  final _terminalFocusNode = FocusNode();
  final _terminalScrollController = ScrollController();
  final _composerFocusNode = FocusNode();

  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _composerController = TextEditingController();

  bool _usePrivateKey = false;
  bool _busy = false;
  bool _connected = false;
  bool _recording = false;
  bool _transcribing = false;
  bool _tmuxScrollMode = false;
  bool _terminalToolsVisible = true;
  bool _nativeKeyboardLocked = false;
  bool _macroRunning = false;
  double _tmuxScrollRemainder = 0;
  double _terminalMouseScrollRemainder = 0;
  double _terminalFontSize = _terminalDefaultFontSize;
  Map<String, int> _terminalKeyUseCounts = {};
  String? _status;
  String? _privateKeyName;
  String? _generatedPublicKey;

  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Timer? _backupDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminal.write('DevOTA SSH terminal\r\n');
    _terminal.onOutput = (data) =>
        _session?.write(Uint8List.fromList(utf8.encode(data)));
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _session?.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };
    _loadProfile();
    _loadTerminalKeyUsage();
    _loadTerminalToolVisibility();
    _loadNativeKeyboardLock();
    _loadTerminalFontSize();
    _attachMacroController();
  }

  @override
  void dispose() {
    widget.macroController?.detach();
    WidgetsBinding.instance.removeObserver(this);
    _disconnect();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _passphraseController.dispose();
    _composerController.dispose();
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _backupDebounce?.cancel();
    _terminalFocusNode.dispose();
    _terminalScrollController.dispose();
    _composerFocusNode.dispose();
    _voice.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SshTerminalTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.macroController != widget.macroController) {
      oldWidget.macroController?.detach();
      _attachMacroController();
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_connected) _terminalFocusNode.requestFocus();
    });
  }

  String get _host => _hostController.text.trim();
  int get _port => int.tryParse(_portController.text.trim()) ?? 22;
  String get _username => _usernameController.text.trim();
  String get _profilePrefix =>
      'ssh_profile:${_host.isEmpty ? 'default' : _host}:$_port';
  String get _hostKeyStorageKey => '$_profilePrefix:host_key';
  String get _passwordStorageKey => '$_profilePrefix:password';
  String get _privateKeyStorageKey => '$_profilePrefix:private_key';
  String get _passphraseStorageKey => '$_profilePrefix:passphrase';
  String get _generatedPrivateKeyStorageKey =>
      'ssh_terminal_generated_private_key';
  String get _generatedPublicKeyStorageKey =>
      'ssh_terminal_generated_public_key';
  static const _terminalKeyUsageCountsKey = 'terminal_key_usage_counts_json';
  static const _terminalToolsVisibleKey = 'terminal_tools_visible';
  static const _nativeKeyboardLockedKey = 'terminal_native_keyboard_locked';
  static const _terminalFontSizeKey = 'terminal_font_size';
  static const _terminalDefaultFontSize = 13.0;
  static const _terminalMinFontSize = 8.0;
  static const _terminalMaxFontSize = 22.0;
  static const _tmuxScrollPixelsPerLine = 18.0;
  static const _tmuxScrollMaxLinesPerGesture = 12;

  void _attachMacroController() {
    widget.macroController?.attach(
      runner: _runMacro,
      canRun: () => _connected && !_macroRunning,
      isRunning: () => _macroRunning,
    );
  }

  void _notifyMacroController() {
    widget.macroController?.notifyStateChanged();
  }

  Future<void> _loadTerminalToolVisibility() async {
    final prefs = await SharedPreferences.getInstance();
    final visible = prefs.getBool(_terminalToolsVisibleKey) ?? true;
    if (mounted) setState(() => _terminalToolsVisible = visible);
  }

  Future<void> _saveTerminalToolVisibility() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_terminalToolsVisibleKey, _terminalToolsVisible);
    _scheduleServerBackup();
  }

  void _toggleTerminalTools() {
    setState(() => _terminalToolsVisible = !_terminalToolsVisible);
    unawaited(_saveTerminalToolVisibility());
  }

  Future<void> _loadNativeKeyboardLock() async {
    final prefs = await SharedPreferences.getInstance();
    final locked = prefs.getBool(_nativeKeyboardLockedKey) ?? false;
    if (mounted) setState(() => _nativeKeyboardLocked = locked);
  }

  Future<void> _saveNativeKeyboardLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nativeKeyboardLockedKey, _nativeKeyboardLocked);
    _scheduleServerBackup();
  }

  void _setNativeKeyboardLocked(bool locked) {
    if (_nativeKeyboardLocked == locked) return;
    setState(() {
      _nativeKeyboardLocked = locked;
      _status = locked
          ? 'Native keyboard locked off.'
          : 'Native keyboard allowed.';
    });
    unawaited(_saveNativeKeyboardLock());
    if (locked) {
      _composerFocusNode.unfocus();
      FocusScope.of(context).requestFocus(_terminalFocusNode);
      _terminalFocusNode.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    } else {
      _focusTerminalInput();
    }
  }

  Future<void> _loadTerminalFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final fontSize =
        prefs.getDouble(_terminalFontSizeKey) ?? _terminalDefaultFontSize;
    if (mounted) {
      setState(() => _terminalFontSize = _boundedTerminalFontSize(fontSize));
    }
  }

  double _boundedTerminalFontSize(double fontSize) {
    return fontSize
        .clamp(_terminalMinFontSize, _terminalMaxFontSize)
        .toDouble();
  }

  Future<void> _saveTerminalFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_terminalFontSizeKey, _terminalFontSize);
    _scheduleServerBackup();
  }

  void _adjustTerminalFontSize(double factor) {
    final next = _boundedTerminalFontSize(_terminalFontSize * factor);
    if (next == _terminalFontSize) return;
    setState(() {
      _terminalFontSize = next;
      _status = 'Terminal font ${next.toStringAsFixed(1)}px';
    });
    unawaited(_saveTerminalFontSize());
  }

  void _resetTerminalFontSize() {
    setState(() {
      _terminalFontSize = _terminalDefaultFontSize;
      _status = 'Terminal font reset.';
    });
    unawaited(_saveTerminalFontSize());
  }

  void _collapseTerminalToolsForScroll() {
    if (!mounted) return;
    if (!_terminalToolsVisible &&
        !_terminalFocusNode.hasFocus &&
        !_composerFocusNode.hasFocus) {
      return;
    }
    if (_terminalToolsVisible) {
      setState(() => _terminalToolsVisible = false);
      unawaited(_saveTerminalToolVisibility());
    }
    _hideTerminalKeyboard();
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    _collapseTerminalToolsForScroll();
    _handleTerminalScrollDelta(-event.delta.dy);
  }

  void _handleTerminalPointerSignal(PointerSignalEvent event) {
    _collapseTerminalToolsForScroll();
    if (_tmuxScrollMode && event is PointerScrollEvent) {
      _handleTerminalScrollDelta(event.scrollDelta.dy);
    }
    if (!_tmuxScrollMode && event is PointerScrollEvent) {
      _handleTerminalScrollDelta(event.scrollDelta.dy);
    }
  }

  void _handleTerminalScrollDelta(double scrollDeltaY) {
    if (_tmuxScrollMode) {
      _scrollTmuxCopyMode(scrollDeltaY);
      return;
    }
    if (_terminal.mouseMode.reportScroll) {
      _scrollTerminalMouseMode(scrollDeltaY);
    }
  }

  void _scrollTmuxCopyMode(double scrollDeltaY) {
    if (!_connected || scrollDeltaY == 0) return;
    _tmuxScrollRemainder += scrollDeltaY;
    var lines = (_tmuxScrollRemainder.abs() / _tmuxScrollPixelsPerLine).floor();
    if (lines == 0) return;
    if (lines > _tmuxScrollMaxLinesPerGesture) {
      lines = _tmuxScrollMaxLinesPerGesture;
    }
    final direction = _tmuxScrollRemainder.isNegative ? -1 : 1;
    _tmuxScrollRemainder -= direction * lines * _tmuxScrollPixelsPerLine;
    final sequence = direction < 0 ? '\x1B[A' : '\x1B[B';
    _writeToSession(List.filled(lines, sequence).join());
  }

  void _scrollTerminalMouseMode(double scrollDeltaY) {
    if (!_connected || scrollDeltaY == 0) return;
    _terminalMouseScrollRemainder += scrollDeltaY;
    var lines = (_terminalMouseScrollRemainder.abs() / _tmuxScrollPixelsPerLine)
        .floor();
    if (lines == 0) return;
    if (lines > _tmuxScrollMaxLinesPerGesture) {
      lines = _tmuxScrollMaxLinesPerGesture;
    }
    final direction = _terminalMouseScrollRemainder.isNegative ? -1 : 1;
    _terminalMouseScrollRemainder -=
        direction * lines * _tmuxScrollPixelsPerLine;
    final button = direction < 0
        ? TerminalMouseButton.wheelUp
        : TerminalMouseButton.wheelDown;
    final position = CellOffset(
      (_terminal.viewWidth / 2).floor(),
      (_terminal.viewHeight / 2).floor(),
    );
    for (var i = 0; i < lines; i++) {
      _terminal.mouseInput(button, TerminalMouseButtonState.down, position);
    }
  }

  void _resetTerminalScrollGestures() {
    _tmuxScrollRemainder = 0;
    _terminalMouseScrollRemainder = 0;
  }

  Future<void> _loadTerminalKeyUsage() async {
    final prefs = await SharedPreferences.getInstance();
    final countsJson = prefs.getString(_terminalKeyUsageCountsKey);
    if (countsJson == null || countsJson.isEmpty) return;
    try {
      final decoded = jsonDecode(countsJson);
      if (decoded is! Map) return;
      final counts = decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          value is int ? value : int.tryParse(value.toString()) ?? 0,
        ),
      );
      if (mounted) setState(() => _terminalKeyUseCounts = counts);
    } catch (_) {
      if (mounted) setState(() => _terminalKeyUseCounts = {});
    }
  }

  void _recordTerminalKeyUse(String id) {
    setState(() {
      _terminalKeyUseCounts = {
        ..._terminalKeyUseCounts,
        id: (_terminalKeyUseCounts[id] ?? 0) + 1,
      };
    });
    unawaited(_saveTerminalKeyUsage());
  }

  Future<void> _saveTerminalKeyUsage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _terminalKeyUsageCountsKey,
      jsonEncode(_terminalKeyUseCounts),
    );
    _scheduleServerBackup();
  }

  void _activateTerminalKeyButton(String id, VoidCallback action) {
    _recordTerminalKeyUse(id);
    action();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    _hostController.text = prefs.getString('ssh_host') ?? '';
    _portController.text = prefs.getString('ssh_port') ?? '22';
    _usernameController.text = prefs.getString('ssh_username') ?? '';
    _usePrivateKey = prefs.getBool('ssh_use_private_key') ?? false;
    _privateKeyName = prefs.getString('ssh_private_key_name');
    _generatedPublicKey = await _storage.read(
      key: _generatedPublicKeyStorageKey,
    );
    _passwordController.text =
        await _storage.read(key: _passwordStorageKey) ?? '';
    _passphraseController.text =
        await _storage.read(key: _passphraseStorageKey) ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _saveProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ssh_host', _host);
    await prefs.setString('ssh_port', _port.toString());
    await prefs.setString('ssh_username', _username);
    await prefs.setBool('ssh_use_private_key', _usePrivateKey);
    if (_privateKeyName != null) {
      await prefs.setString('ssh_private_key_name', _privateKeyName!);
    }
    await _storage.write(
      key: _passwordStorageKey,
      value: _passwordController.text,
    );
    await _storage.write(
      key: _passphraseStorageKey,
      value: _passphraseController.text,
    );
    _scheduleServerBackup();
  }

  void _scheduleServerBackup() {
    _backupDebounce?.cancel();
    _backupDebounce = Timer(const Duration(seconds: 2), () {
      _saveBackupToServerSilently();
    });
  }

  Future<void> _saveBackupToServerSilently() async {
    try {
      if (!await BackupService.hasLocalRestorableData()) return;
      await BackupService.saveToServer(widget.dio, widget.serverUrl);
    } catch (_) {
      // Keep terminal edits local even when the server is unavailable.
    }
  }

  Future<void> _pickPrivateKey() async {
    final picked = await FilePicker.pickFiles(withData: true);
    final file = picked?.files.isNotEmpty == true ? picked!.files.first : null;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final pem = utf8.decode(bytes);
    await _storage.write(key: _privateKeyStorageKey, value: pem);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ssh_private_key_name', file.name);
    setState(() => _privateKeyName = file.name);
    _scheduleServerBackup();
  }

  String _publicKeyLine(SSHKeyPair keyPair) {
    final comment = keyPair is OpenSSHEd25519KeyPair
        ? keyPair.comment
        : 'devota-phone';
    return '${keyPair.name} ${base64.encode(keyPair.toPublicKey().encode())} $comment';
  }

  Future<void> _generateTerminalKey() async {
    setState(() {
      _busy = true;
      _status = 'Generating Ed25519 key...';
    });
    try {
      final signingKey = ed25519.SigningKey.generate();
      final comment =
          'devota-phone-${DateTime.now().toUtc().toIso8601String()}';
      final keyPair = OpenSSHEd25519KeyPair(
        Uint8List.fromList(signingKey.verifyKey.asTypedList),
        Uint8List.fromList(signingKey.asTypedList),
        comment,
      );
      final pem = keyPair.toPem();
      final publicKey = _publicKeyLine(keyPair);
      await _storage.write(key: _generatedPrivateKeyStorageKey, value: pem);
      await _storage.write(
        key: _generatedPublicKeyStorageKey,
        value: publicKey,
      );
      await _storage.write(key: _privateKeyStorageKey, value: pem);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ssh_use_private_key', true);
      await prefs.setString('ssh_private_key_name', 'DevOTA phone key');
      setState(() {
        _usePrivateKey = true;
        _privateKeyName = 'DevOTA phone key';
        _generatedPublicKey = publicKey;
        _status = 'Generated DevOTA phone key.';
      });
      _scheduleServerBackup();
    } catch (e) {
      setState(() => _status = 'Key generation failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _currentPrivateKeyPem() async {
    final profilePem = await _storage.read(key: _privateKeyStorageKey);
    if (profilePem != null && profilePem.trim().isNotEmpty) return profilePem;
    return _storage.read(key: _generatedPrivateKeyStorageKey);
  }

  Future<void> _copyPublicKey() async {
    final publicKey =
        _generatedPublicKey ??
        await _storage.read(key: _generatedPublicKeyStorageKey);
    if (publicKey == null || publicKey.trim().isEmpty) {
      setState(() => _status = 'Generate a key first.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: publicKey));
    setState(() => _status = 'Public key copied.');
  }

  Future<void> _sendPublicKeyToServer() async {
    final publicKey =
        _generatedPublicKey ??
        await _storage.read(key: _generatedPublicKeyStorageKey);
    if (publicKey == null || publicKey.trim().isEmpty) {
      setState(() => _status = 'Generate a key first.');
      return;
    }
    final baseUrl = widget.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      setState(() => _status = 'Select a build server first.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Sending public key to build server...';
    });
    try {
      final resp = await widget.dio.post(
        '$baseUrl/ssh/authorized-key',
        data: {'publicKey': publicKey, 'target': 'auto'},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final data = resp.data is Map
          ? Map<String, dynamic>.from(resp.data as Map)
          : const <String, dynamic>{};
      final target = data['target']?.toString() ?? 'server';
      final path = data['path']?.toString();
      final already = data['alreadyPresent'] == true;
      final approvalRequired = data['approvalRequired'] == true;
      final warnings = data['warnings'] is List
          ? (data['warnings'] as List).map((item) => item.toString()).toList()
          : const <String>[];
      final warningText = warnings.isEmpty ? '' : ' Warning: ${warnings.first}';
      setState(() {
        if (approvalRequired) {
          _status =
              'Windows administrator approval requested. Accept the Windows prompt, return here, then tap Connect.';
        } else {
          _status = already
              ? 'Public key was already installed on $target.$warningText'
              : 'Public key installed on $target${path == null ? '' : ' at $path'}.$warningText';
        }
      });
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        await _sendPublicKeyToServerClipboard(baseUrl, publicKey);
      } else {
        setState(() => _status = 'Public key push failed: ${_dioError(e)}');
      }
    } catch (e) {
      setState(() => _status = 'Public key push failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _dioError(DioException e) {
    final code = e.response?.statusCode;
    final reason = e.response?.statusMessage;
    if (code != null && reason != null && reason.trim().isNotEmpty) {
      return 'HTTP $code: $reason';
    }
    final data = e.response?.data;
    if (code != null && data != null) {
      final text = data
          .toString()
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isNotEmpty) {
        return 'HTTP $code: ${text.length > 180 ? '${text.substring(0, 180)}...' : text}';
      }
      return 'HTTP $code';
    }
    final message = e.message;
    if (message != null && message.trim().isNotEmpty) return message;
    return e.type.name;
  }

  Future<void> _sendPublicKeyToServerClipboard(
    String baseUrl,
    String publicKey,
  ) async {
    final resp = await widget.dio.post(
      '$baseUrl/clipboard',
      data: publicKey,
      options: Options(
        headers: {'Content-Type': 'text/plain; charset=utf-8'},
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    setState(() {
      _status = resp.statusCode == 200
          ? 'Public key sent to PC clipboard.'
          : 'Clipboard push returned HTTP ${resp.statusCode}.';
    });
  }

  Future<void> _ping() async {
    if (_host.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Pinging $_host:$_port...';
    });
    final started = DateTime.now();
    try {
      final addresses = await InternetAddress.lookup(
        _host,
      ).timeout(const Duration(seconds: 8));
      final address = addresses.first.address;
      final socket = await Socket.connect(
        address,
        _port,
        timeout: const Duration(seconds: 6),
      );
      socket.destroy();
      final ms = DateTime.now().difference(started).inMilliseconds;
      setState(() => _status = 'Reachable at $address:$_port in ${ms}ms');
    } catch (e) {
      setState(() => _status = 'Ping failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _verifyHostKey(String type, Uint8List fingerprintBytes) async {
    final fingerprint = utf8.decode(fingerprintBytes);
    final saved = await _storage.read(key: _hostKeyStorageKey);
    if (saved == fingerprint) return true;
    if (saved != null && saved != fingerprint) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Host key changed'),
            content: SelectableText('Saved: $saved\nNew: $fingerprint'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return false;
    }
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trust SSH host?'),
        content: SelectableText('$type\n$fingerprint'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Trust'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _storage.write(key: _hostKeyStorageKey, value: fingerprint);
      return true;
    }
    return false;
  }

  Future<void> _connect() async {
    if (_host.isEmpty || _username.isEmpty) {
      setState(() => _status = 'Host and username are required.');
      return;
    }
    await _saveProfile();
    setState(() {
      _busy = true;
      _status = 'Connecting...';
    });
    _terminal.write('\r\nConnecting to $_username@$_host:$_port...\r\n');
    try {
      List<SSHKeyPair>? identities;
      if (_usePrivateKey) {
        final pem = await _currentPrivateKeyPem();
        if (pem == null || pem.trim().isEmpty) {
          throw StateError('Import or generate a private key first.');
        }
        identities = SSHKeyPair.fromPem(
          pem,
          _passphraseController.text.isEmpty
              ? null
              : _passphraseController.text,
        );
      }
      final socket = await SSHSocket.connect(
        _host,
        _port,
        timeout: const Duration(seconds: 12),
      );
      final client = SSHClient(
        socket,
        username: _username,
        identities: identities,
        onPasswordRequest: _usePrivateKey
            ? null
            : () => _passwordController.text,
        onVerifyHostKey: _verifyHostKey,
      );
      await client.authenticated;
      final session = await client.shell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );
      _client = client;
      _session = session;
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      _stdoutSub = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(_terminal.write);
      _stderrSub = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(_terminal.write);
      session.done.whenComplete(() {
        if (!mounted) return;
        setState(() {
          _connected = false;
          _status = 'SSH session closed.';
        });
        _notifyMacroController();
      });
      setState(() {
        _connected = true;
        _status = 'Connected to $_host:$_port';
      });
      _notifyMacroController();
    } catch (e) {
      _terminal.write('Connection failed: $e\r\n');
      setState(() => _status = 'Connection failed: $e');
      _disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
      _notifyMacroController();
    }
  }

  Future<void> _disconnect() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    if (mounted) {
      setState(() {
        _connected = false;
        _macroRunning = false;
      });
    }
    _resetTerminalScrollGestures();
    _notifyMacroController();
  }

  void _writeToSession(String text) {
    if (!_connected) return;
    _session?.write(Uint8List.fromList(utf8.encode(text)));
  }

  void _focusTerminalInput() {
    _composerFocusNode.unfocus();
    void requestTerminalFocus() {
      if (!mounted || !_connected || _tmuxScrollMode) return;
      FocusScope.of(context).requestFocus(_terminalFocusNode);
      _terminalFocusNode.requestFocus();
      unawaited(
        SystemChannels.textInput.invokeMethod<void>(
          _nativeKeyboardLocked ? 'TextInput.hide' : 'TextInput.show',
        ),
      );
    }

    requestTerminalFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestTerminalFocus();
    });
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 90), () {
        requestTerminalFocus();
      }),
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        requestTerminalFocus();
      }),
    );
  }

  void _hideTerminalKeyboard() {
    _terminalFocusNode.unfocus();
    _composerFocusNode.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  void _sendTerminalKey(String sequence, {String? fallbackText}) {
    if (_connected) {
      _writeToSession(sequence);
      return;
    }
    if (fallbackText != null) _insertComposerText(fallbackText);
  }

  void _sendTmuxCommand(String command) {
    _sendTerminalKey('\x02$command');
  }

  void _enableTmuxMouse() {
    _sendTerminalKey('\x02:set -g mouse on\r');
    if (mounted) {
      setState(() => _status = 'tmux mouse enabled for this session.');
    }
  }

  void _enterTmuxScrollMode() {
    _sendTmuxCommand('[');
    _hideTerminalKeyboard();
    _resetTerminalScrollGestures();
    if (mounted) {
      setState(() {
        _tmuxScrollMode = true;
        _status = 'tmux scroll mode: tap Exit scroll or Esc to type again.';
      });
    }
  }

  void _exitTmuxScrollMode() {
    _sendTerminalKey('q');
    _resetTerminalScrollGestures();
    if (mounted) {
      setState(() {
        _tmuxScrollMode = false;
        _status = 'Exited tmux scroll mode.';
      });
    }
    _focusTerminalInput();
  }

  void _exitTmuxScrollModeWithEsc() {
    _sendTerminalKey('\x1B');
    _resetTerminalScrollGestures();
    if (mounted) {
      setState(() {
        _tmuxScrollMode = false;
        _status = 'Exited tmux scroll mode.';
      });
    }
    _focusTerminalInput();
  }

  void _insertComposerText(String text) {
    final selection = _composerController.selection;
    final value = _composerController.text;
    final start = selection.isValid ? selection.start : value.length;
    final end = selection.isValid ? selection.end : value.length;
    final next = value.replaceRange(start, end, text);
    _composerController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  void _submitComposer() {
    final text = _composerController.text.trim();
    if (text.isEmpty || !_connected) return;
    _submitTextToTerminal(text);
  }

  void _appendComposerText(String text) {
    if (text.trim().isEmpty) return;
    final existing = _composerController.text;
    _composerController.text = existing.isEmpty ? text : '$existing $text';
    _composerController.selection = TextSelection.fromPosition(
      TextPosition(offset: _composerController.text.length),
    );
  }

  void _prefixComposerText(String text) {
    final prefix = text.trim();
    if (prefix.isEmpty) return;
    final existing = _composerController.text.trimLeft();
    _composerController.text = existing.isEmpty ? prefix : '$prefix $existing';
    _composerController.selection = TextSelection.fromPosition(
      TextPosition(offset: _composerController.text.length),
    );
  }

  void _submitTextToTerminal(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_connected) return;
    _writeToSession('$trimmed\n');
    _composerController.clear();
    _focusTerminalInput();
  }

  void _runSavedCommand(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    widget.onCommandUsed?.call(trimmed);
    if (_composerController.text.trim().isNotEmpty) {
      _prefixComposerText(trimmed);
      setState(() => _status = 'Command prefix inserted.');
      _focusTerminalInput();
      return;
    }
    if (_connected) {
      _submitTextToTerminal(trimmed);
    } else {
      _appendComposerText(trimmed);
      setState(() => _status = 'Command inserted. Connect before submitting.');
    }
  }

  String? _macroTerminalKeySequence(String value) {
    return switch (value) {
      'enter' => '\r',
      'backspace' => '\x7F',
      'ctrl_b' => '\x02',
      'ctrl_c' => '\x03',
      'tab' => '\t',
      'esc' => '\x1B',
      'slash' => '/',
      '0' => '0',
      '1' => '1',
      '2' => '2',
      '3' => '3',
      '4' => '4',
      '5' => '5',
      '6' => '6',
      '7' => '7',
      '8' => '8',
      '9' => '9',
      'home' => '\x1B[H',
      'end' => '\x1B[F',
      'page_up' => '\x1B[5~',
      'page_down' => '\x1B[6~',
      'up' => '\x1B[A',
      'down' => '\x1B[B',
      'left' => '\x1B[D',
      'right' => '\x1B[C',
      _ => null,
    };
  }

  Future<void> _runMacro(TerminalMacro macro) async {
    if (!_connected) {
      setState(() => _status = 'Connect SSH before running macros.');
      throw StateError('Connect SSH before running macros.');
    }
    if (_macroRunning) {
      throw StateError('A macro is already running.');
    }
    widget.onMacroUsed?.call(macro);
    setState(() {
      _macroRunning = true;
      _status = 'Running macro: ${macro.name}';
    });
    _notifyMacroController();
    _focusTerminalInput();
    try {
      for (final step in macro.steps) {
        if (!_connected) throw StateError('SSH disconnected.');
        switch (step.type) {
          case TerminalMacroStepType.shell:
            final command = step.value.trimRight();
            if (command.isNotEmpty) _writeToSession('$command\n');
            break;
          case TerminalMacroStepType.terminalKey:
            final sequence = _macroTerminalKeySequence(step.value);
            if (sequence == null) {
              throw StateError('Unknown terminal key: ${step.value}');
            }
            _writeToSession(sequence);
            break;
          case TerminalMacroStepType.tmux:
            final sequence = terminalMacroTmuxSequence(step.value);
            if (sequence == null) {
              throw StateError('Unknown tmux command.');
            }
            _writeToSession(sequence);
            break;
          case TerminalMacroStepType.wait:
            break;
        }
        if (step.delaySeconds > 0) {
          await Future<void>.delayed(
            Duration(milliseconds: (step.delaySeconds * 1000).round()),
          );
        }
      }
      if (mounted) setState(() => _status = 'Macro complete: ${macro.name}');
    } catch (e) {
      if (mounted) setState(() => _status = 'Macro stopped: $e');
      rethrow;
    } finally {
      if (mounted) {
        setState(() => _macroRunning = false);
        _notifyMacroController();
        _focusTerminalInput();
      }
    }
  }

  Future<void> _attachFileToTerminal() async {
    if (_busy) return;
    final baseUrl = widget.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      setState(() => _status = 'Select a build server before attaching files.');
      return;
    }
    final picked = await FilePicker.pickFiles(withData: true);
    final file = picked?.files.isNotEmpty == true ? picked!.files.first : null;
    if (file == null) return;
    if (file.bytes == null && file.path == null) {
      setState(() => _status = 'Could not read selected file.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Uploading file to build server...';
    });
    try {
      final upload = file.bytes != null
          ? MultipartFile.fromBytes(file.bytes!, filename: file.name)
          : await MultipartFile.fromFile(file.path!, filename: file.name);
      final resp = await widget.dio.post(
        '$baseUrl/terminal/upload',
        data: FormData.fromMap({'file': upload}),
        options: Options(
          sendTimeout: const Duration(seconds: 45),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final data = resp.data is Map
          ? Map<String, dynamic>.from(resp.data as Map)
          : const <String, dynamic>{};
      final terminalText =
          data['terminalText']?.toString() ?? data['path']?.toString() ?? '';
      if (terminalText.isEmpty) {
        throw StateError('Server did not return an uploaded path.');
      }
      if (_connected) {
        _writeToSession(terminalText);
        _focusTerminalInput();
      } else {
        _appendComposerText(terminalText);
      }
      if (mounted) {
        setState(() => _status = 'File attached: $terminalText');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'File attach failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startVoiceRecording() async {
    var key = await _voice.loadApiKey();
    if (key == null || key.isEmpty) {
      key = await _promptApiKey();
      if (key == null || key.isEmpty) return;
    }
    final ok = await _voice.requestMicrophone();
    if (!ok) {
      setState(() => _status = 'Microphone permission required.');
      return;
    }
    await _voice.startRecording('terminal_voice.m4a');
    setState(() {
      _recording = true;
      _status = 'Recording voice input...';
    });
  }

  Future<void> _finishVoiceRecording() async {
    final path = await _voice.stopRecording();
    if (!mounted) {
      await VoiceInputService.deleteRecording(path);
      return;
    }
    setState(() {
      _recording = false;
      _transcribing = true;
      _status = 'Transcribing voice input...';
    });
    try {
      final key = await _voice.loadApiKey();
      if (key == null || key.isEmpty) return;
      final text = path == null ? '' : await _voice.transcribe(path, key);
      if (text.isEmpty) return;
      _appendComposerText(text);
      _composerFocusNode.requestFocus();
      if (mounted) setState(() => _status = 'Transcript added.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Transcription failed: $e');
    } finally {
      await VoiceInputService.deleteRecording(path);
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<String?> _promptApiKey() async {
    final initialValue = await _voice.loadApiKey() ?? '';
    if (!mounted) return null;
    final key = await OpenAiKeyDialog.show(context, initialValue: initialValue);
    if (key != null && key.isNotEmpty) {
      await _voice.saveApiKey(key);
      _scheduleServerBackup();
    }
    return key;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return SafeArea(
      top: widget.fullscreen,
      child: Column(
        children: [
          _buildConnectionPanel(theme),
          Expanded(
            child: Listener(
              onPointerMove: _handleTerminalPointerMove,
              onPointerSignal: _handleTerminalPointerSignal,
              child: Container(
                color: Colors.black,
                child: AbsorbPointer(
                  absorbing: _tmuxScrollMode,
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    focusNode: _terminalFocusNode,
                    scrollController: _terminalScrollController,
                    textStyle: TerminalStyle(fontSize: _terminalFontSize),
                    autofocus: true,
                    readOnly: _tmuxScrollMode,
                    hardwareKeyboardOnly: _nativeKeyboardLocked,
                  ),
                ),
              ),
            ),
          ),
          _buildTerminalToolsHeader(theme),
          if (_terminalToolsVisible) ...[
            _buildTerminalControlPad(theme),
            _buildTmuxKeyBar(theme),
            if (widget.quickMacros.isNotEmpty) _buildMacroBar(theme),
            if (widget.quickCommands.isNotEmpty) _buildSavedCommandBar(theme),
          ],
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildConnectionPanel(ThemeData theme) {
    final connectionLabel = _host.isEmpty
        ? 'No SSH host saved'
        : '${_username.isEmpty ? 'user' : _username}@$_host:$_port';
    final subtitle = _status ?? connectionLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 1,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                _connected ? Icons.link : Icons.link_off,
                size: 20,
                color: _connected ? theme.colorScheme.primary : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _connected ? 'SSH connected' : connectionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _terminalPanelIconButton(
                icon: Icon(_connected ? Icons.link_off : Icons.link),
                tooltip: _connected ? 'Disconnect' : 'Connect',
                onPressed: _busy ? null : (_connected ? _disconnect : _connect),
              ),
              _buildTerminalFontControls(theme),
              _terminalPanelIconButton(
                icon: Icon(
                  _nativeKeyboardLocked ? Icons.keyboard_hide : Icons.keyboard,
                ),
                tooltip: _nativeKeyboardLocked
                    ? 'Native keyboard locked off'
                    : 'Native keyboard allowed',
                selected: _nativeKeyboardLocked,
                onPressed: () =>
                    _setNativeKeyboardLocked(!_nativeKeyboardLocked),
              ),
              _terminalPanelIconButton(
                icon: Icon(
                  widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
                tooltip: widget.fullscreen
                    ? 'Show DevOTA tabs'
                    : 'Hide DevOTA tabs',
                selected: widget.fullscreen,
                onPressed: widget.onFullscreenChanged == null
                    ? null
                    : () => widget.onFullscreenChanged!(!widget.fullscreen),
              ),
              _terminalPanelIconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'SSH settings',
                onPressed: _showConnectionSheet,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _terminalPanelIconButton({
    required Widget icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool selected = false,
  }) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          fixedSize: const Size(34, 34),
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: selected
              ? theme.colorScheme.secondaryContainer
              : null,
          foregroundColor: selected
              ? theme.colorScheme.onSecondaryContainer
              : null,
        ),
        icon: icon,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildTerminalFontControls(ThemeData theme) {
    final borderColor = theme.colorScheme.outlineVariant;
    return Container(
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fontControlButton(
            icon: Icons.zoom_in,
            tooltip: 'Increase terminal font',
            onPressed: () => _adjustTerminalFontSize(1.1),
          ),
          _fontControlDivider(borderColor),
          Tooltip(
            message: 'Reset terminal font',
            child: InkWell(
              onTap: _resetTerminalFontSize,
              child: SizedBox(
                width: 34,
                height: 32,
                child: Center(
                  child: Text(
                    _terminalFontSize.round().toString(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _fontControlDivider(borderColor),
          _fontControlButton(
            icon: Icons.zoom_out,
            tooltip: 'Decrease terminal font',
            onPressed: () => _adjustTerminalFontSize(1 / 1.1),
          ),
        ],
      ),
    );
  }

  Widget _fontControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(width: 32, height: 32, child: Icon(icon, size: 18)),
      ),
    );
  }

  Widget _fontControlDivider(Color color) {
    return SizedBox(width: 1, height: 20, child: ColoredBox(color: color));
  }

  Future<void> _showConnectionSheet() async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
            return Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottomInset),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'SSH Settings',
                          style: theme.textTheme.titleMedium,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _field(_hostController, 'Host')),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 86,
                          child: _field(
                            _portController,
                            'Port',
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _field(_usernameController, 'User'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _usePrivateKey
                              ? TextField(
                                  controller: _passphraseController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Key passphrase',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (_) => _saveProfile(),
                                )
                              : TextField(
                                  controller: _passwordController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Password',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (_) => _saveProfile(),
                                ),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('Key'),
                          selected: _usePrivateKey,
                          onSelected: (v) {
                            setState(() => _usePrivateKey = v);
                            setSheetState(() {});
                            _saveProfile();
                          },
                        ),
                        const SizedBox(width: 4),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.key),
                          tooltip: _privateKeyName ?? 'Import private key',
                          onPressed: _pickPrivateKey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          icon: Icon(_connected ? Icons.link_off : Icons.link),
                          label: Text(_connected ? 'Disconnect' : 'Connect'),
                          onPressed: _busy
                              ? null
                              : (_connected ? _disconnect : _connect),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.network_ping),
                          label: const Text('Ping'),
                          onPressed: _busy ? null : _ping,
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Key'),
                          onPressed: _busy ? null : _generateTerminalKey,
                        ),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.copy),
                          tooltip: 'Copy generated public key',
                          onPressed: _generatedPublicKey == null
                              ? null
                              : _copyPublicKey,
                        ),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.upload),
                          tooltip: 'Install public key through build server',
                          onPressed: _busy || _generatedPublicKey == null
                              ? null
                              : _sendPublicKeyToServer,
                        ),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.key),
                          tooltip: 'Set OpenAI key',
                          onPressed: _promptApiKey,
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
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  Widget _buildTerminalToolsHeader(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: InkWell(
        onTap: _toggleTerminalTools,
        child: SizedBox(
          height: 34,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(
                  _terminalToolsVisible
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Text(
                  'Tools',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _terminalToolsVisible
                        ? 'Terminal, tmux, macros, commands'
                        : 'Tap to show terminal controls',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_tmuxScrollMode)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _exitTmuxScrollMode,
                    child: const Text('Exit scroll'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTerminalControlPad(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            _buildArrowCluster(),
            const SizedBox(width: 6),
            Expanded(
              child: SizedBox(
                height: 64,
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          _terminalGridButton(
                            'tab',
                            'Tab',
                            () => _sendTerminalKey('\t'),
                          ),
                          _terminalGridGap(),
                          _terminalGridButton('esc', 'Esc', () {
                            if (_tmuxScrollMode) {
                              _exitTmuxScrollModeWithEsc();
                            } else {
                              _sendTerminalKey('\x1B');
                            }
                          }),
                          _terminalGridGap(),
                          _terminalGridButton(
                            'ctrl_c',
                            'C-c',
                            () => _sendTerminalKey('\x03'),
                            tooltip: 'Ctrl-C',
                          ),
                          _terminalGridGap(),
                          _terminalGridButton(
                            'slash',
                            '/',
                            () => _sendTerminalKey('/', fallbackText: '/'),
                            enabledWhenDisconnected: true,
                          ),
                          _terminalGridGap(),
                          _terminalGridIconButton(
                            'attach_file',
                            Icons.add,
                            'Attach file',
                            () => unawaited(_attachFileToTerminal()),
                            enabledWhenDisconnected: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Row(
                        children: [
                          _terminalGridButton(
                            'home',
                            'Home',
                            () => _sendTerminalKey('\x1B[H'),
                          ),
                          _terminalGridGap(),
                          _terminalGridButton(
                            'end',
                            'End',
                            () => _sendTerminalKey('\x1B[F'),
                          ),
                          _terminalGridGap(),
                          _terminalGridButton(
                            'page_up',
                            'PgUp',
                            () => _sendTerminalKey('\x1B[5~'),
                          ),
                          _terminalGridGap(),
                          _terminalGridButton(
                            'page_down',
                            'PgDn',
                            () => _sendTerminalKey('\x1B[6~'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            _terminalActionKeyColumn(),
          ],
        ),
      ),
    );
  }

  Widget _buildArrowCluster() {
    return SizedBox(
      width: 94,
      height: 64,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: _terminalArrowButton(
              'up',
              Icons.keyboard_arrow_up,
              'Up',
              '\x1B[A',
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: _terminalArrowButton(
              'left',
              Icons.keyboard_arrow_left,
              'Left',
              '\x1B[D',
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _terminalArrowButton(
              'down',
              Icons.keyboard_arrow_down,
              'Down',
              '\x1B[B',
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: _terminalArrowButton(
              'right',
              Icons.keyboard_arrow_right,
              'Right',
              '\x1B[C',
            ),
          ),
        ],
      ),
    );
  }

  Widget _terminalArrowButton(
    String usageId,
    IconData icon,
    String tooltip,
    String sequence,
  ) {
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          fixedSize: const Size(30, 30),
          minimumSize: const Size(30, 30),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 20),
        onPressed: _connected
            ? () => _activateTerminalKeyButton(
                usageId,
                () => _sendTerminalKey(sequence),
              )
            : null,
      ),
    );
  }

  Widget _terminalGridGap() => const SizedBox(width: 4);

  Widget _terminalGridButton(
    String usageId,
    String label,
    VoidCallback onPressed, {
    String? tooltip,
    bool enabledWhenDisconnected = false,
  }) {
    final enabled = _connected || enabledWhenDisconnected;
    final button = OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: enabled
          ? () => _activateTerminalKeyButton(usageId, onPressed)
          : null,
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
    );
    return Expanded(
      child: SizedBox.expand(
        child: tooltip == null
            ? button
            : Tooltip(message: tooltip, child: button),
      ),
    );
  }

  Widget _terminalGridIconButton(
    String usageId,
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    bool enabledWhenDisconnected = false,
  }) {
    final enabled = _connected || enabledWhenDisconnected;
    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: SizedBox.expand(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: Size.zero,
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: enabled
                ? () => _activateTerminalKeyButton(usageId, onPressed)
                : null,
            child: Icon(icon, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _terminalActionKeyColumn() {
    return SizedBox(
      width: 30,
      height: 64,
      child: Column(
        children: [
          _terminalActionKeyButton(
            'backspace',
            Icons.backspace_outlined,
            'Backspace',
            '\x7F',
          ),
          const SizedBox(height: 4),
          _terminalActionKeyButton(
            'enter',
            Icons.keyboard_return,
            'Enter',
            '\r',
          ),
        ],
      ),
    );
  }

  Widget _terminalActionKeyButton(
    String usageId,
    IconData icon,
    String tooltip,
    String sequence,
  ) {
    final enabled = _connected;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: SizedBox(
          width: 30,
          height: 30,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: enabled
                ? () => _activateTerminalKeyButton(
                    usageId,
                    () => _sendTerminalKey(sequence),
                  )
                : null,
            child: Icon(icon, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _buildTmuxKeyBar(ThemeData theme) {
    var index = 0;
    _TerminalKeyBarItem item(String id, Widget Function() build) {
      return _TerminalKeyBarItem(
        originalIndex: index++,
        useCount: _terminalKeyUseCounts[id] ?? 0,
        build: build,
      );
    }

    final items = <_TerminalKeyBarItem>[
      item(
        'tmux_prefix',
        () => _terminalKeyButton(
          'tmux_prefix',
          'Prefix',
          () => _sendTmuxCommand('\x02'),
          tooltip: 'tmux send prefix',
        ),
      ),
      item(
        'tmux_new',
        () => _terminalKeyButton(
          'tmux_new',
          'New',
          () => _sendTmuxCommand('c'),
          tooltip: 'tmux new window',
        ),
      ),
      item(
        'tmux_prev',
        () => _terminalKeyButton(
          'tmux_prev',
          'Prev',
          () => _sendTmuxCommand('p'),
          tooltip: 'tmux previous window',
        ),
      ),
      item(
        'tmux_next',
        () => _terminalKeyButton(
          'tmux_next',
          'Next',
          () => _sendTmuxCommand('n'),
          tooltip: 'tmux next window',
        ),
      ),
      item(
        'tmux_list',
        () => _terminalKeyButton(
          'tmux_list',
          'List',
          () => _sendTmuxCommand('w'),
          tooltip: 'tmux window list',
        ),
      ),
      item(
        'tmux_scroll',
        () => _tmuxScrollMode
            ? _terminalKeyButton(
                'tmux_scroll',
                'Exit scroll',
                _exitTmuxScrollMode,
                tooltip: 'Exit tmux copy/scroll mode',
              )
            : _terminalKeyButton(
                'tmux_scroll',
                'Scroll',
                _enterTmuxScrollMode,
                tooltip: 'tmux copy/scroll mode',
              ),
      ),
      item(
        'tmux_mouse',
        () => _terminalKeyButton(
          'tmux_mouse',
          'Mouse',
          _enableTmuxMouse,
          tooltip: 'tmux mouse on',
        ),
      ),
      item(
        'tmux_split_vertical',
        () => _terminalKeyButton(
          'tmux_split_vertical',
          'Split |',
          () => _sendTmuxCommand('%'),
          tooltip: 'tmux split pane side by side',
        ),
      ),
      item(
        'tmux_split_horizontal',
        () => _terminalKeyButton(
          'tmux_split_horizontal',
          'Split -',
          () => _sendTmuxCommand('"'),
          tooltip: 'tmux split pane top and bottom',
        ),
      ),
      item(
        'tmux_detach',
        () => _terminalKeyButton(
          'tmux_detach',
          'Detach',
          () => _sendTmuxCommand('d'),
          tooltip: 'tmux detach session',
        ),
      ),
    ];

    items.sort((a, b) {
      final usage = b.useCount.compareTo(a.useCount);
      if (usage != 0) return usage;
      return a.originalIndex.compareTo(b.originalIndex);
    });

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            _terminalKeyGroupLabel(theme, 'tmux'),
            for (final item in items) item.build(),
          ],
        ),
      ),
    );
  }

  Widget _terminalKeyGroupLabel(ThemeData theme, String label) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 10),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildSavedCommandBar(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            _terminalKeyGroupLabel(theme, 'cmds'),
            for (final command in widget.quickCommands)
              _terminalCommandButton(command),
          ],
        ),
      ),
    );
  }

  Widget _buildMacroBar(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            _terminalKeyGroupLabel(theme, 'macros'),
            for (final macro in widget.quickMacros) _terminalMacroButton(macro),
          ],
        ),
      ),
    );
  }

  Widget _terminalMacroButton(TerminalMacro macro) {
    final enabled = _connected && !_macroRunning;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: macro.name,
        child: SizedBox(
          height: 32,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: _macroRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow, size: 16),
            onPressed: enabled
                ? () => unawaited(_runMacro(macro).catchError((Object _) {}))
                : null,
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                macro.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _terminalCommandButton(String command) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: command,
        child: SizedBox(
          height: 32,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.keyboard_return, size: 16),
            onPressed: () => _runSavedCommand(command),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                command,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _terminalKeyButton(
    String usageId,
    String label,
    VoidCallback onPressed, {
    String? tooltip,
    bool enabledWhenDisconnected = false,
  }) {
    final enabled = _connected || enabledWhenDisconnected;
    final button = SizedBox(
      height: 32,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: enabled
            ? () => _activateTerminalKeyButton(usageId, onPressed)
            : null,
        child: Text(label),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: tooltip == null
          ? button
          : Tooltip(message: tooltip, child: button),
    );
  }

  Widget _buildComposer() {
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composerController,
                      focusNode: _composerFocusNode,
                      decoration: const InputDecoration(
                        hintText: 'Type command',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      maxLines: 1,
                      autocorrect: false,
                      enableSuggestions: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      textCapitalization: TextCapitalization.none,
                      textInputAction: TextInputAction.send,
                      readOnly: _nativeKeyboardLocked,
                      showCursor: !_nativeKeyboardLocked,
                      keyboardType: _nativeKeyboardLocked
                          ? TextInputType.none
                          : TextInputType.text,
                      onTap: _nativeKeyboardLocked
                          ? () {
                              _composerFocusNode.unfocus();
                              FocusScope.of(
                                context,
                              ).requestFocus(_terminalFocusNode);
                              unawaited(
                                SystemChannels.textInput.invokeMethod<void>(
                                  'TextInput.hide',
                                ),
                              );
                            }
                          : null,
                      onSubmitted: (_) => _submitComposer(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    icon: Icon(_recording ? Icons.stop : Icons.mic),
                    tooltip: _recording ? 'Stop recording' : 'Voice input',
                    style: _recording
                        ? IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.errorContainer,
                            foregroundColor: theme.colorScheme.onErrorContainer,
                          )
                        : null,
                    onPressed: _transcribing
                        ? null
                        : (_recording
                              ? _finishVoiceRecording
                              : _startVoiceRecording),
                  ),
                  const SizedBox(width: 2),
                  IconButton.filled(
                    icon: _transcribing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    tooltip: 'Submit to SSH',
                    onPressed: _connected && !_transcribing && !_recording
                        ? _submitComposer
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: keyboardType,
      onChanged: (_) => _saveProfile(),
    );
  }
}
