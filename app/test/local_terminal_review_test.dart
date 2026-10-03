import 'dart:convert';
import 'package:devota/local_terminal_review.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'local rules preserve failures, negation, partial counts and new prompts',
    () {
      for (final source in [
        'All work complete. Tests failed.',
        'Not complete. Changes committed and pushed.',
        '19/20 completed and approved.',
        'All work complete. Please confirm the install.',
      ]) {
        expect(
          classifyTerminalText(source).status,
          'needs_attention',
          reason: source,
        );
      }
      for (final source in [
        'All work complete.\n❯ Start the next task',
        'I will fix this. Changes committed and pushed.',
        '42 tests passed.',
        'Done.',
        'If all work complete, report success.',
        'All work complete, but verification remains pending.',
      ]) {
        expect(
          classifyTerminalText(source).status,
          isNot('reported_success'),
          reason: source,
        );
      }
      expect(
        classifyTerminalText('All work complete.').status,
        'reported_success',
      );
      expect(
        classifyTerminalText('Implemented and verified the changes.').status,
        'reported_success',
      );
    },
  );
  test('snapshot isolates newest reply and is bounded', () {
    final excerpt = terminalReviewExcerpt(
      '● All work complete.\n❯ New request\n'
      '● Tests failed.\n❯\n',
    );
    expect(excerpt, isNot(contains('All work complete')));
    expect(classifyTerminalText(excerpt).status, 'needs_attention');
    final bounded = terminalReviewExcerpt(
      List.filled(100, 'x' * 300).join('\n'),
    );
    expect(bounded.length, lessThanOrEqualTo(6000));
    expect(bounded.split('\n').length, lessThanOrEqualTo(40));
  });
  test(
    'OCR cannot erase failure to turn a report green; no host model call',
    () async {
      const channel = MethodChannel('devota/terminal_review');
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'recognizeSnapshot');
            calls++;
            return 'All work complete.';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bad = jsonDecode(
        await reviewTerminalLocally('All work complete. Tests failed.'),
      );
      expect(bad['status'], 'uncertain');
      final good = jsonDecode(
        await reviewTerminalLocally('All work complete.'),
      );
      expect(good['status'], 'reported_success');
      expect(good['evidence'], 'All work complete.');
      expect(calls, 2);
    },
  );
}
