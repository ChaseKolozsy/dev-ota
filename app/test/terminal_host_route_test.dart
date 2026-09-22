import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:devota/terminal_host_route.dart';

void main() {
  test('Windows UTF-16 diagnostics and Linux UTF-8 decode cleanly', () {
    const text = 'No such distribution 世界';
    expect(decodeHostOutput(utf8.encode(text)), text);
    final utf16 = [
      for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
    ];
    expect(decodeHostOutput(utf16), text);
    expect(decodeHostOutput([255, 254, ...utf16]), text);
  });
  test('native commands and stdin are unchanged', () {
    const route = TerminalHostRoute(mode: 'direct');
    expect(route.wrap('cat', input: 'hello'), (command: 'cat', input: 'hello'));
  });
  test('WSL keeps Linux metacharacters out of Windows command line', () {
    const route = TerminalHostRoute(
      mode: 'wsl',
      distribution: 'Ubuntu-24.04',
      user: 'chase',
    );
    const command = "printf '%s' 'dollar\$ & | %PATH% 世界'";
    final result = route.wrap(command);
    expect(
      result.command,
      'wsl.exe --distribution Ubuntu-24.04 --user chase --exec /bin/sh -s',
    );
    expect(result.command, isNot(contains('%PATH%')));
    expect(result.input, startsWith('cd "\$HOME" || exit 1\n'));
    expect(result.input, contains('世界'));
    final review = route.wrap('cat', input: 'line1\nline2 世界');
    expect(
      review.input,
      contains(base64Encode(utf8.encode('line1\nline2 世界'))),
    );
  });
  test('Windows-shell injection characters are rejected', () {
    for (final value in [
      'x&whoami',
      'x"',
      '\$USER',
      '%PATH%',
      'x\n',
      '-root',
      'a|b',
      'a`b',
      'with space',
    ]) {
      expect(
        () => TerminalHostRoute(mode: 'wsl', distribution: value).wrap('true'),
        throwsArgumentError,
      );
      expect(
        () => TerminalHostRoute(mode: 'wsl', user: value).wrap('true'),
        throwsArgumentError,
      );
    }
  });
  test('auto detects Windows once and pins all later operations', () async {
    final calls = <({String command, String? input})>[];
    final router = TerminalHostRouter((command, {input}) async {
      calls.add((command: command, input: input));
      if (command == 'tmux -V') {
        throw StateError(
          "'tmux' is not recognized as an internal or external command",
        );
      }
      if (input!.contains('WSL_DISTRO_NAME')) return 'Ubuntu-24.04\nchase\n';
      return 'ok';
    });
    expect(await router.execute('tmux list-panes'), 'ok');
    await router.execute('tmux send-keys -t %1 Enter');
    await router.execute(
      'python3 dev-ota/server/terminal_review.py',
      input: '{}',
    );
    expect(calls.where((c) => c.command == 'tmux -V'), hasLength(1));
    expect(
      calls
          .skip(2)
          .every(
            (c) =>
                c.command.contains('--distribution Ubuntu-24.04 --user chase'),
          ),
      isTrue,
    );
    expect(
      TerminalHostRoute.fromJson(router.route.toJson()).label,
      'WSL · Ubuntu-24.04 · chase',
    );
  });
  test('Linux failure does not fall back to a different host', () async {
    var calls = 0;
    final router = TerminalHostRouter((command, {input}) async {
      calls++;
      throw StateError('tmux: command not found');
    });
    await expectLater(router.execute('tmux send-keys'), throwsStateError);
    expect(calls, 1);
  });
  test('failed mutations are never retried or rerouted', () async {
    var mutations = 0;
    final router = TerminalHostRouter((command, {input}) async {
      if (command == 'tmux -V') return 'tmux 3.4';
      mutations++;
      throw StateError('disconnected');
    });
    await expectLater(router.execute('tmux send-keys'), throwsStateError);
    expect(mutations, 1);
    expect(router.route.mode, 'direct');
  });
  test('probe failures can be retried and explicit WSL is honored', () async {
    var attempts = 0;
    final router = TerminalHostRouter(
      (command, {input}) async {
        expect(command, contains('--distribution OtherDistro --user tester'));
        if (input!.contains('WSL_DISTRO_NAME')) {
          if (attempts++ == 0) throw StateError('temporarily unavailable');
          return 'OtherDistro\ntester\n';
        }
        return 'ok';
      },
      route: const TerminalHostRoute(
        mode: 'wsl',
        distribution: 'OtherDistro',
        user: 'tester',
      ),
    );
    await expectLater(router.execute('tmux list-panes'), throwsStateError);
    expect(await router.execute('tmux list-panes'), 'ok');
  });
}
