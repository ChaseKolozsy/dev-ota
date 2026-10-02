import 'dart:convert';
import 'dart:typed_data';

import 'package:devota/macro_sync_service.dart';
import 'package:devota/terminal_macro.dart';
import 'package:devota/terminal_watch.dart';
import 'package:devota/ssh_terminal_tab.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ResolverAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final macro = Map<String, dynamic>.from(options.data['macro'] as Map);
    final steps = (macro['steps'] as List).cast<Map>();
    for (final step in steps) {
      step['value'] = step['value'].toString().replaceAll(
        '{{devota:ceb-primer:forward}}',
        '[{"topic":"semana","rank":172}]',
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'item': macro}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

TerminalMacro queueMacro() => const TerminalMacro(
  id: 'm',
  name: 'CEB',
  steps: [
    TerminalMacroStep(
      id: 'clear',
      type: TerminalMacroStepType.shell,
      value: '/clear',
      delaySeconds: 0,
    ),
    TerminalMacroStep(
      id: 'prompt',
      type: TerminalMacroStepType.shell,
      value: 'Assigned: {{devota:ceb-primer:forward}}',
      delaySeconds: 0,
    ),
  ],
);

void main() {
  test('all authoring markers require preparation', () {
    for (final family in [
      'creative-full',
      'creative-rank',
      'primer-commentary',
      'ogden-commentary',
    ]) {
      final macro = queueMacro().copyWith(
        steps: [
          TerminalMacroStep(
            id: 'prompt',
            type: TerminalMacroStepType.shell,
            value: '{{devota:cradle:en:$family:forward}}',
            delaySeconds: 0,
          ),
        ],
      );
      expect(macro.needsQueueRoster, isTrue);
    }
  });

  testWidgets('terminal resolves before clearing or typing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final adapter = ResolverAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final controller = TerminalMacroController();
    final writes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshTerminalTab(
            dio: dio,
            serverUrl: 'http://devota',
            macroController: controller,
            testHooks: SshTerminalTestHooks(sessionSink: writes.add),
          ),
        ),
      ),
    );
    await tester.pump();
    final run = controller.run(queueMacro());
    await tester.pumpAndSettle();
    await run;
    expect(adapter.requests, hasLength(1));
    expect(writes.join(), contains('semana'));
    expect(writes.join(), isNot(contains('{{devota:')));
    expect(
      writes.join().indexOf('/clear'),
      lessThan(writes.join().indexOf('semana')),
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('terminal queue failure sends no clear or prompt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = TerminalMacroController();
    final writes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshTerminalTab(
            dio: Dio(),
            serverUrl: '',
            macroController: controller,
            testHooks: SshTerminalTestHooks(sessionSink: writes.add),
          ),
        ),
      ),
    );
    await tester.pump();
    await expectLater(controller.run(queueMacro()), throwsStateError);
    await tester.pump(const Duration(milliseconds: 300));
    expect(writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('resolve on every run without changing the saved macro', () async {
    final adapter = ResolverAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final macro = queueMacro();
    for (var i = 0; i < 2; i++) {
      final resolved = await MacroSyncService.resolveForRun(
        dio,
        'http://devota',
        macro,
      );
      expect(resolved.needsQueueRoster, isFalse);
      expect(resolved.steps.last.value, contains('semana'));
    }
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.path, 'http://devota/macros/resolve');
    expect(macro.needsQueueRoster, isTrue);
    final staticMacro = macro.copyWith(steps: [macro.steps.first]);
    expect(
      await MacroSyncService.resolveForRun(dio, '', staticMacro),
      same(staticMacro),
    );
    expect(adapter.requests, hasLength(2));
  });

  for (final fail in [false, true]) {
    test(
      'watch ${fail ? "failure sends nothing" : "pastes expanded roster"}',
      () async {
        var time = DateTime(2026);
        const pane = WatchedPane(
          id: '%1',
          identity: '1:2:3',
          label: 'test:1.0',
          window: '1',
        );
        final binding = TerminalWatchBinding(pane: pane, macroId: 'm');
        final commands = <String>[];
        final watch = TerminalWatchController(now: () => time)
          ..reviewEnabled = false;
        addTearDown(watch.dispose);
        watch.configure([binding], [queueMacro()]);
        watch.connect(
          TmuxWatchTransport((command) async {
            commands.add(command);
            return 'Ready';
          }),
        );
        await watch.poll();
        for (var i = 0; i < 2; i++) {
          time = time.add(const Duration(seconds: 6));
          await watch.poll();
        }
        watch.resolveMacro = (macro) async {
          if (fail) throw StateError('Queue unavailable');
          return macro.copyWith(
            steps: macro.steps
                .map(
                  (s) => s.copyWith(
                    value: s.value.replaceAll(
                      '{{devota:ceb-primer:forward}}',
                      '[{"topic":"semana","rank":172}]',
                    ),
                  ),
                )
                .toList(),
          );
        };
        await watch.act(pane.id, 'run', watch.token(binding));
        final writes = commands
            .where((c) => c.contains('paste-buffer') || c.contains('send-keys'))
            .toList();
        if (fail) {
          expect(writes, isEmpty);
          expect(
            watch.observations[pane.id]!.runError,
            contains('Queue unavailable'),
          );
        } else {
          expect(writes, hasLength(4));
          final encoded = base64Encode(
            utf8.encode('Assigned: [{"topic":"semana","rank":172}]'),
          );
          expect(writes.any((c) => c.contains(encoded)), isTrue);
        }
      },
    );
  }
}
