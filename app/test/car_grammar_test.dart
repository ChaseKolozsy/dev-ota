import 'package:devota/car/car_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

CarCommand cmd(String said) {
  final parsed = parseCarCommand(said);
  expect(parsed.ok, isTrue, reason: '"$said" should parse, got ${parsed.error}');
  return parsed.command!;
}

void rejected(String said) {
  final parsed = parseCarCommand(said);
  expect(parsed.ok, isFalse, reason: '"$said" must not parse, got ${parsed.command}');
  expect(parsed.error, carDidntCatch);
}

void main() {
  group('normaliser', () {
    test('lowercases, strips punctuation, folds control and reads slash', () {
      expect(carNormalize('Ctrl-C!'), ['control', 'c']);
      expect(carNormalize('CTL  L.'), ['control', 'l']);
      expect(carNormalize('/compact'), ['slash', 'compact']);
      expect(carNormalize("That's all"), ['thats', 'all']);
      expect(carNormalize('never mind'), ['never', 'mind']);
      expect(carNormalize('nevermind'), ['never', 'mind']);
    });

    test('number words become numbers only inside slots', () {
      expect(carParseNumber(['thirty'], 0).first, (30, 1));
      expect(carParseNumber(['twenty', 'five'], 0).first, (25, 2));
      expect(carParseNumber(['a', 'hundred'], 0).first, (100, 2));
      expect(carParseNumber(['to'], 0).first, (2, 1));
      expect(carParseNumber(['for'], 0).first, (4, 1));
      expect(carParseNumber(['12'], 0).first, (12, 1));
      expect(carParseNumber(['tab'], 0), isEmpty);
      // Outside a slot "to" stays a word: "send it" is not "send 2".
      expect(cmd('send it').kind, CarCommandKind.submit);
    });
  });

  group('keys', () {
    test('every key and synonym', () {
      expect(cmd('tab').bytes, '\t');
      expect(cmd('tab key').bytes, '\t');
      expect(cmd('shift tab').bytes, '\x1b[Z');
      expect(cmd('back tab').bytes, '\x1b[Z');
      expect(cmd('escape').bytes, '\x1b');
      expect(cmd('escape key').bytes, '\x1b');
      expect(cmd('E S C').bytes, '\x1b');
      expect(cmd('forward slash').bytes, '/');
      expect(cmd('slash').bytes, '/');
      expect(cmd('plus').bytes, '+');
      expect(cmd('minus').bytes, '-');
      expect(cmd('dash').bytes, '-');
      expect(cmd('hyphen').bytes, '-');
      expect(cmd('question mark').bytes, '?');
      expect(cmd('space').bytes, ' ');
      expect(cmd('home').bytes, '\x1b[H');
      expect(cmd('end').bytes, '\x1b[F');
      expect(cmd('control home').bytes, '\x1b[1;5H');
      expect(cmd('control end').bytes, '\x1b[1;5F');
      expect(cmd('page up').bytes, '\x1b[5~');
      expect(cmd('PG up').bytes, '\x1b[5~');
      expect(cmd('page down').bytes, '\x1b[6~');
    });

    test('enter and submit are different commands', () {
      expect(cmd('enter').kind, CarCommandKind.enter);
      expect(cmd('return').kind, CarCommandKind.enter);
      expect(cmd('press enter').kind, CarCommandKind.enter);
      expect(cmd('submit').kind, CarCommandKind.submit);
      expect(cmd('send').kind, CarCommandKind.submit);
      expect(cmd('Send it.').kind, CarCommandKind.submit);
    });

    test('control letters, with Ctrl-C and Ctrl-D destructive', () {
      final c = cmd('control C');
      expect(c.bytes, '\x03');
      expect(c.destructive, isTrue);
      expect(cmd('control see').bytes, '\x03');
      expect(cmd('interrupt').bytes, '\x03');
      expect(cmd('interrupt').destructive, isTrue);
      final d = cmd('ctrl d');
      expect(d.bytes, '\x04');
      expect(d.destructive, isTrue);
      final l = cmd('control L');
      expect(l.bytes, '\x0c');
      expect(l.destructive, isFalse);
      expect(cmd('control are').bytes, '\x12');
    });

    test('option N picks a numbered choice 1-9', () {
      expect(cmd('option 1').bytes, '1');
      expect(cmd('choose three').bytes, '3');
      expect(cmd('number two').bytes, '2');
      expect(cmd('option to').bytes, '2');
      rejected('option 12');
    });

    test('arrows with an optional count up to 20', () {
      expect(cmd('up').bytes, '\x1b[A');
      expect(cmd('down 3 times').bytes, '\x1b[B' * 3);
      expect(cmd('arrow left').bytes, '\x1b[D');
      expect(cmd('arrow right five').bytes, '\x1b[C' * 5);
      expect(cmd('up twenty times').count, 20);
      rejected('up 21 times');
    });

    test('backspace N, default 1, confirmed only above 30', () {
      expect(cmd('backspace').count, 1);
      final thirty = cmd('backspace 30 characters');
      expect(thirty.count, 30);
      expect(thirty.destructive, isFalse);
      final big = cmd('delete thirty one');
      expect(big.count, 31);
      expect(big.destructive, isTrue);
      expect(cmd('back 12').count, 12);
      expect(cmd('backspace a hundred').count, 100);
      rejected('backspace 201');
    });

    test('clear line is destructive', () {
      expect(cmd('clear line').bytes, '\x15');
      expect(cmd('clear line').destructive, isTrue);
    });
  });

  group('slash commands', () {
    test('bare exit is /exit, never a mode exit', () {
      for (final said in ['exit', 'Exit.', 'exit claude', 'quit', 'slash exit', '/exit']) {
        final c = cmd(said);
        expect(c.kind, CarCommandKind.slash, reason: said);
        expect(c.text, 'exit', reason: said);
        expect(c.echo, 'Exit Claude');
      }
    });

    test('named and other slash commands', () {
      expect(cmd('compact').text, 'compact');
      expect(cmd('slash compact').text, 'compact');
      expect(cmd('clear conversation').text, 'clear');
      expect(cmd('plan mode').text, 'plan');
      final other = cmd('slash review pr');
      expect(other.text, 'review-pr');
      expect(other.echo, 'Slash review pr');
    });

    test('exit screen phrases stay UI commands', () {
      expect(cmd('exit full screen').kind, CarCommandKind.ui);
    });
  });

  group('escape versus exit (§8.3)', () {
    test('escape is accepted only exactly', () {
      expect(cmd('escape').kind, CarCommandKind.keys);
      rejected('escaped');
      rejected('a scape');
      rejected('escape the');
    });

    test('an utterance between escape key and exit is rejected', () {
      rejected('exit key');
      rejected('escape keys');
    });
  });

  group('macros, reading, windows, scroll', () {
    test('macro by number and name', () {
      expect(cmd('macro 3').kind, CarCommandKind.macroNumber);
      expect(cmd('macro three').count, 3);
      expect(cmd('macro ninety nine').count, 99);
      final named = cmd('macro cebuano middle');
      expect(named.kind, CarCommandKind.macroName);
      expect(named.text, 'cebuano middle');
      expect(cmd('list macros').kind, CarCommandKind.listMacros);
    });

    test('reading and window selection', () {
      expect(cmd('read').kind, CarCommandKind.read);
      expect(cmd('listen').kind, CarCommandKind.read);
      expect(cmd('go back').kind, CarCommandKind.earlier);
      expect(cmd('stop').kind, CarCommandKind.stopReading);
      expect(cmd('quiet').kind, CarCommandKind.stopReading);
      expect(cmd('how are the windows').kind, CarCommandKind.status);
      expect(cmd('window 2').count, 2);
      expect(cmd('target three').count, 3);
      rejected('window 4');
    });

    test('scroll defaults to 15 lines, capped at 200', () {
      expect(cmd('scroll up').count, 15);
      expect(cmd('scroll up 40 lines').count, 40);
      expect(cmd('scroll back').kind, CarCommandKind.scrollUp);
      expect(cmd('scroll down 5').kind, CarCommandKind.scrollDown);
      expect(cmd('more').kind, CarCommandKind.scrollMore);
      expect(cmd('scroll up more').kind, CarCommandKind.scrollMore);
      expect(cmd('bottom').kind, CarCommandKind.scrollBottom);
      expect(cmd('scroll to bottom').kind, CarCommandKind.scrollBottom);
      rejected('scroll up 500');
    });
  });

  group('UI and car-mode control', () {
    test('UI commands', () {
      expect(cmd('open keyboard').ui, CarUiCommand.openKeyboard);
      expect(cmd('hide keyboard').ui, CarUiCommand.closeKeyboard);
      expect(cmd('maximize').ui, CarUiCommand.maximize);
      expect(cmd('full screen').ui, CarUiCommand.maximize);
      expect(cmd('show tabs').ui, CarUiCommand.minimize);
      expect(cmd('expand tools').ui, CarUiCommand.openTools);
      expect(cmd('collapse tools').ui, CarUiCommand.collapseTools);
    });

    test('mode words', () {
      expect(cmd('done').kind, CarCommandKind.done);
      expect(cmd("that's all").kind, CarCommandKind.done);
      expect(cmd('stop listening').kind, CarCommandKind.done);
      expect(cmd('say again').kind, CarCommandKind.repeat);
      expect(cmd('never mind').kind, CarCommandKind.cancel);
      expect(cmd('scratch that').destructive, isTrue);
      expect(cmd('privacy on').kind, CarCommandKind.privacyOn);
      expect(cmd('buttons off').kind, CarCommandKind.carModeOff);
      expect(cmd('take the buttons back').kind, CarCommandKind.takeButtons);
      expect(cmd('yes').kind, CarCommandKind.confirmYes);
      expect(cmd('no').kind, CarCommandKind.confirmNo);
    });
  });

  group('strict matching', () {
    test('unmatched and empty phrases do nothing', () {
      rejected('');
      rejected('please fix the tests');
      rejected('tabs');
      rejected('hello');
    });

    test('one word-level edit of exactly one multi-word entry', () {
      expect(cmd('scroll to the bottom').kind, CarCommandKind.scrollBottom);
      expect(cmd('open the keyboard').ui, CarUiCommand.openKeyboard);
      // Ambiguous near-misses are rejected.
      rejected('close');
    });

    test('biasing phrases include the fixed vocabulary', () {
      final phrases = carBiasingPhrases();
      expect(phrases, containsAll(['escape', 'submit', 'scroll up', 'done']));
      expect(phrases.any((p) => p.contains('N')), isFalse);
    });
  });
}
