// Emulator-only entry point. Uses a loopback SSH fixture and real Vim panes;
// never connects to agents, production hosts, or the user's macro store.
import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:devota/background_session_service.dart';
import 'package:devota/ssh_watch_transport.dart';
import 'package:devota/terminal_macro.dart';
import 'package:devota/terminal_notification_bridge.dart';
import 'package:devota/terminal_watch.dart';

void main() => runApp(const MaterialApp(home: Demo()));

class Demo extends StatefulWidget {
  const Demo({super.key});
  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  final watch = TerminalWatchController(
    quietPeriod: const Duration(seconds: 5),
  );
  late final bridge = TerminalNotificationBridge(watch);
  SSHClient? client;
  String status = 'Ready to connect to local Vim fixture';
  @override
  void initState() {
    super.initState();
    watch.reviewEnabled = false; // Live model is tested separately on synthetic prose.
    bridge.publish();
    watch.addListener(_update);
  }

  void _update() {
    if (mounted) setState(() {});
  }

  Future<void> start() async {
    try {
      client?.close();
      final connection = SSHClient(
        await SSHSocket.connect('127.0.0.1', 22222),
        username: 'fixture',
        onPasswordRequest: () => 'fixture-only',
      );
      client = connection;
      await connection.authenticated;
      final transport = sshWatchTransport(connection);
      final panes = await transport.panes();
      if (panes.length != 3) {
        throw StateError('Expected exactly three isolated Vim panes');
      }
      final macros = [
        for (var i = 0; i < panes.length; i++)
          TerminalMacro(
            id: 'hello-$i',
            name: 'Hello ${i + 1}',
            steps: [
              TerminalMacroStep(
                id: 'text',
                type: TerminalMacroStepType.shell,
                value: ":call append('\$', 'hello ${i + 1}')",
                delaySeconds: 0,
              ),
              const TerminalMacroStep(
                id: 'enter',
                type: TerminalMacroStepType.terminalKey,
                value: 'enter',
                delaySeconds: 0.3,
              ),
              const TerminalMacroStep(
                id: 'write',
                type: TerminalMacroStepType.shell,
                value: ':w',
                delaySeconds: 0,
              ),
            ],
          ),
      ];
      watch.configure([
        for (var i = 0; i < panes.length; i++)
          TerminalWatchBinding(pane: panes[i], macroId: macros[i].id),
      ], macros);
      await BackgroundSessionService.start('Vim notification test');
      watch.connect(transport);
      connection.done.whenComplete(() {
        if (mounted) watch.connect(null);
      });
      setState(() => status = 'Connected to three Vim windows');
    } catch (e) {
      setState(() => status = '$e');
    }
  }

  @override
  void dispose() {
    bridge.dispose();
    watch.dispose();
    client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Terminal notification fixture')),
    body: ListView(
      children: [
        Text(status),
        FilledButton(onPressed: start, child: const Text('Start Vim test')),
        for (final card in watch.cards)
          ListTile(
            title: Text('${card['title']}'),
            subtitle: Text('${card['status']}'),
          ),
      ],
    ),
  );
}
