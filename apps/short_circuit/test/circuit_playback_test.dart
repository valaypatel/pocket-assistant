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
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const ShortCircuitApp());
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('Settings').last);
    await tester.pump();
    await tester.tap(find.text('Circuit').first);
    await tester.pump();
    await status(
      tester,
      '@sync-status\nplayback=idle\nplayback_ms=0\nplayback_stop=1',
    );
    await tester.scrollUntilVisible(
      find.byTooltip('Play latest recording on Circuit'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets(
    'playback follows board status beyond six seconds and Stop waits for acknowledgement',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Play latest recording on Circuit'));
      await tester.pump();
      expect(writes.where((v) => v == '@audio-play').length, 1);
      expect(find.text('Requesting playback…'), findsOneWidget);
      await status(tester, 'Playing latest recording');
      await tester.pump(const Duration(seconds: 10));
      expect(find.byTooltip('Stop playback on Circuit'), findsOneWidget);
      expect(find.text('Playing on Circuit'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop playback on Circuit'));
      await tester.pump();
      expect(writes, contains('@audio-play-stop'));
      expect(find.text('Stopping playback…'), findsOneWidget);
      await status(tester, 'Playback stopped');
      expect(
        find.byTooltip('Play latest recording on Circuit'),
        findsOneWidget,
      );
      expect(find.text('Playback stopped'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Playback stopped'), findsOneWidget);
      await close(tester);
    },
  );
  testWidgets(
    'board snapshots recover playback on reopening and missed completion',
    (tester) async {
      await open(tester);
      await status(
        tester,
        '@sync-status\nwaiting=0\nreset=1\nuptime=100\nplayback=playing\nplayback_ms=42000',
      );
      expect(find.byTooltip('Stop playback on Circuit'), findsOneWidget);
      expect(find.text('Playing on Circuit · 0:42'), findsOneWidget);
      await status(
        tester,
        '@sync-status\nwaiting=0\nreset=1\nuptime=110\nplayback=idle\nplayback_ms=0',
      );
      expect(
        find.byTooltip('Play latest recording on Circuit'),
        findsOneWidget,
      );
      expect(find.text('Playback ended on Circuit'), findsOneWidget);
      await close(tester);
    },
  );
  testWidgets(
    'failure and missing acknowledgement do not claim playback started',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Play latest recording on Circuit'));
      await tester.pump();
      await status(tester, 'Playback failed: no recording found');
      expect(find.text('Playback failed: no recording found'), findsOneWidget);
      await tester.tap(find.byTooltip('Play latest recording on Circuit'));
      await tester.pump(const Duration(seconds: 9));
      expect(
        find.text('Circuit did not confirm playback. Try again.'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Play latest recording on Circuit'),
        findsOneWidget,
      );
      await close(tester);
    },
  );
  testWidgets(
    'a Stop timeout keeps playback active until the board reports idle',
    (tester) async {
      await open(tester);
      await status(tester, 'Playing latest recording');
      await tester.tap(find.byTooltip('Stop playback on Circuit'));
      await tester.pump(const Duration(seconds: 9));
      expect(
        find.text('Circuit did not confirm Stop. Try again.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Stop playback on Circuit'), findsOneWidget);
      await status(tester, '@sync-status\nplayback=idle\nplayback_ms=0');
      expect(
        find.byTooltip('Play latest recording on Circuit'),
        findsOneWidget,
      );
      await close(tester);
    },
  );

  testWidgets(
    'old firmware reports playback without offering an unsupported Stop',
    (tester) async {
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 4));
      await tester.tap(find.text('Settings').last);
      await tester.pump();
      await tester.tap(find.text('Circuit').first);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byTooltip('Play latest recording on Circuit'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await status(tester, 'Playing latest recording');
      expect(find.byTooltip('Stop playback on Circuit'), findsNothing);
      expect(find.byTooltip('Playing on Circuit'), findsOneWidget);
      await status(tester, 'Playback complete');
      expect(
        find.byTooltip('Play latest recording on Circuit'),
        findsOneWidget,
      );
      await close(tester);
    },
  );
}
