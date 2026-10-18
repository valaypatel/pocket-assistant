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
  final writes = <String>[];
  Future<void> status(WidgetTester tester, String value) async {
    await messenger.handlePlatformMessage(
      'circuit/audio_status',
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await tester.pump();
  }

  setUp(() {
    writes.clear();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    for (final name in [
      'circuit/audio_status',
      'circuit/phone_recorder_events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(const MethodChannel('circuit/relay'), (
      call,
    ) async {
      if (call.method == 'write') {
        writes.add(call.arguments['value'] as String);
        return true;
      }
      return switch (call.method) {
        'status' => 'Connected to Circuit',
        'syncedNotes' => <String>[],
        'requestLocalNetwork' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('circuit/phone_recorder'),
      (_) async => null,
    );
  });
  Future<void> open(WidgetTester tester, String report) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ShortCircuitApp());
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('Settings').last);
    await tester.pump();
    await tester.tap(find.text('Circuit').first);
    await tester.pump();
    await status(tester, report);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('a board that works on its own hides what needs a live link', (
    tester,
  ) async {
    await open(
      tester,
      '@sync-status\nfw=3.0.1|aaaaaaaa\npm=saver|auto\nmode=sync\nbat=80',
    );
    expect(find.text('Sync mode'), findsOneWidget);
    expect(find.text('Broadcast a message'), findsNothing);
    expect(find.text('Power mode'), findsNothing);
    expect(find.byTooltip('Play latest recording on Circuit'), findsNothing);
    expect(find.text('Record'), findsNothing);
    expect(find.text('Update Circuit'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a board that stays linked keeps every row', (tester) async {
    await open(
      tester,
      '@sync-status\nfw=3.0.1|aaaaaaaa\npm=saver|auto\nmode=connected\nbat=80',
    );
    expect(find.text('Broadcast a message'), findsOneWidget);
    expect(find.text('Power mode'), findsOneWidget);
    await close(tester);
  });

  testWidgets('an older board (no mode) keeps every row', (tester) async {
    await open(
      tester,
      '@sync-status\nfw=2.0.0|aaaaaaaa\npm=saver|auto\nbat=80',
    );
    expect(find.text('Broadcast a message'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a firmware update needs 30% battery and says so', (
    tester,
  ) async {
    await open(
      tester,
      '@sync-status\nfw=3.0.1|aaaaaaaa\npm=saver|auto\nmode=sync\nbat=20',
    );
    expect(find.text('Needs 30% battery · Circuit has 20%'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Update and Reset grey out while a sync is running', (
    tester,
  ) async {
    await open(
      tester,
      '@sync-status\nfw=3.0.1|aaaaaaaa\npm=saver|auto\nmode=sync\nbat=80',
    );
    expect(find.text('Sync running · update when it finishes'), findsNothing);
    await status(tester, 'Sync started\n1000 bytes');
    expect(find.text('Sync running · update when it finishes'), findsOneWidget);
    expect(find.text('Sync running · try when it finishes'), findsOneWidget);
    await status(tester, 'Sync complete: all notes saved');
    await tester.pump();
    expect(find.text('Sync running · update when it finishes'), findsNothing);
    await close(tester);
  });
}
