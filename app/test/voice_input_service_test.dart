import 'dart:io';
import 'dart:typed_data';
import 'package:devota/voice_input_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class TranscriptionAdapter implements HttpClientAdapter {
  int calls = 0;
  int status = 200;
  String body = '{"text":"hello terminal"}';
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    expect(options.headers['Authorization'], 'Bearer test-key');
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TranscriptionAdapter adapter;
  late VoiceInputService voice;
  late File audio;
  late Directory directory;
  setUp(() async {
    adapter = TranscriptionAdapter();
    voice = VoiceInputService(Dio()..httpClientAdapter = adapter);
    directory = await Directory.systemTemp.createTemp('devota-voice-test-');
    audio = await File('${directory.path}/audio.m4a').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async => directory.delete(recursive: true));
  test('missing or blank keys fail before reading or sending audio', () async {
    for (final key in [null, '', '   ']) {
      await expectLater(
        voice.transcribe(audio.path, key),
        throwsA(
          isA<VoiceInputException>().having(
            (e) => e.message,
            'message',
            missingVoiceApiKey,
          ),
        ),
      );
    }
    expect(adapter.calls, 0);
  });
  test('missing recording and empty audio cannot silently succeed', () async {
    for (final path in [null, '${directory.path}/missing.m4a']) {
      await expectLater(
        voice.transcribe(path, 'test-key'),
        throwsA(isA<VoiceInputException>()),
      );
    }
    await audio.writeAsBytes([]);
    await expectLater(
      voice.transcribe(audio.path, 'test-key'),
      throwsA(isA<VoiceInputException>()),
    );
    expect(adapter.calls, 0);
  });
  test(
    'empty and malformed responses are explicit failures; valid text survives',
    () async {
      for (final body in ['{"text":"   "}', '{}', '{"text":42}']) {
        adapter.body = body;
        await expectLater(
          voice.transcribe(audio.path, ' test-key '),
          throwsA(isA<VoiceInputException>()),
        );
      }
      adapter.body = '{"text":" hello terminal "}';
      expect(
        await voice.transcribe(audio.path, ' test-key '),
        'hello terminal',
      );
    },
  );
  test(
    'HTTP errors are actionable without exposing key or response body',
    () async {
      for (final status in [401, 403, 429, 413, 500]) {
        adapter.status = status;
        adapter.body = '{"error":{"message":"private-secret-test-key"}}';
        try {
          await voice.transcribe(audio.path, 'test-key');
          fail('Expected HTTP error');
        } catch (error) {
          final message = voiceInputErrorMessage(error);
          expect(message, isNot(contains('private-secret')));
          expect(message, isNot(contains('test-key')));
          if (status == 401) expect(message, contains('API key'));
          if (status == 429) expect(message, contains('rate limit'));
        }
      }
      adapter.status = 429;
      adapter.body = '{"error":{"code":"credit_balance_exhausted"}}';
      try {
        await voice.transcribe(audio.path, 'test-key');
        fail('Expected quota error');
      } catch (error) {
        expect(voiceInputErrorMessage(error), contains('billing'));
      }
    },
  );
  test('timeouts and network failures have clear messages', () {
    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      expect(
        voiceInputErrorMessage(
          DioException(requestOptions: RequestOptions(), type: type),
        ),
        contains('timed out'),
      );
    }
    expect(
      voiceInputErrorMessage(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionError,
        ),
      ),
      contains('internet connection'),
    );
  });
}
