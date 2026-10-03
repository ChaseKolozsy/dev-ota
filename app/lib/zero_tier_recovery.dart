import 'dart:convert';
import 'terminal_macro.dart';

String? zeroTierRecoveryReadiness(Map<String, dynamic> status) {
  if (status['wholeDeviceAllowed'] != true) {
    return 'ZeroTier recovery did not start. In Agent, enable whole-device '
        'control and restart the Agent to apply it.';
  }
  if (status['accessibility'] is! Map ||
      (status['accessibility'] as Map)['enabled'] != true) {
    return 'ZeroTier recovery did not start. Enable DevOTA in Android '
        'Accessibility settings.';
  }
  return null;
}

/// Upgrade the shipped recovery definition even when only its cached copy is
/// available. Never rewrite a different macro or a user-authored step.
TerminalMacro repairZeroTierRecoveryMacro(TerminalMacro macro) {
  if (macro.name != zeroTierRecoveryMacroName || !macro.isDeviceMacro) {
    return macro;
  }
  const package = 'com.zerotier.one';
  final steps = <TerminalMacroStep>[];
  for (final step in macro.steps) {
    if (step.id == 'zt-on') {
      final value = Map<String, dynamic>.from(jsonDecode(step.value) as Map);
      value.remove('expect');
      steps.add(step.copyWith(value: jsonEncode(value), delaySeconds: 0));
    } else if (step.id == 'zt-online' || step.id == 'zt-offline') {
      final online = step.id == 'zt-online';
      if (online && !macro.steps.any((s) => s.id == 'zt-reopen')) {
        steps.add(
          TerminalMacroStep(
            id: 'zt-reopen',
            type: TerminalMacroStepType.device,
            value: jsonEncode({
              'action': 'launchApp',
              'args': {'packageName': package},
              'capture': true,
              'label': 'Reopen ZeroTier to verify network state',
            }),
            delaySeconds: 1,
          ),
        );
      }
      steps.add(
        step.copyWith(
          value: jsonEncode({
            'action': 'waitUi',
            'args': {
              'packageName': package,
              'timeoutSeconds': online ? 60 : 15,
              'intervalMs': 500,
            },
            'expect': {
              'activePackage': package,
              'textIncludes': [online ? 'ONLINE' : 'OFFLINE'],
              if (online) 'textExcludes': ['OFFLINE'],
            },
            'capture': true,
            'label': online
                ? 'Wait until ZeroTier is online'
                : 'Wait until ZeroTier is offline',
          }),
          delaySeconds: 0,
        ),
      );
    } else {
      steps.add(step);
    }
  }
  return macro.copyWith(steps: steps);
}
