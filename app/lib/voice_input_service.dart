import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class VoiceInputException implements Exception {
  const VoiceInputException(this.message);
  final String message;
  @override
  String toString() => message;
}

const missingVoiceApiKey =
    'Voice input requires an OpenAI API key. '
    'Use Set OpenAI key in the terminal settings.';

/// Never display raw HTTP bodies or exception strings that may contain keys.
String voiceInputErrorMessage(Object error) {
  if (error is VoiceInputException) return error.message;
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 401) {
      return 'OpenAI rejected the API key or authentication settings. '
          'Check Set OpenAI key in the terminal settings.';
    }
    if (status == 403) {
      return 'OpenAI denied transcription access. Check your API project access and region.';
    }
    if (status == 429) {
      final data = error.response?.data;
      final detail = data is Map ? data['error'] : null;
      final code = detail is Map ? detail['code'] : null;
      if (const {
        'insufficient_quota',
        'credit_balance_exhausted',
        'organization_spend_limit_exceeded',
        'project_spend_limit_exceeded',
        'organization_usage_limit_exceeded',
      }.contains(code)) {
        return 'OpenAI transcription quota or credit limit reached. Check API billing and limits.';
      }
      return 'OpenAI transcription rate limit reached. Wait briefly and try again.';
    }
    if (status == 413) {
      return 'The voice recording is too large. Record a shorter message.';
    }
    if (status != null && status >= 500) {
      return 'OpenAI transcription is temporarily unavailable. Try again shortly.';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return 'Voice transcription timed out. Check your connection and try again.';
    }
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.badCertificate) {
      return 'Could not connect securely to OpenAI. Check your internet connection.';
    }
    return 'OpenAI could not transcribe the recording. Check your API settings and try again.';
  }
  return 'Voice input failed. Check microphone permission and try again.';
}

class VoiceInputService {
  VoiceInputService(this._dio);

  static const apiKeyStorageKey = 'openai_api_key';

  final Dio _dio;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  AudioRecorder? _recorder;

  Future<String?> loadApiKey() => _storage.read(key: apiKeyStorageKey);

  Future<void> saveApiKey(String key) =>
      _storage.write(key: apiKeyStorageKey, value: key);

  Future<bool> requestMicrophone() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> startRecording(String fileName) async {
    final cacheDir = await getTemporaryDirectory();
    final path = '${cacheDir.path}/$fileName';
    final recorder = _recorder ??= AudioRecorder();
    await recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
  }

  Future<String?> stopRecording() async => _recorder?.stop();

  Future<String> transcribe(String? filePath, String? apiKey) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) throw const VoiceInputException(missingVoiceApiKey);
    if (filePath == null ||
        filePath.isEmpty ||
        !await File(filePath).exists() ||
        await File(filePath).length() == 0) {
      throw const VoiceInputException(
        'No audio recording was captured. Try recording again.',
      );
    }
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: 'audio.m4a'),
      'model': 'whisper-1',
    });
    final resp = await _dio.post(
      'https://api.openai.com/v1/audio/transcriptions',
      data: formData,
      options: Options(
        headers: {'Authorization': 'Bearer $key'},
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final data = resp.data;
    if (data is! Map || data['text'] is! String) {
      throw const VoiceInputException(
        'OpenAI returned an invalid transcription response. Try again.',
      );
    }
    final text = (data['text'] as String).trim();
    if (text.isEmpty) {
      throw const VoiceInputException(
        'No speech was recognized. Try recording again.',
      );
    }
    return text;
  }

  Future<void> dispose() async {
    await _recorder?.dispose();
  }

  static Future<void> deleteRecording(String? path) async {
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
