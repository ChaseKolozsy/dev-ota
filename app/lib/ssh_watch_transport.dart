import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'terminal_watch.dart';

TmuxWatchTransport sshWatchTransport(
  SSHClient client, {
  bool Function()? isCurrent,
}) => TmuxWatchTransport(
  (command) => _execute(client, command, isCurrent: isCurrent),
  reviewer: (text) => _execute(
    client,
    'python3 dev-ota/server/terminal_review.py',
    isCurrent: isCurrent,
    input: jsonEncode({'text': text}),
    timeout: const Duration(seconds: 45),
  ),
);

Future<String> _execute(
  SSHClient client,
  String command, {
  bool Function()? isCurrent,
  String? input,
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (isCurrent != null && !isCurrent()) throw StateError('SSH disconnected');
  SSHSession? operation;
  var finished = false;
  try {
    return await (() async {
      final session = await client.execute(command);
      operation = session;
      if (finished) {
        session.close();
        throw StateError('SSH operation expired');
      }
      if (input != null) {
        session.write(utf8.encode(input));
        session.stdin.close();
      }
      final output = session.stdout.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      final errors = session.stderr.drain<void>();
      await session.done;
      final bytes = await output;
      await errors;
      if (session.exitCode != 0) {
        throw StateError('Pane unavailable or tmux command failed');
      }
      return utf8.decode(bytes, allowMalformed: true);
    })().timeout(timeout);
  } finally {
    finished = true;
    operation?.close();
  }
}
