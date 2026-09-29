import 'package:devota/voice/voice_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceCommand cmd(String said, {bool confirming = false}) {
  final parsed = parseVoiceCommand(said, confirming: confirming);
  expect(parsed, isNotNull, reason: '"$said" should be a command');
  return parsed!;
}

void dictation(String said, {bool confirming = false}) {
  expect(
    parseVoiceCommand(said, confirming: confirming),
    isNull,
    reason: '"$said" must stay dictation',
  );
}

void main() {
  group('normaliser', () {
    test('lowercases, strips punctuation, folds control and slash', () {
      expect(voiceNormalize('Ctrl-C!'), ['control', 'c']);
      expect(voiceNormalize('CTL  L.'), ['control', 'l']);
      expect(voiceNormalize('/compact'), ['slash', 'compact']);
      expect(voiceNormalize('Back space 5'), ['backspace', '5']);
      expect(voiceNormalize('nevermind'), ['never', 'mind']);
    });

    test('number words become numbers only inside slots', () {
      expect(voiceParseNumber(['twenty'], 0).last, (20, 1));
      expect(voiceParseNumber(['twenty', 'five'], 0).first, (25, 2));
      expect(voiceParseNumber(['a', 'hundred'], 0).first, (100, 2));
      expect(voiceParseNumber(['to'], 0).first, (2, 1));
      expect(voiceParseNumber(['for'], 0).first, (4, 1));
      expect(voiceParseNumber(['12'], 0).first, (12, 1));
      expect(voiceParseNumber(['tab'], 0), isEmpty);
      // Outside a slot "to" stays a word.
      expect(cmd('send it').kind, VoiceCommandKind.submit);
    });
  });

  group('whole-utterance commands', () {
    test('sending', () {
      expect(cmd('submit').kind, VoiceCommandKind.submit);
      expect(cmd('Submit.').kind, VoiceCommandKind.submit);
      expect(cmd('send it').kind, VoiceCommandKind.submit);
      expect(cmd('enter').kind, VoiceCommandKind.enter);
      expect(cmd('Press enter').kind, VoiceCommandKind.enter);
      expect(cmd('return').kind, VoiceCommandKind.enter);
    });

    test('keys and their bytes', () {
      expect(cmd('escape').bytes, '\x1b');
      expect(cmd('Escape key').bytes, '\x1b');
      expect(cmd('E S C').bytes, '\x1b');
      expect(cmd('tab').bytes, '\t');
      expect(cmd('shift tab').bytes, '\x1b[Z');
      expect(cmd('page up').bytes, '\x1b[5~');
      expect(cmd('Page down.').bytes, '\x1b[6~');
      expect(cmd('control home').bytes, '\x1b[1;5H');
      expect(cmd('control end').bytes, '\x1b[1;5F');
      expect(cmd('arrow up').bytes, '\x1b[A');
      expect(cmd('down arrow').bytes, '\x1b[B');
      expect(cmd('arrow down three times').bytes, '\x1b[B' * 3);
      expect(cmd('option 2').bytes, '2');
      expect(cmd('clear line').needsConfirm, isTrue);
    });

    test('control letters; C and D confirm', () {
      final c = cmd('control C');
      expect(c.bytes, '\x03');
      expect(c.needsConfirm, isTrue);
      expect(cmd('Ctrl-C').bytes, '\x03');
      expect(cmd('control see').bytes, '\x03');
      expect(cmd('control D').needsConfirm, isTrue);
      final l = cmd('control L');
      expect(l.bytes, '\x0c');
      expect(l.needsConfirm, isFalse);
    });

    test('backspace with number words and digits', () {
      expect(cmd('backspace').count, 1);
      expect(cmd('backspace twenty').count, 20);
      expect(cmd('Backspace 20').count, 20);
      expect(cmd('backspace twenty five').count, 25);
      expect(cmd('back space five').count, 5);
      expect(cmd('backspace a hundred').count, 100);
      expect(cmd('backspace 12 characters').count, 12);
      expect(cmd('delete 3 characters').count, 3);
      expect(cmd('backspace to').count, 2);
      dictation('backspace 500');
      dictation('backspace zero');
    });

    test('scrolling', () {
      final up = cmd('scroll up');
      expect(up.kind, VoiceCommandKind.scrollUp);
      expect(up.count, 15);
      expect(cmd('scroll up forty lines').count, 40);
      expect(cmd('scroll down 5').kind, VoiceCommandKind.scrollDown);
      expect(cmd('scroll to the bottom').kind, VoiceCommandKind.scrollBottom);
    });

    test('macros by number and by name', () {
      final three = cmd('macro three');
      expect(three.kind, VoiceCommandKind.macroNumber);
      expect(three.count, 3);
      expect(three.needsConfirm, isTrue);
      expect(cmd('Macro 12').count, 12);
      expect(cmd('macro for').count, 4);
      final named = cmd('macro run tests');
      expect(named.kind, VoiceCommandKind.macroName);
      expect(named.text, 'run tests');
      expect(named.needsConfirm, isFalse);
      expect(cmd('list macros').kind, VoiceCommandKind.listMacros);
    });

    test('slash commands; exit, clear, compact and unknown ones confirm', () {
      final compact = cmd('/compact');
      expect(compact.kind, VoiceCommandKind.slash);
      expect(compact.text, 'compact');
      expect(compact.needsConfirm, isTrue);
      expect(cmd('slash plan').text, 'plan');
      expect(cmd('slash plan').needsConfirm, isFalse);
      expect(cmd('plan mode').text, 'plan');
      expect(cmd('slash exit').text, 'exit');
      expect(cmd('slash exit').needsConfirm, isTrue);
      expect(cmd('slash clear').needsConfirm, isTrue);
      expect(cmd('clear conversation').text, 'clear');
      expect(cmd('slash release notes').text, 'release-notes');
      expect(cmd('slash release notes').needsConfirm, isFalse);
      // Unknown words are sent only after a confirmation; long sentences
      // that start with "slash" are dictation.
      final custom = cmd('slash deploy staging');
      expect(custom.text, 'deploy-staging');
      expect(custom.needsConfirm, isTrue);
      dictation('slash the budget by half before friday');
      final exit = cmd('exit');
      expect(exit.text, 'exit');
      expect(exit.needsConfirm, isTrue);
      expect(cmd('Exit.').text, 'exit');
      expect(cmd('quit').text, 'exit');
    });

    test('windows, draft and listening', () {
      expect(cmd('window 2').count, 2);
      expect(cmd('window two').count, 2);
      expect(cmd('window too').count, 2);
      expect(cmd('switch to window three').count, 3);
      expect(cmd('which window').kind, VoiceCommandKind.whichWindow);
      final clear = cmd('clear draft');
      expect(clear.kind, VoiceCommandKind.clearDraft);
      expect(clear.needsConfirm, isTrue);
      expect(cmd('Read it back.').kind, VoiceCommandKind.readBack);
      expect(cmd('stop listening').kind, VoiceCommandKind.stopListening);
      expect(cmd('open keyboard').kind, VoiceCommandKind.openKeyboard);
      expect(cmd('hide keyboard').kind, VoiceCommandKind.closeKeyboard);
    });
  });

  group('dictation', () {
    test('a command word inside a sentence stays dictation', () {
      dictation('please submit the form');
      dictation('submit the pull request when the tests pass');
      dictation('I want to exit the loop early');
      dictation('press escape twice');
      dictation('the tab key is broken');
      dictation('scroll up to see the error');
      dictation('clear the draft folder and start again');
      dictation('run macro 3 later');
      dictation('stop listening to the old events');
      dictation('window 2 has the logs');
    });

    test('ordinary answers to the agent are dictation outside a confirm', () {
      dictation('yes');
      dictation('no');
      dictation('cancel');
      dictation('never mind');
      dictation('up');
      dictation('right');
      dictation('okay');
    });

    test('near misses are never promoted to commands', () {
      dictation('submits');
      dictation('escapes');
      dictation('exit now');
      dictation('control');
      dictation('window');
      dictation('macro');
      dictation('slash');
      dictation('window ten thousand');
    });
  });

  group('confirmation answers', () {
    test('yes and no only while confirming', () {
      expect(cmd('yes', confirming: true).kind, VoiceCommandKind.confirmYes);
      expect(cmd('Yeah.', confirming: true).kind, VoiceCommandKind.confirmYes);
      expect(
        cmd('confirm', confirming: true).kind,
        VoiceCommandKind.confirmYes,
      );
      expect(cmd('no', confirming: true).kind, VoiceCommandKind.confirmNo);
      expect(cmd('cancel', confirming: true).kind, VoiceCommandKind.confirmNo);
      expect(
        cmd('never mind', confirming: true).kind,
        VoiceCommandKind.confirmNo,
      );
      dictation('yes do it', confirming: true);
      // Other commands still parse while confirming.
      expect(cmd('escape', confirming: true).bytes, '\x1b');
    });
  });
}
