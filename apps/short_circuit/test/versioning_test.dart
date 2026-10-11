import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The app's version must come from CI (or the clock), never from pubspec.yaml or a flag: a
// hand-picked build number above the tester build's once forced an uninstall that wiped the
// app's settings and keys. These checks stop that being undone by accident.
void main() {
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();

  test('the Android version comes from the environment or the clock', () {
    expect(gradle, contains('System.getenv("APP_VERSION_CODE")'));
    expect(gradle, contains('System.getenv("APP_VERSION_NAME")'));
    expect(gradle, isNot(contains('flutter.versionCode')));
    expect(gradle, isNot(contains('flutter.versionName')));
  });

  test(
    'the build workflow sets the version and passes no number of its own',
    () {
      final workflow = File('../../.github/workflows/app.yml')
          .readAsStringSync();
      expect(workflow, contains('APP_VERSION_CODE'));
      expect(workflow, contains('APP_VERSION_NAME'));
      expect(workflow, isNot(contains('--build-number')));
      expect(workflow, isNot(contains('--build-name')));
    },
  );
}
