import 'dart:convert';

import 'package:dio/dio.dart';

import 'terminal_macro.dart';

class MacroSyncSnapshot {
  const MacroSyncSnapshot({
    required this.macros,
    required this.usageCounts,
    this.updatedAt,
  });

  final List<TerminalMacro> macros;
  final Map<String, int> usageCounts;
  final String? updatedAt;

  factory MacroSyncSnapshot.fromJson(Map<String, dynamic> json) {
    final rawMacros = json['macros'];
    final macros = rawMacros is List
        ? rawMacros
              .whereType<Map>()
              .map(
                (item) =>
                    TerminalMacro.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((macro) => macro.name.trim().isNotEmpty)
              .toList()
        : <TerminalMacro>[];
    final rawCounts = json['usageCounts'];
    final usageCounts = rawCounts is Map
        ? rawCounts.map(
            (key, value) => MapEntry(
              key.toString(),
              value is int ? value : int.tryParse(value.toString()) ?? 0,
            ),
          )
        : <String, int>{};
    return MacroSyncSnapshot(
      macros: macros,
      usageCounts: usageCounts,
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'macros': macros.map((macro) => macro.toJson()).toList(),
      'usageCounts': usageCounts,
    };
  }
}

class MacroSyncService {
  static const _path = '/macros';
  static const _syncPath = '/macros/sync';

  static String _baseUrl(String serverUrl) {
    return serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
  }

  static Map<String, dynamic>? _asJsonMap(Object? data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  static Future<MacroSyncSnapshot?> fetch(Dio dio, String serverUrl) async {
    final base = _baseUrl(serverUrl);
    if (base.isEmpty) return null;
    try {
      final resp = await dio.get(
        '$base$_path',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (resp.statusCode != 200) return null;
      final json = _asJsonMap(resp.data);
      return json == null ? null : MacroSyncSnapshot.fromJson(json);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  static Future<bool> sync(
    Dio dio,
    String serverUrl, {
    required List<TerminalMacro> macros,
    required Map<String, int> usageCounts,
  }) async {
    final base = _baseUrl(serverUrl);
    if (base.isEmpty) return false;
    final snapshot = MacroSyncSnapshot(
      macros: macros,
      usageCounts: usageCounts,
    );
    final resp = await dio.post(
      '$base$_syncPath',
      data: snapshot.toJson(),
      options: Options(
        headers: {'Content-Type': 'application/json'},
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    return resp.statusCode == 200;
  }
}
