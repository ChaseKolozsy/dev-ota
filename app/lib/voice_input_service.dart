import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class VoiceInputService {
  VoiceInputService(this._dio);

  static const apiKeyStorageKey = 'openai_api_key';

  final Dio _dio;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final AudioRecorder _recorder = AudioRecorder();

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
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
  }

  Future<String?> stopRecording() => _recorder.stop();

  Future<String> transcribe(String filePath, String apiKey) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: 'audio.m4a'),
      'model': 'whisper-1',
    });
    final resp = await _dio.post(
      'https://api.openai.com/v1/audio/transcriptions',
      data: formData,
      options: Options(
        headers: {'Authorization': 'Bearer $apiKey'},
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    return (resp.data['text'] as String? ?? '').trim();
  }

  Future<void> dispose() async {
    await _recorder.dispose();
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
