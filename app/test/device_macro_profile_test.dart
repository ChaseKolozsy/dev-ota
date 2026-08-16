import 'package:devota/device_macro_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const revvl7 = {
    'profile': 'revvl7pro-android36-1080x2436',
    'models': ['TMRV07P5G', 'sdk_gphone64_x86_64'],
    'androidSdk': 36,
    'shortSidePx': 1080,
    'longSidePx': 2436,
    'densityDpi': 480,
  };
  const physical = {
    'model': 'TMRV07P5G',
    'androidSdk': 36,
    'shortSidePx': 1080,
    'longSidePx': 2436,
    'densityDpi': 480,
  };

  test('accepts the physical REVVL 7 Pro profile', () {
    expect(() => assertDeviceMacroProfile(revvl7, physical), returnsNormally);
  });

  test('accepts an emulator deliberately tuned to the same profile', () {
    expect(
      () => assertDeviceMacroProfile(revvl7, {
        ...physical,
        'model': 'sdk_gphone64_x86_64',
      }),
      returnsNormally,
    );
  });

  test('fails before actions on a mismatched device', () {
    expect(
      () => assertDeviceMacroProfile(revvl7, {...physical, 'longSidePx': 2400}),
      throwsStateError,
    );
    expect(
      () => assertDeviceMacroProfile({'profile': 'label-only'}, physical),
      throwsFormatException,
    );
  });
}
