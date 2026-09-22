import 'dart:convert';
import 'dart:async';
import 'package:devota/terminal_conclusion.dart';
import 'package:devota/terminal_watch.dart';
import 'package:devota/terminal_macro.dart';
import 'package:flutter_test/flutter_test.dart';

class Fixture {
  DateTime time = DateTime(2026);
  String screen = 'Final answer: All tests passed.';
  late final watch = TerminalWatchController(now: () => time);
  Fixture(Future<String> Function(String) reviewer, {int panes = 1}) {
    watch.configure(
      [
        for (var i = 1; i <= panes; i++)
          TerminalWatchBinding(
            pane: WatchedPane(
              id: '%$i',
              identity: 'id$i',
              label: 'Window $i',
              window: '$i',
            ),
            macroId: 'm',
          ),
      ],
      [const TerminalMacro(id: 'm', name: 'Hello', steps: [])],
    );
    watch.connect(TmuxWatchTransport((_) async => screen, reviewer: reviewer));
  }
  Future<void> tick([int seconds = 5]) async {
    time = time.add(Duration(seconds: seconds));
    await watch.poll();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> settle() async {
    await tick(0);
    await tick();
    await tick();
  }
}

String success(String source) => jsonEncode({
  'status': 'reported_success',
  'reason': 'Reports passing tests.',
  'evidence': source,
});

void main() {
  test('late retry verdict is discarded after new output', () async {
    final pending = Completer<String>();
    var calls = 0;
    final fixture = Fixture((source) async {
      if (++calls == 1) throw StateError('offline');
      return pending.future;
    });
    addTearDown(fixture.watch.dispose);
    await fixture.settle();
    for (var i = 0; i < 6; i++) {
      await fixture.tick();
    }
    expect(calls, 2);
    expect(fixture.watch.cards.single['status'], contains('Checking outcome'));
    final old = fixture.screen;
    fixture.screen = 'New task started.';
    await fixture.tick();
    pending.complete(success(old));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.watch.observations['%1']!.verdict, isNull);
    expect(
      fixture.watch.cards.single['status'],
      isNot(contains('Reported success')),
    );
  });
  test(
    'checker errors retry after cooldown without resending a macro',
    () async {
      var calls = 0;
      final fixture = Fixture((source) async {
        if (++calls == 1) throw StateError('offline');
        return success(source);
      });
      addTearDown(fixture.watch.dispose);
      await fixture.settle();
      expect(calls, 1);
      expect(fixture.watch.cards.single['status'], contains('retry 2/3'));
      for (var i = 0; i < 5; i++) {
        await fixture.tick();
      }
      expect(calls, 1);
      await fixture.tick();
      expect(calls, 2);
      expect(
        fixture.watch.cards.single['status'],
        contains('Reported success'),
      );
      expect(fixture.watch.observations['%1']!.macroSent, isFalse);
    },
  );

  test(
    'retry budget is three attempts with 30 and 90 second backoff',
    () async {
      var calls = 0;
      final fixture = Fixture((_) async {
        calls++;
        return 'invalid';
      });
      addTearDown(fixture.watch.dispose);
      await fixture.settle();
      for (var i = 0; i < 6; i++) {
        await fixture.tick();
      }
      expect(calls, 2);
      for (var i = 0; i < 17; i++) {
        await fixture.tick();
      }
      expect(calls, 2);
      await fixture.tick();
      expect(calls, 3);
      expect(
        fixture.watch.cards.single['status'],
        contains('unavailable after 3 attempts'),
      );
      for (var i = 0; i < 30; i++) {
        await fixture.tick();
      }
      expect(calls, 3);
      fixture.screen = 'New final answer: not complete.';
      await fixture.settle();
      expect(calls, 4);
      expect(fixture.watch.cards.single['status'], contains('retry 2/3'));
    },
  );

  test('valid uncertain assessment is not retried endlessly', () async {
    var calls = 0;
    final fixture = Fixture((_) async {
      calls++;
      return jsonEncode({
        'status': 'uncertain',
        'reason': 'No clear conclusion.',
        'evidence': '',
      });
    });
    addTearDown(fixture.watch.dispose);
    await fixture.settle();
    for (var i = 0; i < 40; i++) {
      await fixture.tick();
    }
    expect(calls, 1);
    expect(fixture.watch.cards.single['status'], contains('Outcome unknown'));
  });

  test('one unavailable pane does not starve other settled panes', () async {
    var calls = 0;
    final fixture = Fixture((source) async {
      if (++calls == 1) throw StateError('busy');
      return success(source);
    }, panes: 3);
    addTearDown(fixture.watch.dispose);
    await fixture.settle();
    await fixture.tick();
    await fixture.tick();
    expect(calls, 3);
    expect(fixture.watch.cards.first['status'], contains('retry 2/3'));
    expect(fixture.watch.cards.last['status'], contains('Reported success'));
  });

  test('retry flag cannot turn an invalid assessment into success', () {
    final verdict = ConclusionVerdict.parse(
      jsonEncode({
        'status': 'reported_success',
        'reason': 'Done',
        'evidence': 'Done',
        'retryable': true,
      }),
      'Done',
    );
    expect(verdict.status, 'uncertain');
    expect(verdict.retryable, isTrue);
  });
}
