import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final writes = <String>[];
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
  Future<void> status(WidgetTester tester, String value) async {
    await messenger.handlePlatformMessage(
      'circuit/audio_status',
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> open(WidgetTester tester, {String tab = 'Circuit'}) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ShortCircuitApp());
    await tester.pump(const Duration(seconds: 4));
    if (tab == 'Circuit') {
      await tester.tap(find.text('Circuit').last);
      await tester.pump();
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets(
    'pulling down on Notes asks Circuit whether anything is waiting',
    (tester) async {
      await open(tester, tab: 'Notes');
      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 4));
      expect(writes, contains('@audio-sync'));
      await close(tester);
    },
  );

  testWidgets('the Circuit page keeps technical details folded away', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Circuit'), findsWidgets);
    expect(find.text('Bluetooth address'), findsNothing);
    expect(find.text('Wi-Fi MAC address'), findsNothing);
    await close(tester);
  });

  testWidgets('the Circuit page shows the battery Circuit reports', (
    tester,
  ) async {
    await open(tester);
    await status(
      tester,
      '@sync-status\nwaiting=0\nreset=1\nuptime=500\nbat=85',
    );
    expect(find.text('Battery 85%'), findsOneWidget);
    await status(
      tester,
      '@sync-status\nwaiting=0\nreset=1\nuptime=600\nbat=10',
    );
    expect(find.text('Battery 10% · charge soon'), findsOneWidget);
    await close(tester);
  });

  test('the battery icon follows the charge', () {
    expect(batteryIconFor(100), LucideIcons.batteryFull);
    expect(batteryIconFor(60), LucideIcons.batteryMedium);
    expect(batteryIconFor(30), LucideIcons.batteryLow);
    expect(batteryIconFor(5), LucideIcons.batteryWarning);
  });

  testWidgets('a note still waiting for its audio is never called synced', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'circuit_notes': jsonEncode([
        CircuitNote(
          id: 'w',
          createdAt: DateTime.now().subtract(const Duration(seconds: 20)),
          status: 'Recording saved on Circuit.',
          boardId: 77,
        ).toJson(),
      ]),
    });
    await open(tester, tab: 'Notes');
    expect(find.text('1 note is waiting on Circuit'), findsOneWidget);
    expect(find.textContaining('everything is synced'), findsNothing);
    await close(tester);
  });

  testWidgets('while Circuit records, finished minutes are not "waiting"', (
    tester,
  ) async {
    await open(tester, tab: 'Notes');
    await status(tester, 'Recording started');
    // A minute is done on the board: one part waits, but the recording is still going.
    await status(tester, '@sync-status\nwaiting=1\nreset=1\nuptime=500');
    expect(find.text('Circuit is recording'), findsOneWidget);
    expect(find.textContaining('waiting on Circuit'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'each note shows its own sync progress, and the strip has no bar',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'circuit_notes': jsonEncode([
          for (final id in [77, 78])
            CircuitNote(
              id: 'n$id',
              createdAt: DateTime.now().subtract(Duration(seconds: 30 + id)),
              status: 'Recording saved on Circuit.',
              boardId: id,
            ).toJson(),
        ]),
      });
      await open(tester, tab: 'Notes');
      await status(tester, 'Sync started\n1000 bytes');
      await status(tester, 'Sync note #77: 40% (1 of 2)');
      expect(find.text('Syncing 40%'), findsOneWidget);
      // One bar, in the note that is downloading; the other note just waits.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Note 1 of 2'), findsOneWidget);
      expect(find.text('Syncing a voice note'), findsNothing);
      expect(find.text('Waiting to sync'), findsOneWidget);
      await status(tester, 'Sync note #78: 10% (2 of 2)');
      expect(find.text('Syncing 10%'), findsOneWidget);
      await close(tester);
    },
  );
}
