import 'dart:convert';
import 'dart:io';

import 'package:devota/device_macro_local_http.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('asserts loopback status and selected JSON paths', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.statusCode = 402;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'reason': 'content_locked',
          'nested': {'licensed': false},
        }),
      );
      await request.response.close();
    });

    final result = await runDeviceMacroLocalHttpAssert(Dio(), {
      'url': 'http://127.0.0.1:${server.port}/lesson',
      'expectedStatus': 402,
      'jsonPathEquals': {
        'reason': 'content_locked',
        r'$.nested.licensed': false,
      },
      'bodyIncludes': ['content_locked'],
    });

    expect(result['statusCode'], 402);
    expect(result['observedJsonPaths'], {
      'reason': 'content_locked',
      r'$.nested.licensed': false,
    });
    expect(result.containsKey('body'), isFalse);
  });

  test('rejects non-loopback URLs and mutating methods', () async {
    expect(
      () => runDeviceMacroLocalHttpAssert(Dio(), {
        'url': 'https://example.com/private',
        'expectedStatus': 200,
      }),
      throwsFormatException,
    );
    expect(
      () => runDeviceMacroLocalHttpAssert(Dio(), {
        'url': 'http://127.0.0.1:8002/keys',
        'method': 'POST',
        'expectedStatus': 200,
      }),
      throwsFormatException,
    );
  });

  test('polls until the expected local install state appears', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'presence': requests < 3 ? 'installing' : 'installed',
          'bytes_done': 240407632,
          'bytes_total': 240407632,
        }),
      );
      await request.response.close();
    });

    final attempts = <Map<String, dynamic>>[];
    final result = await runDeviceMacroLocalHttpAssert(Dio(), {
      'url': 'http://127.0.0.1:${server.port}/packs/presence?sku=hu-v2',
      'expectedStatus': 200,
      'jsonPathEquals': {'presence': 'installed'},
      'jsonPaths': ['bytes_done', 'bytes_total'],
      'retryUntilSeconds': 2,
      'retryIntervalSeconds': 0.1,
    }, onAttempt: (attempt) async => attempts.add(attempt));

    expect(result['attempts'], 3);
    expect(result['observedJsonPaths'], {
      'presence': 'installed',
      'bytes_done': 240407632,
      'bytes_total': 240407632,
    });
    expect(result['elapsedMilliseconds'], isA<int>());
    expect(attempts, hasLength(3));
    expect(attempts.take(2).every((attempt) => attempt['ok'] == false), isTrue);
    expect(attempts.last['ok'], isTrue);
  });

  test('validates polling bounds', () async {
    expect(
      () => runDeviceMacroLocalHttpAssert(Dio(), {
        'url': 'http://127.0.0.1:8002/health',
        'expectedStatus': 200,
        'retryUntilSeconds': 3601,
      }),
      throwsFormatException,
    );
    expect(
      () => runDeviceMacroLocalHttpAssert(Dio(), {
        'url': 'http://127.0.0.1:8002/health',
        'expectedStatus': 200,
        'retryIntervalSeconds': 0,
      }),
      throwsFormatException,
    );
  });
}
