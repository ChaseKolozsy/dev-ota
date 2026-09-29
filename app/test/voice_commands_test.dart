import 'package:devota/voice/voice_commands.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceTarget t(
  VoiceTargetKind kind,
  String id,
  String label, {
  String? tooltip,
  String? abbreviation,
}) => VoiceTarget(
  kind: kind,
  id: id,
  label: label,
  tooltip: tooltip,
  abbreviation: abbreviation,
  run: () {},
);

void main() {
  const matcher = VoiceCommandMatcher();
  final targets = [
    t(VoiceTargetKind.padKey, 'ctrl_c', 'Ctrl-C', abbreviation: 'C-c'),
    t(VoiceTargetKind.padKey, 'page_up', 'Page Up', abbreviation: 'PgUp'),
    t(VoiceTargetKind.padKey, 'backspace', 'Backspace', abbreviation: 'BkSp'),
    t(VoiceTargetKind.padKey, 'slash', 'Slash', abbreviation: '/'),
    // A user's custom key, macro and cmds, known only at runtime.
    t(VoiceTargetKind.padKey, 'custom:1', 'Ctrl-Z', abbreviation: 'C-z'),
    t(VoiceTargetKind.arrow, 'up', 'Up'),
    t(VoiceTargetKind.tmux, 'tmux_next', 'Next', tooltip: 'tmux next window'),
    t(
      VoiceTargetKind.tmux,
      'tmux_split_vertical',
      'Split |',
      tooltip: 'tmux split pane side by side',
    ),
    t(
      VoiceTargetKind.tmux,
      'tmux_split_horizontal',
      'Split -',
      tooltip: 'tmux split pane top and bottom',
    ),
    t(VoiceTargetKind.macro, 'm1', 'Deploy staging'),
    t(VoiceTargetKind.command, '/compact', '/compact'),
    t(VoiceTargetKind.command, 'git status', 'git status'),
  ];

  String? idOf(String said) {
    final m = matcher.match(said, targets);
    return m is TargetMatch ? m.target.id : null;
  }

  test('button names match whatever the recognizer capitalises', () {
    expect(idOf('control C'), 'ctrl_c');
    expect(idOf('Control-C'), 'ctrl_c');
    expect(idOf('ctrl+c'), 'ctrl_c');
    expect(idOf('Page up.'), 'page_up');
    expect(idOf('backspace'), 'backspace');
    expect(idOf('slash'), 'slash');
    expect(idOf('up'), 'up');
    expect(idOf('arrow up'), 'up');
    expect(idOf('up arrow'), 'up');
    expect(idOf('next'), 'tmux_next');
    expect(idOf('next window'), 'tmux_next');
  });

  test('a command must be the whole utterance', () {
    for (final said in [
      'please press page up',
      'page up twice',
      'go to the next window now',
      'run the compact command',
      'tell it to control c the build',
    ]) {
      final m = matcher.match(said, targets);
      expect(m, isA<DictationMatch>(), reason: said);
      expect((m as DictationMatch).text, said);
    }
    expect(matcher.match('send it now', targets), isA<DictationMatch>());
    expect(matcher.match('yes please', targets), isA<DictationMatch>());
  });

  test('custom keys, macros and cmds are commands by their names', () {
    expect(idOf('control z'), 'custom:1');
    expect(idOf('deploy staging'), 'm1');
    expect(idOf('run deploy staging'), 'm1');
    expect(idOf('compact'), '/compact');
    expect(idOf('slash compact'), '/compact');
    expect(idOf('run compact'), '/compact');
    expect(idOf('git status'), 'git status');
  });

  test('a name two buttons share names neither; their tooltips still do', () {
    expect(idOf('split'), isNull);
    expect(idOf('split pane side by side'), 'tmux_split_vertical');
    expect(idOf('split pane top and bottom'), 'tmux_split_horizontal');
  });

  test('backspace N and delete N words edit the composer', () {
    ComposerEditMatch edit(String said) =>
        matcher.match(said, targets) as ComposerEditMatch;
    expect(edit('backspace twenty').count, 20);
    expect(edit('backspace twenty').edit, ComposerEdit.backspace);
    expect(edit('Backspace 5').count, 5);
    expect(edit('backspace twenty five').count, 25);
    expect(edit('backspace a hundred').count, 100);
    expect(edit('backspace three times').count, 3);
    expect(edit('delete three words').count, 3);
    expect(edit('delete three words').edit, ComposerEdit.deleteWords);
    expect(edit('delete word').count, 1);
    expect(edit('delete a word').count, 1);
    expect(edit('delete the last two words').count, 2);
    expect(edit('delete to words').count, 2);
    expect(edit('clear').edit, ComposerEdit.clear);
    // Not numbers: plain dictation.
    expect(matcher.match('backspace banana', targets), isA<DictationMatch>());
    expect(matcher.match('delete the file', targets), isA<DictationMatch>());
    // Bare "backspace" is the pad key, which acts on the terminal.
    expect(idOf('backspace'), 'backspace');
  });

  test('number words', () {
    expect(parseCount(['twenty']), 20);
    expect(parseCount(['twenty', 'one']), 21);
    expect(parseCount(['one', 'hundred', 'and', 'five']), 105);
    expect(parseCount(['12']), 12);
    expect(parseCount(['five', 'five']), isNull);
    expect(parseCount(['lots']), isNull);
  });

  test('send, stop listening, yes and no', () {
    expect(matcher.match('Send', targets), isA<SendMatch>());
    expect(matcher.match('submit.', targets), isA<SendMatch>());
    expect(matcher.match('stop listening', targets), isA<StopListeningMatch>());
    expect(matcher.match('Yes.', targets), isA<YesMatch>());
    expect(matcher.match('no', targets), isA<NoMatch>());
  });

  test('read screen, read reply and stop reading', () {
    ReadTarget? read(String said) {
      final m = matcher.match(said, targets);
      return m is ReadMatch ? m.target : null;
    }

    expect(read('Read screen'), ReadTarget.screen);
    expect(read('read the screen.'), ReadTarget.screen);
    expect(read('Read reply'), ReadTarget.reply);
    expect(read('read the reply'), ReadTarget.reply);
    expect(matcher.match('Stop reading.', targets), isA<StopReadingMatch>());
    // Inside a longer sentence the same words are dictation.
    for (final said in [
      'read screen output into the log',
      'please read the reply from the server',
      'stop reading the config twice',
      'can you read screen',
    ]) {
      expect(matcher.match(said, targets), isA<DictationMatch>(), reason: said);
    }
    // A button can never shadow them.
    final shadow = [
      ...targets,
      t(VoiceTargetKind.command, 'read screen', 'read screen'),
    ];
    expect(matcher.match('read screen', shadow), isA<ReadMatch>());
  });

  test('exit labels ask for confirmation', () {
    expect(isExitLabel('/exit'), isTrue);
    expect(isExitLabel('exit'), isTrue);
    expect(isExitLabel('/compact'), isFalse);
    expect(isExitLabel('exit scroll'), isFalse);
  });

  test('composer edit helpers', () {
    expect(backspaceText('hello', 2), 'hel');
    expect(backspaceText('hi', 20), '');
    expect(deleteLastWords('fix the  bug ', 1), 'fix the');
    expect(deleteLastWords('one two', 5), '');
  });
}
