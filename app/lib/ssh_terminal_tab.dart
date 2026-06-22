import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'voice_input_service.dart';

class SshTerminalTab extends StatefulWidget {
  const SshTerminalTab({super.key, required this.dio});

  final Dio dio;

  @override
  State<SshTerminalTab> createState() => _SshTerminalTabState();
}

class _SshTerminalTabState extends State<SshTerminalTab> {
  final _storage = const FlutterSecureStorage();
  late final _voice = VoiceInputService(widget.dio);
  late final _terminal = Terminal(maxLines: 10000);
  final _terminalController = TerminalController();

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
  String? _status;
  String? _privateKeyName;

  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  @override
  void initState() {
    super.initState();
    _terminal.write('DevOTA SSH terminal\r\n');
    _terminal.onOutput = (data) =>
        _session?.write(Uint8List.fromList(utf8.encode(data)));
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _session?.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };
    _loadProfile();
  }

  @override
  void dispose() {
    _disconnect();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _passphraseController.dispose();
    _composerController.dispose();
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _voice.dispose();
    super.dispose();
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

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    _hostController.text = prefs.getString('ssh_host') ?? '';
    _portController.text = prefs.getString('ssh_port') ?? '22';
    _usernameController.text = prefs.getString('ssh_username') ?? '';
    _usePrivateKey = prefs.getBool('ssh_use_private_key') ?? false;
    _privateKeyName = prefs.getString('ssh_private_key_name');
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
        final pem = await _storage.read(key: _privateKeyStorageKey);
        if (pem == null || pem.trim().isEmpty) {
          throw StateError('Import a private key first.');
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
      });
      setState(() {
        _connected = true;
        _status = 'Connected to $_host:$_port';
      });
    } catch (e) {
      _terminal.write('Connection failed: $e\r\n');
      setState(() => _status = 'Connection failed: $e');
      _disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
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
    if (mounted) setState(() => _connected = false);
  }

  void _submitComposer() {
    final text = _composerController.text.trim();
    if (text.isEmpty || !_connected) return;
    _session?.write(Uint8List.fromList(utf8.encode('$text\n')));
    _composerController.clear();
  }

  Future<void> _toggleVoice() async {
    if (_recording) {
      final path = await _voice.stopRecording();
      setState(() {
        _recording = false;
        _transcribing = true;
      });
      try {
        final key = await _voice.loadApiKey();
        if (key == null || key.isEmpty) return;
        final text = path == null ? '' : await _voice.transcribe(path, key);
        if (text.isNotEmpty) {
          final existing = _composerController.text;
          _composerController.text = existing.isEmpty
              ? text
              : '$existing $text';
          _composerController.selection = TextSelection.fromPosition(
            TextPosition(offset: _composerController.text.length),
          );
        }
      } catch (e) {
        if (mounted) setState(() => _status = 'Transcription failed: $e');
      } finally {
        await VoiceInputService.deleteRecording(path);
        if (mounted) setState(() => _transcribing = false);
      }
      return;
    }
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
    setState(() => _recording = true);
  }

  Future<String?> _promptApiKey() async {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Column(
            children: [
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
                  const SizedBox(width: 8),
                  Expanded(child: _field(_usernameController, 'User')),
                ],
              ),
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
                          )
                        : TextField(
                            controller: _passwordController,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Password',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Key'),
                    selected: _usePrivateKey,
                    onSelected: (v) => setState(() => _usePrivateKey = v),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.key),
                    tooltip: _privateKeyName ?? 'Import private key',
                    onPressed: _pickPrivateKey,
                  ),
                ],
              ),
              const SizedBox(height: 8),
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
                  IconButton.filledTonal(
                    icon: const Icon(Icons.key),
                    tooltip: 'Set OpenAI key',
                    onPressed: _promptApiKey,
                  ),
                ],
              ),
              if (_status != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _status!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: Colors.black,
            child: TerminalView(
              _terminal,
              controller: _terminalController,
              autofocus: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _composerController,
                  decoration: const InputDecoration(
                    hintText: 'Speak or type a terminal command...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  minLines: 1,
                  maxLines: 3,
                  onSubmitted: (_) => _submitComposer(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: Icon(
                  _recording ? Icons.stop : Icons.mic,
                  color: _recording ? Colors.red : null,
                ),
                tooltip: _recording ? 'Stop recording' : 'Voice input',
                onPressed: _transcribing ? null : _toggleVoice,
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                icon: _transcribing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                tooltip: 'Submit to SSH',
                onPressed: _connected && !_transcribing
                    ? _submitComposer
                    : null,
              ),
            ],
          ),
        ),
      ],
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
