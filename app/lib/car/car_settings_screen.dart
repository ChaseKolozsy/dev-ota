import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'car_buttons.dart';
import 'car_channel.dart';
import 'car_session.dart';
import 'car_settings.dart';

/// Terminal → SSH settings → Car control (proposal §4.2). A normal touch UI
/// for when parked. While car mode runs it shows a single "settings are for
/// when parked" card; the one exception is the master switch (§4.3).
class CarSettingsScreen extends StatefulWidget {
  const CarSettingsScreen({super.key, required this.session});
  final CarSession session;

  @override
  State<CarSettingsScreen> createState() => _CarSettingsScreenState();
}

class _CarSettingsScreenState extends State<CarSettingsScreen> {
  CarSession get session => widget.session;
  CarSettings get s => session.settings;

  @override
  void initState() {
    super.initState();
    session.addListener(_changed);
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _set(CarSettings next) => session.update(next);

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    await Permission.notification.request();
    if (!mic.isGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is needed for dictation.')),
      );
    }
    await session.startCarMode(withMic: mic.isGranted);
  }

  Future<void> _chooseCar() async {
    final permission = await Permission.bluetoothConnect.request();
    if (!permission.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bluetooth permission is needed to pick the car.')),
        );
      }
      return;
    }
    final devices = await session.channel.bondedDevices();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Car Bluetooth device'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('None — start car mode by hand'),
          ),
          for (final d in devices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, d['address']),
              child: Text('${d['name']?.isNotEmpty == true ? d['name'] : 'Unnamed'}  ·  ${d['address']}'),
            ),
          if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No paired Bluetooth devices found.'),
            ),
        ],
      ),
    );
    if (picked != null) await _set(s.copyWith(autoDevice: picked));
  }

  Widget _dropdown<T>(String title, T value, List<T> values, String Function(T) label, ValueChanged<T> onChanged) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      trailing: DropdownButton<T>(
        value: value,
        items: [for (final v in values) DropdownMenuItem(value: v, child: Text(label(v)))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final panes = session.target.panes();
    return Scaffold(
      appBar: AppBar(title: const Text('Car control')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Car button control'),
            subtitle: const Text(
              'Steering-wheel buttons and voice, eyes-free. Off: DevOTA behaves exactly as before.',
            ),
            value: s.enabled,
            onChanged: (v) => _set(s.copyWith(enabled: v)),
          ),
          if (session.message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(session.message!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (s.enabled && session.running) ...[
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.directions_car, size: 48),
                    const SizedBox(height: 8),
                    Text('Car mode on — settings are for when parked.',
                        textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.stop),
                      label: const Text('Car mode off'),
                      onPressed: () => session.stopCarMode(),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (s.enabled) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.directions_car),
                  label: const Text('Start car mode'),
                  onPressed: session.probing ? null : _start,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.hearing),
                  label: const Text('Button learning (car probe)'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => CarProbeScreen(session: session),
                  )),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.gamepad_outlined),
                  label: const Text('Buttons'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => CarButtonMapScreen(session: session),
                  )),
                ),
              ],
            ),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-on with car'),
              subtitle: Text(s.autoDevice.isEmpty ? 'Off — start by hand' : s.autoDevice),
              trailing: const Icon(Icons.bluetooth),
              onTap: _chooseCar,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dictation (|◀◀, pick-up, voice button)'),
              value: s.dictationEnabled,
              onChanged: (v) => _set(s.copyWith(dictationEnabled: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Voice commands'),
              subtitle: const Text('Double press, play/pause double-tap, or say "command …"'),
              value: s.commandsEnabled,
              onChanged: (v) => _set(s.copyWith(commandsEnabled: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Spoken feedback'),
              subtitle: const Text('Car mode will not start without it'),
              value: s.speechEnabled,
              onChanged: (v) => _set(s.copyWith(speechEnabled: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Confirm destructive commands'),
              subtitle: const Text('Recommended on. "Exit" is always confirmed.'),
              value: s.confirmDestructive,
              onChanged: (v) => _set(s.copyWith(confirmDestructive: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Passenger privacy'),
              subtitle: const Text("Don't read terminal text aloud"),
              value: s.privacyMode,
              onChanged: (v) => _set(s.copyWith(privacyMode: v)),
            ),
            const SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Screen navigation via accessibility'),
              subtitle: Text('Not in this build (optional Phase 4).'),
              value: false,
              onChanged: null,
            ),
            const Divider(height: 28),
            _dropdown('Next / previous', s.nextPrevMode, CarNextPrevMode.values, carNextPrevLabel,
                (v) => _set(s.copyWith(nextPrevMode: v, buttonMap: s.buttonMap?.withNextPrevMode(v)))),
            _dropdown('Verbosity', s.verbosity, CarVerbosity.values,
                (v) => '${v.name[0].toUpperCase()}${v.name.substring(1)}', (v) => _set(s.copyWith(verbosity: v))),
            _dropdown('Dictation recognizer', s.dictationRecognizer, CarDictationRecognizer.values,
                carDictationRecognizerLabel, (v) => _set(s.copyWith(dictationRecognizer: v))),
            _dropdown('After hang-up', s.dictationSend, CarDictationSend.values, carDictationSendLabel,
                (v) => _set(s.copyWith(dictationSend: v))),
            _dropdown('Macro confirm', s.macroConfirm, CarMacroConfirm.values, carMacroConfirmLabel,
                (v) => _set(s.copyWith(macroConfirm: v))),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Read-back cap: ${s.readbackMaxWords} words'),
              subtitle: Slider(
                min: 20,
                max: 200,
                divisions: 18,
                value: s.readbackMaxWords.toDouble(),
                onChanged: (v) => _set(s.copyWith(readbackMaxWords: v.round())),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Target window'),
              trailing: DropdownButton<String>(
                value: panes.any((p) => p.id == s.targetPane) ? s.targetPane : '',
                items: [
                  const DropdownMenuItem(value: '', child: Text('First bound')),
                  for (var i = 0; i < panes.length && i < 3; i++)
                    DropdownMenuItem(value: panes[i].id, child: Text('Window ${i + 1} (${panes[i].id})')),
                ],
                onChanged: (v) => _set(s.copyWith(targetPane: v ?? '')),
              ),
            ),
            const SizedBox(height: 8),
            Text('Command mode ends on', style: theme.textTheme.titleSmall),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Saying "done"'),
              value: s.commandEndOnDone,
              onChanged: (v) => _set(s.copyWith(commandEndOnDone: v ?? true)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hang-up'),
              value: s.commandEndOnHangUp,
              onChanged: (v) => _set(s.copyWith(commandEndOnHangUp: v ?? true)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('10 s of silence'),
              value: s.commandEndOnSilence,
              onChanged: (v) => _set(s.copyWith(commandEndOnSilence: v ?? true)),
            ),
            const Divider(height: 28),
            Text('Press timing (enable only what Button learning proved)', style: theme.textTheme.titleSmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Play/pause double-press'),
              subtitle: Text('${s.doublePressMs} ms window; adds that delay to single presses'),
              value: s.playPauseDouble,
              onChanged: (v) => _set(s.copyWith(playPauseDouble: v)),
            ),
            if (s.playPauseDouble)
              Slider(
                min: 250,
                max: 700,
                divisions: 9,
                value: s.doublePressMs.toDouble(),
                onChanged: (v) => _set(s.copyWith(doublePressMs: v.round())),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Play/pause long-press'),
              subtitle: Text('Held ≥ ${s.longPressMs} ms'),
              value: s.playPauseLong,
              onChanged: (v) => _set(s.copyWith(playPauseLong: v)),
            ),
            const Divider(height: 28),
            CarRedialGuardTile(session: session),
            const Divider(height: 28),
            Text('Permissions', style: theme.textTheme.titleSmall),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => Permission.microphone.request(),
                  child: const Text('Microphone'),
                ),
                OutlinedButton(
                  onPressed: () => Permission.bluetoothConnect.request(),
                  child: const Text('Bluetooth'),
                ),
                OutlinedButton(
                  onPressed: () => Permission.notification.request(),
                  child: const Text('Notifications'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The redial guard (steering-wheel proposal §11.1). The Corolla's pick-up
/// button redials the last number it saw, which is DevOTA's stand-in call;
/// without this permission that redial becomes a real carrier call.
class CarRedialGuardTile extends StatefulWidget {
  const CarRedialGuardTile({super.key, required this.session});
  final CarSession session;

  @override
  State<CarRedialGuardTile> createState() => _CarRedialGuardTileState();
}

class _CarRedialGuardTileState extends State<CarRedialGuardTile>
    with WidgetsBindingObserver {
  CarRedialGuardStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The permission dialog pauses the activity; re-read when it closes.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final status = await widget.session.channel.redialGuardStatus();
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status;
    final granted = status?.granted == true;
    final number = status?.number.isNotEmpty == true ? status!.number : '10000000';
    final last = status == null || status.recent.isEmpty ? null : status.recent.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pick-up redial guard', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          granted
              ? 'On. When the car redials $number, DevOTA cancels the carrier call '
                    'and, in car mode, starts dictation. No other call is touched.'
              : 'Off. The car stores DevOTA\'s stand-in call as $number and the '
                    'pick-up button redials it as a REAL carrier call. Allow '
                    '"Call logs" (outgoing calls) so DevOTA can cancel exactly that number.',
          style: TextStyle(color: granted ? null : theme.colorScheme.error),
        ),
        if (status != null && status.cancelled > 0)
          Text(
            'Cancelled ${status.cancelled} redial${status.cancelled == 1 ? '' : 's'}'
            '${last == null ? '' : ', last ${last.number} at ${last.at.hour.toString().padLeft(2, '0')}:${last.at.minute.toString().padLeft(2, '0')}'}.',
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            if (!granted)
              FilledButton.tonal(
                onPressed: () async {
                  await widget.session.channel.requestRedialGuard();
                  await Future<void>.delayed(const Duration(milliseconds: 500));
                  await _refresh();
                },
                child: const Text('Allow redial guard'),
              ),
            TextButton(onPressed: _refresh, child: const Text('Refresh')),
          ],
        ),
      ],
    );
  }
}

/// Car control → Buttons: the editable map of proposal §5.2.
class CarButtonMapScreen extends StatefulWidget {
  const CarButtonMapScreen({super.key, required this.session});
  final CarSession session;

  @override
  State<CarButtonMapScreen> createState() => _CarButtonMapScreenState();
}

class _CarButtonMapScreenState extends State<CarButtonMapScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = widget.session.settings;
    final map = settings.effectiveButtonMap;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buttons'),
        actions: [
          TextButton(
            onPressed: () async {
              await widget.session.update(settings.copyWith(resetButtonMap: true));
              if (mounted) setState(() {});
            },
            child: const Text('Reset to defaults'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final mode in editableCarModes)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(carModeLabel(mode), style: Theme.of(context).textTheme.titleMedium),
                    for (final signal in CarSignal.values)
                      Row(
                        children: [
                          Expanded(child: Text(carSignalLabel(signal))),
                          DropdownButton<CarAction>(
                            value: map.action(mode, signal),
                            items: [
                              for (final a in CarAction.values)
                                DropdownMenuItem(value: a, child: Text(carActionLabel(a))),
                            ],
                            onChanged: (a) async {
                              if (a == null) return;
                              await widget.session.update(
                                settings.copyWith(buttonMap: map.withCell(mode, signal, a)),
                              );
                              if (mounted) setState(() {});
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Car control → Button learning: the Phase 0 car probe (proposal §5.3).
class CarProbeScreen extends StatefulWidget {
  const CarProbeScreen({super.key, required this.session});
  final CarSession session;

  @override
  State<CarProbeScreen> createState() => _CarProbeScreenState();
}

class _CarProbeScreenState extends State<CarProbeScreen> {
  static const _downloads = MethodChannel('io.github.chasekolozsy.devota/control_agent');
  Timer? _poll;
  List<Map<String, dynamic>> _log = const [];
  String _bvraOrder = 'none';
  String? _status;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    widget.session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!widget.session.settings.enabled) return;
    final log = await widget.session.channel.probeLog(limit: 300);
    if (mounted) setState(() => _log = log);
  }

  Future<void> _start() async {
    await Permission.microphone.request();
    await Permission.bluetoothConnect.request();
    await Permission.notification.request();
    await widget.session.startProbe(bvraOrder: _bvraOrder);
  }

  Future<String?> _export() async {
    final path = await widget.session.channel.probeExport();
    if (path == null && mounted) setState(() => _status = 'Export failed.');
    return path;
  }

  Future<void> _saveToDownloads() async {
    final path = await _export();
    if (path == null) return;
    final name = path.split('/').last;
    try {
      final saved = await _downloads.invokeMethod<dynamic>('saveToDownloads', {
        'filename': name,
        'sourcePath': path,
        'mimeType': 'application/x-ndjson',
      });
      setState(() => _status = 'Saved: ${saved is String && saved.isNotEmpty ? saved : 'Downloads/$name'}');
    } catch (error) {
      setState(() => _status = 'Save failed: $error');
    }
  }

  Future<void> _sendToHost() async {
    final path = await _export();
    if (path == null) return;
    final send = widget.session.sendProbeToHost;
    if (send == null) {
      setState(() => _status = 'Connect the SSH terminal first.');
      return;
    }
    try {
      final remote = await send(path);
      setState(() => _status = 'Sent to the build host: $remote');
    } catch (error) {
      setState(() => _status = 'Send failed: $error');
    }
  }

  Future<void> _share() async {
    final path = await _export();
    if (path == null) return;
    final ok = await widget.session.channel.shareFile(path, 'application/x-ndjson');
    if (!ok) setState(() => _status = 'Share failed.');
  }

  String _line(Map<String, dynamic> e) {
    final t = DateTime.fromMillisecondsSinceEpoch((e['t'] as num?)?.toInt() ?? 0);
    final hh = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
    final detail = e['detail'];
    return '$hh  ${e['source']}  ${e['event']}${detail is Map && detail.isNotEmpty ? '  $detail' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Button learning')),
      body: !session.settings.enabled
          ? const Center(child: Text('Turn on Car button control first.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Parked only. Start the probe, then press each steering-wheel button: '
                  'call (short, long, double), hang-up, next, previous, play/pause, volume. '
                  'DevOTA speaks and logs every event it receives. No audio or text is recorded.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Voice-button handling'),
                  subtitle: const Text('Repeat the probe once per option'),
                  trailing: DropdownButton<String>(
                    value: _bvraOrder,
                    items: const [
                      DropdownMenuItem(value: 'none', child: Text('Log only')),
                      DropdownMenuItem(value: 'ack', child: Text('Acknowledge')),
                      DropdownMenuItem(value: 'call', child: Text('Place call')),
                      DropdownMenuItem(value: 'ack_then_call', child: Text('Ack, then call')),
                    ],
                    onChanged: session.probing ? null : (v) => setState(() => _bvraOrder = v ?? 'none'),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    session.probing
                        ? FilledButton.icon(
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop probe'),
                            onPressed: session.stopProbe,
                          )
                        : FilledButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start probe'),
                            onPressed: session.running ? null : _start,
                          ),
                    OutlinedButton(
                      onPressed: session.probing
                          ? () async {
                              final r = await session.channel.probePlaceTestCall();
                              setState(() => _status = r['ok'] == true
                                  ? 'Test call placed. Press hang-up and call on the wheel.'
                                  : 'Test call failed: ${r['error']}');
                            }
                          : null,
                      child: const Text('Place test call'),
                    ),
                    OutlinedButton(
                      onPressed: session.probing ? session.channel.probeEndTestCall : null,
                      child: const Text('End test call'),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.upload),
                      label: const Text('Send to build host'),
                      onPressed: _sendToHost,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text('Save to Downloads'),
                      onPressed: _saveToDownloads,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                      onPressed: _share,
                    ),
                    TextButton(
                      onPressed: () async {
                        await session.channel.probeClear();
                        await _refresh();
                      },
                      child: const Text('Clear log'),
                    ),
                  ],
                ),
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_status!),
                  ),
                const SizedBox(height: 12),
                Text('${_log.length} events', style: theme.textTheme.titleSmall),
                for (final e in _log.reversed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(_line(e), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
              ],
            ),
    );
  }
}
