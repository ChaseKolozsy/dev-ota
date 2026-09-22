// Run with `dart run test_support/wsl_route_smoke.dart` on this WSL host.
// Real Windows shells + WSL, read-only commands and synthetic stdin only.
import 'dart:convert';
import 'dart:io';
import 'package:devota/terminal_host_route.dart';

Future<void> main() async {
  for (final shell in ['cmd.exe', 'powershell.exe']) {
    final router = TerminalHostRouter((command, {input}) async {
      final process = await Process.start('python3', [
        '../scripts/test/windows-shell-probe.py',
        shell,
        command,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      if (input != null) process.stdin.write(input);
      await process.stdin.close();
      final code = await process.exitCode;
      final stderr = await errors;
      if (code != 0) throw StateError('$stderr${await output}');
      final data = jsonDecode(await output) as Map;
      if (data['code'] != 0) {
        throw StateError('$command: ${data['err']}${data['out']}');
      }
      return data['out'] as String;
    });
    final name = (await router.execute('id -un')).trim();
    if (name != 'chase' || router.route.distribution != 'Ubuntu-24.04') {
      throw StateError('Wrong WSL target');
    }
    const sample = 'quotes " apostrophe \' \$HOME %PATH% & | ; 世界\nsecond line';
    final echoed = await router.execute('cat', input: sample);
    if (echoed != sample) throw StateError('stdin changed: $shell');
    final cwd = (await router.execute('pwd')).trim();
    if (cwd != '/home/chase') throw StateError('Wrong working directory');
    stdout.writeln(
      'PASS: $shell -> ${router.route.label}; Unicode/metacharacters/stdin/home preserved',
    );
  }
}
