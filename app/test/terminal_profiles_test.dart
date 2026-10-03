import 'dart:convert';
import 'package:devota/backup_service.dart';
import 'package:devota/terminal_profiles.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'ssh_host': 'first.example',
      'ssh_port': '2222',
      'ssh_username': 'first-user',
      'ssh_use_private_key': true,
      'ssh_private_key_name': 'first.pem',
    });
    FlutterSecureStorage.setMockInitialValues({
      'ssh_profile:first.example:2222:password': 'first-password',
      'ssh_profile:first.example:2222:passphrase': 'first-passphrase',
      'ssh_profile:first.example:2222:private_key': 'first-private-key',
      'ssh_profile:first.example:2222:host_key': 'trusted-host',
    });
  });

  test(
    'restored build keeps unified profiles after legacy settings were changed',
    () async {
      const desktop = TerminalProfile(
        id: 'desktop',
        name: 'Desktop',
        host: 'desktop.example',
        username: 'desktop-user',
        serverUrl: 'http://desktop.example:8082',
        agentUrl: 'ws://desktop.example:8083/phone',
      );
      const palm = TerminalProfile(
        id: 'palm',
        name: 'Palm',
        host: 'palm.example',
        username: 'palm-user',
        serverUrl: 'http://palm.example:8084',
        agentUrl: 'ws://palm.example:8083/phone',
      );
      SharedPreferences.setMockInitialValues({
        TerminalProfiles.profilesKey: jsonEncode([
          desktop.toJson(),
          palm.toJson(),
        ]),
        TerminalProfiles.selectedKey: palm.id,
        TerminalProfiles.unifiedKey: true,
        'ssh_host': 'legacy-overwrite.example',
        'active_server': 'http://legacy-overwrite.example:8082',
        'agent_ws_url': 'ws://legacy-overwrite.example:8083/phone',
      });
      FlutterSecureStorage.setMockInitialValues({
        desktop.secretKey('password'): 'desktop-test-password',
        palm.secretKey('password'): 'palm-test-password',
        desktop.secretKey('agent_token'): 'desktop-test-token',
        palm.secretKey('agent_token'): 'palm-test-token',
      });
      final prefs = await SharedPreferences.getInstance();
      final restored = await TerminalProfiles.loadComputers(prefs, storage);
      expect(restored.profiles.map((p) => p.id), ['desktop', 'palm']);
      expect(restored.selected.id, 'palm');
      expect(restored.selected.host, 'palm.example');
      expect(restored.selected.serverUrl, 'http://palm.example:8084');
      expect(restored.selected.agentUrl, 'ws://palm.example:8083/phone');
      for (final profile in [desktop, palm]) {
        expect(
          await storage.read(key: profile.secretKey('password')),
          '${profile.id}-test-password',
        );
        expect(
          await storage.read(key: profile.secretKey('agent_token')),
          '${profile.id}-test-token',
        );
      }
      await restored.save(prefs, storage);
      expect(prefs.getString('ssh_host'), 'palm.example');
      expect(prefs.getString('active_server'), 'http://palm.example:8084');
      expect(prefs.getString('agent_ws_url'), 'ws://palm.example:8083/phone');
    },
  );
  test(
    'migration preserves credentials, key, authentication and host trust',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profiles = await TerminalProfiles.load(prefs, storage);
      expect(profiles.selected.host, 'first.example');
      expect(profiles.selected.username, 'first-user');
      expect(profiles.selected.port, '2222');
      expect(profiles.selected.usePrivateKey, isTrue);
      expect(profiles.selected.privateKeyName, 'first.pem');
      expect(
        await storage.read(key: profiles.selected.secretKey('password')),
        'first-password',
      );
      expect(
        await storage.read(key: profiles.selected.secretKey('passphrase')),
        'first-passphrase',
      );
      expect(
        await storage.read(key: profiles.selected.secretKey('private_key')),
        'first-private-key',
      );
      expect(
        await storage.read(key: 'ssh_profile:first.example:2222:host_key'),
        'trusted-host',
      );
      final reloaded = await TerminalProfiles.load(prefs, storage);
      expect(reloaded.profiles.length, 1);
      expect(
        prefs.getString(TerminalProfiles.profilesKey),
        isNot(contains('first-password')),
      );
    },
  );

  test(
    'two accounts on the same host retain independent secrets and selection',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profiles = await TerminalProfiles.load(prefs, storage);
      const second = TerminalProfile(
        id: 'second',
        name: 'Other computer',
        host: 'first.example',
        port: '2222',
        username: 'second-user',
      );
      profiles.profiles.add(second);
      profiles.selectedId = second.id;
      await profiles.save(
        prefs,
        storage,
        password: 'second-password',
        passphrase: 'second-passphrase',
      );
      await storage.write(
        key: second.secretKey('private_key'),
        value: 'second-private-key',
      );
      var reloaded = await TerminalProfiles.load(prefs, storage);
      expect(reloaded.selected.username, 'second-user');
      expect(reloaded.selected.usePrivateKey, isFalse);
      expect(prefs.getString('ssh_private_key_name'), isNull);
      expect(
        await storage.read(key: reloaded.selected.secretKey('password')),
        'second-password',
      );
      reloaded.selectedId = 'existing';
      await reloaded.save(prefs, storage);
      reloaded = await TerminalProfiles.load(prefs, storage);
      expect(reloaded.selectedId, 'existing');
      expect(
        await storage.read(key: reloaded.selected.secretKey('password')),
        'first-password',
      );
      expect(
        await storage.read(key: reloaded.selected.secretKey('private_key')),
        'first-private-key',
      );
      expect(
        await storage.read(key: second.secretKey('private_key')),
        'second-private-key',
      );
    },
  );

  test('queued edits persist the latest metadata and credentials', () async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await TerminalProfiles.load(prefs, storage);
    final first = profiles.save(prefs, storage, password: 'old');
    profiles.updateSelected(
      const TerminalProfile(
        id: 'existing',
        name: 'Renamed',
        host: 'updated',
        username: 'new-user',
      ),
    );
    final last = profiles.save(prefs, storage, password: 'latest');
    await Future.wait([first, last]);
    final reloaded = await TerminalProfiles.load(prefs, storage);
    expect(reloaded.selected.name, 'Renamed');
    expect(reloaded.selected.host, 'updated');
    expect(
      await storage.read(key: reloaded.selected.secretKey('password')),
      'latest',
    );
  });

  test(
    'backup round trip includes all profiles and secure credentials',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profiles = await TerminalProfiles.load(prefs, storage);
      profiles.profiles.add(
        const TerminalProfile(
          id: 'second',
          name: 'Second',
          host: 'second.example',
          username: 'second-user',
        ),
      );
      profiles.selectedId = 'second';
      await profiles.save(prefs, storage, password: 'second-password');
      final backup = await BackupService.buildBackup();
      final withoutSecrets = await BackupService.buildBackup(
        includeSecrets: false,
      );
      expect(withoutSecrets['secureStorage'], isEmpty);
      expect(
        withoutSecrets['sharedPreferences'].toString(),
        isNot(contains('second-password')),
      );
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await BackupService.importBackup(backup);
      final restored = await TerminalProfiles.load(
        await SharedPreferences.getInstance(),
        storage,
      );
      expect(restored.profiles.length, 2);
      expect(restored.selectedId, 'second');
      expect(
        await storage.read(key: restored.selected.secretKey('password')),
        'second-password',
      );
      expect(
        await storage.read(
          key: restored.profiles.first.secretKey('private_key'),
        ),
        'first-private-key',
      );
    },
  );
  test(
    'saving a background session does not change the selected computer or its credentials',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profiles = await TerminalProfiles.load(prefs, storage);
      const second = TerminalProfile(
        id: 'second',
        name: 'Second',
        host: 'second.example',
        username: 'second-user',
      );
      profiles.profiles.add(second);
      profiles.selectedId = 'second';
      await profiles.save(prefs, storage, password: 'second-password');
      profiles.updateProfile(
        const TerminalProfile(
          id: 'existing',
          name: 'First',
          host: 'first.example',
          port: '2222',
          username: 'first-user',
        ),
      );
      await profiles.save(
        prefs,
        storage,
        credentialProfileId: 'existing',
        password: 'first-new-password',
      );
      expect(prefs.getString(TerminalProfiles.selectedKey), 'second');
      expect(prefs.getString('ssh_host'), 'second.example');
      expect(
        await storage.read(key: second.secretKey('password')),
        'second-password',
      );
      expect(
        await storage.read(key: profiles.profiles.first.secretKey('password')),
        'first-new-password',
      );
    },
  );
  test(
    'migration joins computer settings and preserves credentials and IDs',
    () async {
      const first = TerminalProfile(
        id: 'desktop',
        name: 'Desktop',
        host: 'first.example',
        username: 'chase',
      );
      const second = TerminalProfile(
        id: 'palm',
        name: 'Palm',
        host: 'second.example',
        username: 'chase',
      );
      SharedPreferences.setMockInitialValues({
        TerminalProfiles.profilesKey: jsonEncode([
          first.toJson(),
          second.toJson(),
        ]),
        TerminalProfiles.selectedKey: 'palm',
        'servers': [
          'http://first.example:8082',
          'http://first.example:8083',
          'http://second.example:8084',
          'http://unmatched:8082',
        ],
        'active_server': 'http://first.example:8082',
        'agent_profiles_json': jsonEncode([
          {
            'id': 'old-first',
            'name': 'Agent one',
            'url': 'ws://first.example:8083/phone',
            'token': 'first-token',
            'wholeDevice': true,
          },
          {
            'id': 'old-second',
            'name': 'Agent two',
            'url': 'http://second.example:8083/phone',
            'token': 'second-token',
            'wholeDevice': false,
          },
          {
            'id': 'unmatched',
            'name': 'Third agent',
            'url': 'wss://third.example/phone',
            'token': 'third-token',
            'wholeDevice': false,
          },
        ]),
      });
      FlutterSecureStorage.setMockInitialValues({
        first.secretKey('private_key'): 'first-key',
        second.secretKey('private_key'): 'second-key',
      });
      final prefs = await SharedPreferences.getInstance();
      final profiles = await TerminalProfiles.loadComputers(prefs, storage);
      expect(profiles.profiles.length, 4);
      expect(profiles.selected.id, second.id);
      expect(profiles.selected.serverUrl, 'http://second.example:8084');
      expect(profiles.selected.agentUrl, 'ws://second.example:8083/phone');
      expect(
        await storage.read(key: second.secretKey('private_key')),
        'second-key',
      );
      expect(
        await storage.read(key: second.secretKey('agent_token')),
        'second-token',
      );
      expect(
        await storage.read(key: first.secretKey('agent_token')),
        'first-token',
      );
      expect(profiles.profiles.first.agentWholeDevice, isTrue);
      profiles.updateSelected(profiles.selected.copyWith(name: 'Renamed Palm'));
      await profiles.save(prefs, storage);
      final reloaded = await TerminalProfiles.loadComputers(prefs, storage);
      expect(reloaded.profiles.length, 4);
      expect(reloaded.selected.name, 'Renamed Palm');
      expect(prefs.getString('active_server'), 'http://second.example:8084');
      expect(
        prefs.getString(TerminalProfiles.profilesKey),
        isNot(contains('second-token')),
      );
      final backup = await BackupService.buildBackup();
      expect(
        (backup['sharedPreferences'] as Map)[TerminalProfiles.unifiedKey],
        true,
      );
    },
  );
  test('importing an older backup reruns the computer merge', () async {
    final prefs = await SharedPreferences.getInstance();
    await TerminalProfiles.loadComputers(prefs, storage);
    expect(prefs.getBool(TerminalProfiles.unifiedKey), true);
    await BackupService.importBackup({
      'format': 'devota-backup',
      'sharedPreferences': {
        'ssh_host': 'restored.example',
        'ssh_username': 'restored-user',
        'ssh_port': '22',
        'active_server': 'http://restored.example:8082',
        'servers': ['http://restored.example:8082'],
        'agent_ws_url': 'ws://restored.example:8083/phone',
        'agent_pair_token': 'restored-token',
      },
      'secureStorage': {
        'ssh_profile:restored.example:22:private_key': 'restored-key',
      },
    });
    final restored = await TerminalProfiles.loadComputers(prefs, storage);
    expect(restored.selected.host, 'restored.example');
    expect(restored.selected.username, 'restored-user');
    expect(restored.selected.serverUrl, 'http://restored.example:8082');
    expect(restored.selected.agentUrl, 'ws://restored.example:8083/phone');
    expect(
      await storage.read(key: restored.selected.secretKey('private_key')),
      'restored-key',
    );
    expect(
      await storage.read(key: restored.selected.secretKey('agent_token')),
      'restored-token',
    );
  });
}
