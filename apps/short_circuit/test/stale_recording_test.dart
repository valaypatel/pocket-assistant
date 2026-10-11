import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> status(WidgetTester tester, String value) async {
    await messenger.handlePlatformMessage(
      'circuit/audio_status',
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await tester.pump();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    for (final name in [
      'circuit/audio_status',
      'circuit/phone_recorder_events',
      'circuit/phone_recorder',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(const MethodChannel('circuit/relay'), (
      call,
    ) async {
      return switch (call.method) {
        'write' => true,
        'status' => 'Connected to Circuit',
        'syncedNotes' => <String>[],
        'requestLocalNetwork' => true,
        _ => null,
      };
    });
  });

  testWidgets(
    'a recording pill left over from a restart is cleared by the board',
    (tester) async {
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 4));
      await status(tester, 'Recording started');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Recording on Circuit'), findsOneWidget);

      // The board restarted: it says nothing about the recording, then reports it is idle.
      await status(
        tester,
        '@sync-status\nplayback=idle\nplayback_ms=0\nplayback_stop=1\nrecording=idle',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(
        const Duration(milliseconds: 500),
      ); // the pill fades out
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Recording on Circuit'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets('a board that is still recording keeps its pill', (tester) async {
    await tester.pumpWidget(const ShortCircuitApp());
    await tester.pump(const Duration(seconds: 4));
    await status(tester, 'Recording started');
    await tester.pump(const Duration(milliseconds: 400));
    await status(
      tester,
      '@sync-status\nplayback=idle\nplayback_ms=0\nplayback_stop=1\nrecording=recording',
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Recording on Circuit'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
