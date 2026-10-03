import 'dart:convert';
import 'package:devota/zero_tier_recovery.dart';
import 'package:devota/terminal_macro.dart';
import 'package:devota/device_macro_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'disconnected relay does not prevent local recovery; permissions do',
    () {
      expect(
        zeroTierRecoveryReadiness({
          'connected': false,
          'wholeDeviceAllowed': true,
          'accessibility': {'enabled': true},
        }),
        isNull,
      );
      expect(
        zeroTierRecoveryReadiness({'wholeDeviceAllowed': false}),
        contains('did not start'),
      );
      expect(
        zeroTierRecoveryReadiness({'wholeDeviceAllowed': true}),
        contains('Accessibility'),
      );
    },
  );
  test(
    'cached recovery removes delayed foreground assertion and polls online',
    () {
      final macro = TerminalMacro(
        id: 'recovery',
        name: zeroTierRecoveryMacroName,
        steps: [
          TerminalMacroStep(
            id: 'zt-on',
            type: TerminalMacroStepType.device,
            value: jsonEncode({
              'action': 'tapUi',
              'args': {
                'selector': {'checked': false},
              },
              'expect': {'activePackage': 'com.zerotier.one'},
            }),
            delaySeconds: 8,
          ),
          TerminalMacroStep(
            id: 'zt-online',
            type: TerminalMacroStepType.device,
            value: jsonEncode({'action': 'assertUi'}),
            delaySeconds: 0,
          ),
        ],
      );
      final repaired = repairZeroTierRecoveryMacro(macro);
      expect(repaired.steps.first.delaySeconds, 0);
      expect(
        DeviceMacroStepSpec.parse(repaired.steps.first.value).expect,
        isEmpty,
      );
      expect(repaired.steps[1].id, 'zt-reopen');
      final online = DeviceMacroStepSpec.parse(repaired.steps.last.value);
      expect(online.action, 'waitUi');
      expect(online.args['timeoutSeconds'], 60);
      expect(online.expect['textExcludes'], ['OFFLINE']);
      expect(
        repairZeroTierRecoveryMacro(repaired).steps.length,
        repaired.steps.length,
      );
      expect(
        repairZeroTierRecoveryMacro(macro.copyWith(name: 'Other')).steps.length,
        2,
      );
    },
  );
}
