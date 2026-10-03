import 'dart:typed_data';
import 'package:devota/ssh_terminal_tab.dart';
import 'package:devota/terminal_profiles.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Picker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'setup.txt',
      size: 4,
      bytes: Uint8List.fromList([116, 101, 115, 116]),
    ),
  ]);
}

class _Uploads implements HttpClientAdapter {
  final requests = <Uri>[];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      '{"terminalText":"/home/chase/.devota-cache/terminal-uploads/setup.txt"}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  for (final configured in [true, false]) {
    testWidgets(
      'attachment uses its terminal computer server: configured=$configured',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final oldPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = _Picker();
        addTearDown(() => FilePickerPlatform.instance = oldPicker);
        final uploads = _Uploads();
        final writes = <String>[];
        final first = TerminalProfile(
          id: 'first',
          name: 'Desktop',
          host: 'desktop',
          serverUrl: configured ? 'http://desktop:8082' : '',
        );
        const second = TerminalProfile(
          id: 'second',
          name: 'Palm',
          host: 'palm',
          serverUrl: 'http://palm:8084',
        );
        // A retained Desktop session must never upload to the selected Palm server.
        final profiles = TerminalProfiles([first, second], second.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SshTerminalTab(
                dio: Dio()..httpClientAdapter = uploads,
                serverUrl: second.serverUrl,
                profiles: profiles,
                profileId: first.id,
                testHooks: SshTerminalTestHooks(sessionSink: writes.add),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Attach file'));
        await tester.pumpAndSettle();
        if (configured) {
          expect(uploads.requests, [
            Uri.parse('http://desktop:8082/terminal/upload'),
          ]);
          expect(
            writes,
            contains('/home/chase/.devota-cache/terminal-uploads/setup.txt'),
          );
        } else {
          expect(uploads.requests, isEmpty);
          expect(
            find.text(
              'Set this computer’s build server in Connect before attaching files.',
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
