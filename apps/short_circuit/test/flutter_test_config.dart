import 'dart:async';

import 'package:short_circuit/main.dart';

/// Runs before every test file. The first-run welcome screens are off by default, so tests that start
/// the whole app land on Notes; onboarding_test.dart switches them on for itself.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Onboarding.enabled = false;
  await testMain();
}
