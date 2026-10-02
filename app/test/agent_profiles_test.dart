import 'package:devota/agent_profiles.dart';
import 'package:devota/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'agent_ws_url': 'ws://original:8083/phone',
      'agent_pair_token': 'original-test-token',
      'agent_whole_device': true,
      'commands': ['keep this command'],
    }),
  );

  test(
    'upgrading preserves the existing connection and other settings',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profiles = await AgentProfiles.load(prefs);
      expect(profiles.selected.name, 'Existing agent');
      expect(profiles.selected.url, 'ws://original:8083/phone');
      expect(profiles.selected.token, 'original-test-token');
      expect(profiles.selected.wholeDevice, isTrue);
      expect(prefs.getStringList('commands'), ['keep this command']);
      final reloaded = await AgentProfiles.load(prefs);
      expect(reloaded.profiles.length, 1);
      expect(reloaded.selected.token, 'original-test-token');
    },
  );

  test(
    'profiles keep independent credentials and selection after restart',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profiles = await AgentProfiles.load(prefs);
      profiles.profiles.add(const AgentProfile(id: 'windows', name: 'Windows'));
      profiles.selectedId = 'windows';
      profiles.updateSelected(
        url: 'ws://windows:8083/phone',
        token: 'windows-test-token',
        wholeDevice: false,
      );
      await profiles.save(prefs);
      final reloaded = await AgentProfiles.load(prefs);
      expect(reloaded.selectedId, 'windows');
      expect(reloaded.selected.wholeDevice, isFalse);
      expect(reloaded.profiles.first.token, 'original-test-token');
      reloaded.selectedId = 'existing';
      await reloaded.save(prefs);
      expect(prefs.getString('agent_ws_url'), 'ws://original:8083/phone');
      expect(prefs.getString('agent_pair_token'), 'original-test-token');
      expect(reloaded.profiles.last.token, 'windows-test-token');
    },
  );

  test('queued edits persist the latest snapshot', () async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await AgentProfiles.load(prefs);
    profiles.updateSelected(
      url: 'ws://first',
      token: 'first',
      wholeDevice: false,
    );
    final first = profiles.save(prefs);
    profiles.updateSelected(url: 'ws://last', token: 'last', wholeDevice: true);
    final last = profiles.save(prefs);
    await Future.wait([first, last]);
    final reloaded = await AgentProfiles.load(prefs);
    expect(reloaded.selected.url, 'ws://last');
    expect(reloaded.selected.token, 'last');
    expect(prefs.getString('agent_ws_url'), 'ws://last');
  });

  test('backup round trip preserves every profile and the selection', () async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await AgentProfiles.load(prefs);
    profiles.profiles.add(
      const AgentProfile(
        id: 'other',
        name: 'Other',
        url: 'ws://other',
        token: 'other-test-token',
      ),
    );
    profiles.selectedId = 'other';
    await profiles.save(prefs);
    final backup = await BackupService.buildBackup(includeSecrets: false);
    await prefs.clear();
    await BackupService.importBackup(backup, includeSecrets: false);
    final reloaded = await AgentProfiles.load(prefs);
    expect(reloaded.selectedId, 'other');
    expect(reloaded.profiles.map((profile) => profile.token), [
      'original-test-token',
      'other-test-token',
    ]);
    expect(prefs.getStringList('commands'), ['keep this command']);
  });
}
