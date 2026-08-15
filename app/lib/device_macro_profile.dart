void assertDeviceMacroProfile(
  Map<String, dynamic> expected,
  Map<String, dynamic> actual,
) {
  final profile = expected['profile']?.toString().trim() ?? '';
  if (profile.isEmpty) {
    throw const FormatException('assertDeviceProfile requires args.profile');
  }

  var constraints = 0;
  final models = expected['models'];
  if (models != null) {
    if (models is! List ||
        models.isEmpty ||
        models.any((value) => value is! String || value.trim().isEmpty)) {
      throw const FormatException(
        'assertDeviceProfile models must be a non-empty string array',
      );
    }
    constraints++;
    final actualModel = actual['model']?.toString() ?? '';
    if (!models.cast<String>().contains(actualModel)) {
      throw StateError(
        '$profile requires model in ${models.join(', ')}, got $actualModel',
      );
    }
  }

  for (final field in const [
    'androidSdk',
    'shortSidePx',
    'longSidePx',
    'densityDpi',
  ]) {
    if (expected[field] == null) continue;
    final wanted = expected[field];
    if (wanted is! int || wanted <= 0) {
      throw FormatException(
        'assertDeviceProfile $field must be a positive integer',
      );
    }
    constraints++;
    final observed = actual[field];
    if (observed != wanted) {
      throw StateError('$profile requires $field=$wanted, got $observed');
    }
  }

  if (constraints == 0) {
    throw const FormatException(
      'assertDeviceProfile requires at least one hardware constraint',
    );
  }
}
