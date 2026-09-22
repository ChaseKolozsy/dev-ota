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
      // Keep a bounded diagnostic for the setup screen instead of silently
      // discarding "tmux not found", socket, or SSH shell errors. Never log it.
      final errors = session.stderr.fold<List<int>>([], (bytes, chunk) {
        final remaining = 2048 - bytes.length;
        if (remaining > 0) bytes.addAll(chunk.take(remaining));
        return bytes;
      });
      await session.done;
      final bytes = await output;
      final errorBytes = await errors;
      if (session.exitCode != 0) {
        final detail = utf8.decode(errorBytes, allowMalformed: true).trim();
        throw StateError(
          'SSH command failed (exit ${session.exitCode ?? 'unknown'}).'
          '${detail.isEmpty ? ' Pane unavailable or tmux command failed.' : '\n$detail'}',
        );
      }
      return utf8.decode(bytes, allowMalformed: true);
    })().timeout(timeout);
  } finally {
    finished = true;
    operation?.close();
  }
}
