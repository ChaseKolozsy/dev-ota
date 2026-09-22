import 'dart:convert';

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String decodeHostOutput(List<int> bytes) {
  // WSL CLI failures are UTF-16LE on some Windows versions, unlike successful
  // Linux output. Keep those diagnostics readable as well.
  final sample = bytes.take(80).toList();
  var zeros = 0;
  for (var i = 1; i < sample.length; i += 2) {
    if (sample[i] == 0) zeros++;
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) || zeros > sample.length / 4)) {
    return String.fromCharCodes([
      for (
        var i = bytes[0] == 255 && bytes[1] == 254 ? 2 : 0;
        i + 1 < bytes.length;
        i += 2
      )
        bytes[i] | (bytes[i + 1] << 8),
    ]);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

typedef HostCommand = Future<String> Function(String command, {String? input});

class TerminalHostRoute {
  const TerminalHostRoute({
    this.mode = 'auto',
    this.distribution = '',
    this.user = '',
  });
  final String mode;
  final String distribution;
  final String user;

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'distribution': distribution,
    'user': user,
  };
  factory TerminalHostRoute.fromJson(Map<String, dynamic> json) =>
      TerminalHostRoute(
        mode: json['mode'] as String? ?? 'auto',
        distribution: json['distribution'] as String? ?? '',
        user: json['user'] as String? ?? '',
      );

  void validate() {
    if (!['auto', 'direct', 'wsl'].contains(mode)) {
      throw ArgumentError('Unknown execution host');
    }
    // Values cross CMD/PowerShell before WSL. Reject shell metacharacters,
    // quotes, option prefixes and control characters instead of escaping twice.
    if (distribution.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(distribution)) {
      throw ArgumentError(
        'Use a WSL distribution name containing letters, numbers, dots, dashes or underscores (no spaces).',
      );
    }
    if (user.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$').hasMatch(user)) {
      throw ArgumentError('Invalid Linux username');
    }
  }

  String get label => mode == 'wsl'
      ? 'WSL · ${distribution.isEmpty ? 'default distribution' : distribution} · ${user.isEmpty ? 'default user' : user}'
      : mode == 'direct'
      ? 'Direct Linux SSH'
      : 'Automatic · Linux or Windows / WSL';

  ({String command, String? input}) wrap(String command, {String? input}) {
    validate();
    if (mode != 'wsl') return (command: command, input: input);
    final launcher =
        'wsl.exe'
        '${distribution.isEmpty ? '' : ' --distribution $distribution'}'
        '${user.isEmpty ? '' : ' --user $user'} --exec /bin/sh -s';
    // All Linux syntax travels on stdin, never through CMD or PowerShell.
    // Give the child a separate input stream for the model-review JSON.
    final script = input == null
        ? 'exec /bin/sh -c ${_quote(command)}'
        : 'printf %s ${_quote(base64Encode(utf8.encode(input)))} | base64 -d | /bin/sh -c ${_quote(command)}';
    return (command: launcher, input: 'cd "\$HOME" || exit 1\n$script\n');
  }
}

/// Resolve using read-only probes once, then pin every operation to that host.
/// Never re-route or replay a failed macro/paste/Enter operation.
class TerminalHostRouter {
  TerminalHostRouter(
    this.raw, {
    TerminalHostRoute route = const TerminalHostRoute(),
  }) : _route = route;
  final HostCommand raw;
  TerminalHostRoute _route;
  TerminalHostRoute? resolved;
  Future<TerminalHostRoute>? _resolving;
  TerminalHostRoute get route => resolved ?? _route;

  void configure(TerminalHostRoute value) {
    value.validate();
    _route = value;
    resolved = null;
    _resolving = null;
  }

  Future<TerminalHostRoute> _resolve() async {
    _route.validate();
    if (_route.mode == 'direct') return _route;
    if (_route.mode == 'auto') {
      try {
        await raw('tmux -V');
        return const TerminalHostRoute(mode: 'direct');
      } catch (e) {
        final message = '$e'.toLowerCase();
        if (!message.contains('tmux') || !message.contains('not recognized')) {
          rethrow;
        }
      }
    }
    final candidate = TerminalHostRoute(
      mode: 'wsl',
      distribution: _route.distribution,
      user: _route.user,
    );
    final probe = candidate.wrap('printf "%s\\n" "\$WSL_DISTRO_NAME"; id -un');
    final output = await raw(probe.command, input: probe.input);
    final fields = output.trim().split(RegExp(r'\r?\n'));
    if (fields.length != 2 || fields.any((f) => f.isEmpty)) {
      throw StateError(
        'Could not identify the WSL distribution and Linux user. Choose them in Execution host.',
      );
    }
    final pinned = TerminalHostRoute(
      mode: 'wsl',
      distribution: fields[0],
      user: fields[1],
    );
    pinned.validate();
    return pinned;
  }

  Future<String> execute(String command, {String? input}) async {
    final pending = _resolving ??= _resolve();
    TerminalHostRoute target;
    try {
      target = await pending;
    } catch (_) {
      if (identical(_resolving, pending)) _resolving = null;
      rethrow;
    }
    if (!identical(_resolving, pending)) {
      throw StateError('Execution host changed; retry discovery');
    }
    resolved = target;
    final request = target.wrap(command, input: input);
    return raw(request.command, input: request.input);
  }
}
