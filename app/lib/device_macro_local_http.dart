import 'dart:convert';

import 'package:dio/dio.dart';

typedef DeviceMacroLocalHttpAttemptObserver =
    Future<void> Function(Map<String, dynamic> attempt);

Future<Map<String, dynamic>> runDeviceMacroLocalHttpAssert(
  Dio dio,
  Map<String, dynamic> args, {
  DeviceMacroLocalHttpAttemptObserver? onAttempt,
}) async {
  final rawUrl = args['url']?.toString().trim() ?? '';
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      uri.scheme != 'http' ||
      !_isLoopbackHost(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException(
      'localHttpAssert url must be an http:// loopback URL',
    );
  }
  final method = args['method']?.toString().trim().toUpperCase() ?? 'GET';
  if (method != 'GET' && method != 'HEAD') {
    throw const FormatException('localHttpAssert permits only GET or HEAD');
  }
  final expectedStatus = args['expectedStatus'];
  if (expectedStatus is! int || expectedStatus < 100 || expectedStatus > 599) {
    throw const FormatException(
      'localHttpAssert expectedStatus must be an HTTP status integer',
    );
  }
  final timeoutSeconds = (args['timeoutSeconds'] as num?)?.toDouble() ?? 30;
  if (!timeoutSeconds.isFinite || timeoutSeconds <= 0 || timeoutSeconds > 120) {
    throw const FormatException(
      'localHttpAssert timeoutSeconds must be greater than 0 and at most 120',
    );
  }
  final retryUntilSeconds =
      (args['retryUntilSeconds'] as num?)?.toDouble() ?? 0;
  if (!retryUntilSeconds.isFinite ||
      retryUntilSeconds < 0 ||
      retryUntilSeconds > 3600) {
    throw const FormatException(
      'localHttpAssert retryUntilSeconds must be from 0 to 3600',
    );
  }
  final retryIntervalSeconds =
      (args['retryIntervalSeconds'] as num?)?.toDouble() ?? 2;
  if (!retryIntervalSeconds.isFinite ||
      retryIntervalSeconds < 0.1 ||
      retryIntervalSeconds > 30) {
    throw const FormatException(
      'localHttpAssert retryIntervalSeconds must be from 0.1 to 30',
    );
  }
  final expectedPaths = args['jsonPathEquals'];
  if (expectedPaths != null && expectedPaths is! Map) {
    throw const FormatException(
      'localHttpAssert jsonPathEquals must be an object',
    );
  }
  final observedPathNames = _stringList(args['jsonPaths'], 'jsonPaths');
  final includes = _stringList(args['bodyIncludes'], 'bodyIncludes');
  final excludes = _stringList(args['bodyExcludes'], 'bodyExcludes');
  final requestTimeout = Duration(
    milliseconds: (timeoutSeconds * 1000).round(),
  );
  final retryDeadline = Duration(
    milliseconds: (retryUntilSeconds * 1000).round(),
  );
  final retryInterval = Duration(
    milliseconds: (retryIntervalSeconds * 1000).round(),
  );
  final watch = Stopwatch()..start();
  var attempts = 0;
  Object? lastFailure;
  while (true) {
    attempts++;
    Map<String, dynamic>? result;
    try {
      result = await _runAttempt(
        dio: dio,
        uri: uri,
        method: method,
        expectedStatus: expectedStatus,
        expectedPaths: expectedPaths,
        observedPathNames: observedPathNames,
        includes: includes,
        excludes: excludes,
        timeout: requestTimeout,
      );
    } catch (error) {
      lastFailure = error;
    }
    await onAttempt?.call({
      'attempt': attempts,
      'elapsedMilliseconds': watch.elapsedMilliseconds,
      ...?result,
      if (result == null) 'ok': false,
      if (result == null) 'error': lastFailure.toString(),
    });
    if (result != null) {
      return {
        ...result,
        'attempts': attempts,
        'elapsedMilliseconds': watch.elapsedMilliseconds,
      };
    }
    if (retryDeadline == Duration.zero || watch.elapsed >= retryDeadline) {
      throw StateError(
        'local HTTP assertion failed after $attempts attempt(s) and '
        '${watch.elapsedMilliseconds} ms: $lastFailure',
      );
    }
    final remaining = retryDeadline - watch.elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(
        remaining < retryInterval ? remaining : retryInterval,
      );
    }
  }
}

Future<Map<String, dynamic>> _runAttempt({
  required Dio dio,
  required Uri uri,
  required String method,
  required int expectedStatus,
  required dynamic expectedPaths,
  required List<String> observedPathNames,
  required List<String> includes,
  required List<String> excludes,
  required Duration timeout,
}) async {
  final response = await dio.requestUri<dynamic>(
    uri,
    options: Options(
      method: method,
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      sendTimeout: timeout,
      receiveTimeout: timeout,
    ),
  );
  final status = response.statusCode ?? 0;
  final body = response.data?.toString() ?? '';
  if (status != expectedStatus) {
    throw StateError(
      'local HTTP ${uri.path} returned $status, expected $expectedStatus',
    );
  }
  for (final text in includes) {
    if (!body.contains(text)) {
      throw StateError('local HTTP body did not include ${jsonEncode(text)}');
    }
  }
  for (final text in excludes) {
    if (body.contains(text)) {
      throw StateError(
        'local HTTP body unexpectedly included ${jsonEncode(text)}',
      );
    }
  }

  final observedPaths = <String, dynamic>{};
  if ((expectedPaths is Map && expectedPaths.isNotEmpty) ||
      observedPathNames.isNotEmpty) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw StateError('local HTTP body was not valid JSON');
    }
    if (expectedPaths is Map) {
      for (final entry in expectedPaths.entries) {
        final path = entry.key.toString();
        final observed = _jsonPath(decoded, path);
        if (observed != entry.value) {
          throw StateError(
            'local HTTP JSON path $path was ${jsonEncode(observed)}, '
            'expected ${jsonEncode(entry.value)}',
          );
        }
        observedPaths[path] = observed;
      }
    }
    for (final path in observedPathNames) {
      observedPaths[path] = _jsonPath(decoded, path);
    }
  }
  return {
    'ok': true,
    'method': method,
    'url': uri.toString(),
    'statusCode': status,
    'bodyBytes': utf8.encode(body).length,
    if (observedPaths.isNotEmpty) 'observedJsonPaths': observedPaths,
  };
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == '127.0.0.1' ||
      normalized == 'localhost' ||
      normalized == '::1';
}

List<String> _stringList(dynamic value, String field) {
  if (value == null) return const [];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('localHttpAssert $field must be a string array');
  }
  return value.cast<String>();
}

dynamic _jsonPath(dynamic value, String rawPath) {
  var path = rawPath.trim();
  if (path == r'$') return value;
  if (path.startsWith(r'$.')) path = path.substring(2);
  if (path.isEmpty) throw const FormatException('JSON path is empty');
  dynamic current = value;
  for (final segment in path.split('.')) {
    if (segment.isEmpty) throw FormatException('invalid JSON path: $rawPath');
    final index = int.tryParse(segment);
    if (index != null) {
      if (current is! List || index < 0 || index >= current.length) {
        throw StateError('local HTTP JSON path $rawPath was missing');
      }
      current = current[index];
      continue;
    }
    if (current is! Map || !current.containsKey(segment)) {
      throw StateError('local HTTP JSON path $rawPath was missing');
    }
    current = current[segment];
  }
  return current;
}
