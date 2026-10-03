import 'package:devota/ssh_terminal_tab.dart';
import 'package:devota/voice_input_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedKeyVoice extends VoiceInputService {
  SavedKeyVoice(this.failure, {this.stopError}) : super(Dio());
  final Object failure;
  final Object? stopError;
  bool stopped = false;
  @override
  Future<String?> loadApiKey() async => 'saved-test-key';
  @override
  Future<bool> requestMicrophone() async => true;
  @override
  Future<void> startRecording(String fileName) async {}
  @override
  Future<String?> stopRecording() async {
    stopped = true;
    if (stopError != null) throw stopError!;
    return null;
  }

  @override
  Future<String> transcribe(String? filePath, String? apiKey) async {
    expect(apiKey, 'saved-test-key');
    throw failure;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets(
    'recorder stop failure is visible and leaves Stop available to retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final voice = SavedKeyVoice(
        Exception('unused'),
        stopError: Exception('stop failed'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshTerminalTab(
              dio: Dio(),
              serverUrl: '',
              quickCommands: const [],
              quickMacros: const [],
              testHooks: SshTerminalTestHooks(
                sessionSink: (_) {},
                voiceInput: voice,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('Voice input failed'),
        ),
        findsOneWidget,
      );
      final stop = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton && widget.tooltip == 'Stop recording',
        ),
      );
      expect(stop.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'saved key with rejected request shows error and restores record controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final voice = SavedKeyVoice(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 401,
            data: {
              'error': {'message': 'private saved-test-key'},
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshTerminalTab(
              dio: Dio(),
              serverUrl: '',
              quickCommands: const [],
              quickMacros: const [],
              testHooks: SshTerminalTestHooks(
                sessionSink: (_) {},
                voiceInput: voice,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      expect(find.text('OpenAI API Key'), findsNothing);
      expect(find.byTooltip('Stop recording'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(voice.stopped, isTrue);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('OpenAI rejected'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('saved-test-key'), findsNothing);
      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'canceling key entry reports missing key and restores record button',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshTerminalTab(
              dio: Dio(),
              serverUrl: '',
              quickCommands: const [],
              quickMacros: const [],
              testHooks: SshTerminalTestHooks(sessionSink: (_) {}),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('OpenAI API Key'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(missingVoiceApiKey),
        ),
        findsOneWidget,
      );
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Voice input',
        ),
      );
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
