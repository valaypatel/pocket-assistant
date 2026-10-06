import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Android shows no permission popup, and refuses to start a service, for anything the
// manifest does not declare. Flutter tests never compile the Android side, so this
// guards what the phone recorder needs.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();

  test('declares the microphone permissions the phone recorder needs', () {
    expect(manifest, contains('android.permission.RECORD_AUDIO'));
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'),
    );
  });

  test('declares the recorder as a microphone service', () {
    final service = RegExp(
      r'<service[^>]*PhoneRecorderService[^>]*/>',
      dotAll: true,
    ).firstMatch(manifest);
    expect(service, isNotNull);
    expect(service!.group(0), contains('foregroundServiceType="microphone"'));
    expect(service.group(0), contains('android:exported="false"'));
  });

  test('declares the relay service and its restart receiver', () {
    expect(manifest, contains('.CircuitRelayService'));
    expect(manifest, contains('.RelayRestartReceiver'));
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
  });
}
