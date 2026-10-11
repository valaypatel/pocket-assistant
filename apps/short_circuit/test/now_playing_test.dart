import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

Future<List<String>> _pump(WidgetTester tester, NowPlaying playing) async {
  final calls = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NowPlayingBar(
          playing: playing,
          onPause: () => calls.add('pause'),
          onResume: () => calls.add('resume'),
          onStop: () => calls.add('stop'),
          onSeek: (ms) => calls.add('seek $ms'),
        ),
      ),
    ),
  );
  return calls;
}

void main() {
  group('what the bar shows next', () {
    const start = NowPlaying(title: 'Note');

    test('follows the player while it plays or is paused', () {
      final playing = nextNowPlaying(start, {
        'state': 'playing',
        'positionMs': 4000,
        'durationMs': 30000,
      });
      expect(playing?.positionMs, 4000);
      expect(playing?.durationMs, 30000);
      expect(playing?.paused, isFalse);
      final paused = nextNowPlaying(playing!, {
        'state': 'paused',
        'positionMs': 5000,
        'durationMs': 30000,
      });
      expect(paused?.paused, isTrue);
      expect(paused?.positionMs, 5000);
      expect(paused?.title, 'Note');
    });

    test('goes away when playback is over, however it ended', () {
      for (final state in ['completed', 'stopped', 'idle', null]) {
        expect(
          nextNowPlaying(start, {'state': state}),
          isNull,
          reason: '$state',
        );
      }
      expect(nextNowPlaying(start, null), isNull);
    });
  });

  test('clock text', () {
    expect(nowPlayingClock(0), '0:00');
    expect(nowPlayingClock(65000), '1:05');
    expect(nowPlayingClock(-5), '0:00');
  });

  group('the bar', () {
    testWidgets('shows the note, the time, and pauses and stops', (
      tester,
    ) async {
      final calls = await _pump(
        tester,
        const NowPlaying(
          title: 'Weekly planning',
          positionMs: 12000,
          durationMs: 90000,
        ),
      );
      expect(find.text('Weekly planning'), findsOneWidget);
      expect(find.text('0:12 / 1:30'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await tester.tap(find.byTooltip('Stop'));
      expect(calls, ['pause', 'stop']);
      expect(find.byTooltip('Resume'), findsNothing);
    });

    testWidgets('a long note says which part is playing', (tester) async {
      await _pump(
        tester,
        const NowPlaying(
          title: 'Long meeting',
          positionMs: 12000,
          durationMs: 60000,
          part: 2,
          parts: 4,
        ),
      );
      expect(find.text('Part 2 of 4 · 0:12 / 1:00'), findsOneWidget);
    });

    test('the part is kept as the player reports back', () {
      const start = NowPlaying(title: 'T', part: 3, parts: 5);
      final next = nextNowPlaying(start, {
        'state': 'playing',
        'positionMs': 1000,
        'durationMs': 60000,
      });
      expect(next?.part, 3);
      expect(next?.parts, 5);
    });

    testWidgets('while paused it says so and offers Resume', (tester) async {
      final calls = await _pump(
        tester,
        const NowPlaying(
          title: 'N',
          state: 'paused',
          positionMs: 1000,
          durationMs: 5000,
        ),
      );
      expect(find.textContaining('Paused'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsNothing);
      await tester.tap(find.byTooltip('Resume'));
      expect(calls, ['resume']);
    });

    testWidgets('moving the slider seeks when the finger lifts', (
      tester,
    ) async {
      final calls = await _pump(
        tester,
        const NowPlaying(title: 'N', positionMs: 0, durationMs: 100000),
      );
      final slider = find.byType(Slider);
      final box = tester.getRect(slider);
      await tester.tapAt(Offset(box.left + box.width * .5, box.center.dy));
      await tester.pump();
      expect(calls.length, 1);
      expect(calls.single, startsWith('seek '));
      final target = int.parse(calls.single.split(' ').last);
      expect(target, inInclusiveRange(40000, 60000));
    });

    testWidgets('the slider is off until the length is known', (tester) async {
      await _pump(tester, const NowPlaying(title: 'N'));
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.onChanged, isNull);
    });

    testWidgets('a long title does not push the buttons away', (tester) async {
      await _pump(
        tester,
        NowPlaying(title: 'x' * 400, positionMs: 0, durationMs: 1000),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Stop'), findsOneWidget);
    });
  });
}
