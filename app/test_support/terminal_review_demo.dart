// Emulator-only notification/status fixture. No SSH, agents or model calls.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:devota/background_session_service.dart';
import 'package:devota/terminal_macro.dart';
import 'package:devota/terminal_notification_bridge.dart';
import 'package:devota/terminal_watch.dart';

void main() => runApp(const MaterialApp(home: ReviewDemo()));

class ReviewDemo extends StatefulWidget {
  const ReviewDemo({super.key});
  @override
  State<ReviewDemo> createState() => _ReviewDemoState();
}

class _ReviewDemoState extends State<ReviewDemo> {
  final watch = TerminalWatchController(
    quietPeriod: const Duration(seconds: 5),
  );
  late final bridge = TerminalNotificationBridge(watch);
  final calls = <int, int>{};
  bool started = false;
  final sources = [
    'Final answer one: All requested work completed. All tests passed.',
    'Final answer two: Tests failed. Required work remains blocked.',
    'Third window: still working, no final conclusion.',
  ];

  Future<void> start() async {
    if (started) return;
    started = true;
    bridge.publish();
    watch.addListener(_changed);
    watch.configure(
      [
        for (var i = 0; i < 3; i++)
          TerminalWatchBinding(
            pane: WatchedPane(
              id: '%$i',
              identity: 'fixture$i',
              label: 'Review ${i + 1}',
              window: '$i',
            ),
            macroId: 'hello',
          ),
      ],
      [const TerminalMacro(id: 'hello', name: 'Fixture', steps: [])],
    );
    await BackgroundSessionService.start('Synthetic review test');
    watch.connect(
      TmuxWatchTransport(
        (command) async {
          if (!command.contains('capture-pane')) {
            throw StateError('Fixture is read-only');
          }
          final index = int.parse(
            RegExp(r"-t '%([0-2])'").firstMatch(command)![1]!,
          );
          return sources[index];
        },
        reviewer: (source) async {
          final index = sources.indexOf(source);
          calls[index] = (calls[index] ?? 0) + 1;
          if (index == 0 && calls[index] == 1) {
            throw StateError('Synthetic busy checker');
          }
          return jsonEncode({
            'status': [
              'reported_success',
              'needs_attention',
              'uncertain',
            ][index],
            'reason': [
              'Reports completion.',
              'Reports failed tests.',
              'No final conclusion.',
            ][index],
            'evidence': index == 2 ? '' : source,
          });
        },
      ),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    bridge.dispose();
    watch.removeListener(_changed);
    watch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Synthetic outcome fixture')),
    body: ListView(
      children: [
        FilledButton(onPressed: start, child: const Text('Start outcome test')),
        Text(
          'Review calls: ${calls[0] ?? 0}, ${calls[1] ?? 0}, ${calls[2] ?? 0}',
        ),
        for (final card in watch.cards)
          ListTile(
            title: Text('${card['title']}'),
            subtitle: Text('${card['status']}'),
          ),
      ],
    ),
  );
}
