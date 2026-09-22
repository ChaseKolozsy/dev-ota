// Isolated emulator entry point: the real SSH settings/setup UI, fixture only.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:devota/ssh_terminal_tab.dart';
import 'package:devota/terminal_macro.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ssh_host', '127.0.0.1');
  await prefs.setString('ssh_port', '22222');
  await prefs.setString('ssh_username', 'fixture');
  await prefs.setBool('ssh_use_private_key', false);
  await prefs.setBool('terminal_background_battery_ask', true);
  // Each setup fixture starts unbound so auto-detection and Save are exercised.
  await prefs.remove('terminal_watch:fixture@127.0.0.1:22222');
  const storage = FlutterSecureStorage();
  await storage.write(
    key: 'ssh_profile:127.0.0.1:22222:password',
    value: 'fixture-only',
  );
  // Each fixture run owns a fresh host key. Only this throwaway app's key.
  await storage.delete(key: 'ssh_profile:127.0.0.1:22222:host_key');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: SshTerminalTab(
            dio: Dio(),
            serverUrl: 'http://127.0.0.1:22223',
            notificationMacros: [
              TerminalMacro(
                id: 'hello',
                name: 'Hello fixture',
                steps: const [
                  TerminalMacroStep(
                    id: 'text',
                    type: TerminalMacroStepType.shell,
                    value: ":call append('\$', 'hello')",
                    delaySeconds: 0,
                  ),
                  TerminalMacroStep(
                    id: 'write',
                    type: TerminalMacroStepType.shell,
                    value: ':w',
                    delaySeconds: 0.3,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
