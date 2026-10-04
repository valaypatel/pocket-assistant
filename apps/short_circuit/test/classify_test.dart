import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:short_circuit/main.dart';

Uint8List _wav(int seconds, {int rate = 16000, int channels = 1}) {
  final frame = channels * 2;
  final size = seconds * rate * frame;
  final out = Uint8List(44 + size);
  final view = ByteData.sublistView(out);
  void put(int at, String text) => out.setRange(at, at + 4, text.codeUnits);
  put(0, 'RIFF');
  view.setUint32(4, 36 + size, Endian.little);
  put(8, 'WAVE');
  put(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, rate, Endian.little);
  view.setUint32(28, rate * frame, Endian.little);
  view.setUint16(32, frame, Endian.little);
  view.setUint16(34, 16, Endian.little);
  put(36, 'data');
  view.setUint32(40, size, Endian.little);
  // A ramp, so a slice can be told apart from the start of the clip.
  for (var i = 44; i < out.length; i++) {
    out[i] = (i ~/ (rate * frame)) % 251;
  }
  return out;
}

void main() {
  group('wavSample', () {
    test('a long recording becomes a 12 second WAV from the middle', () {
      final long = _wav(60);
      final sample = wavSample(long);
      expect(sample.length, 44 + 12 * 16000 * 2);
      expect(String.fromCharCodes(sample, 0, 4), 'RIFF');
      final view = ByteData.sublistView(sample);
      expect(view.getUint32(4, Endian.little), sample.length - 8);
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(40, Endian.little), 12 * 16000 * 2);
      // Starts 24 s in (the middle of 60 s minus half of 12 s), not at 0.
      expect(sample[44], 24);
    });

    test('a clip near the target length is left alone', () {
      final clip = _wav(13);
      expect(identical(wavSample(clip), clip), isTrue);
    });

    test('stereo and other rates keep their format', () {
      final sample = wavSample(_wav(40, rate: 44100, channels: 2));
      final view = ByteData.sublistView(sample);
      expect(view.getUint16(22, Endian.little), 2);
      expect(view.getUint32(24, Endian.little), 44100);
      expect(sample.length, 44 + 12 * 44100 * 4);
    });

    test('anything that is not a WAV is returned unchanged', () {
      final junk = Uint8List.fromList(List.filled(100000, 7));
      expect(identical(wavSample(junk), junk), isTrue);
      final tiny = Uint8List.fromList([1, 2, 3]);
      expect(identical(wavSample(tiny), tiny), isTrue);
    });

    test('a truncated header does not throw', () {
      final cut = Uint8List.sublistView(_wav(60), 0, 30);
      expect(() => wavSample(cut), returnsNormally);
    });
  });

  group('Gemini answer', () {
    test('plain speech stays a spoken note', () {
      final result = GeminiClient.parseTranscriptionText(
        'Call the plumber tomorrow.',
      );
      expect(result.isMusic, isFalse);
      expect(result.transcript, 'Call the plumber tomorrow.');
    });

    test('the music marker makes it a song with no transcript', () {
      final result = GeminiClient.parseTranscriptionText('[[MUSIC]]');
      expect(result.isMusic, isTrue);
      expect(result.transcript, isEmpty);
    });

    test('the noise marker and empty answers mean no speech', () {
      for (final answer in ['[[NOISE]]', '', '   ', null]) {
        expect(
          () => GeminiClient.parseTranscriptionText(answer),
          throwsA(predicate((e) => e.toString().contains('No speech'))),
        );
      }
    });

    test('a note that merely mentions music is not a song', () {
      final result = GeminiClient.parseTranscriptionText(
        'Buy tickets for the music festival.',
      );
      expect(result.isMusic, isFalse);
    });
  });

  test('copyWith can turn a voice note into a song note', () {
    final voice = CircuitNote(id: '1', createdAt: DateTime(2026), status: 'x');
    final song = voice.copyWith(kind: 'song', song: const SongResult());
    expect(song.isSong, isTrue);
    expect(song.copyWith(status: 'y').isSong, isTrue);
    expect(voice.isSong, isFalse);
  });

  group('RecordingView', () {
    Future<void> pump(
      WidgetTester tester, {
      required double width,
      required bool song,
      Duration elapsed = const Duration(seconds: 10),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      // Same wrapper as the app: Scaffold hands its body loose constraints.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildScTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SafeArea(
              bottom: false,
              child: RecordingView(
                elapsed: elapsed,
                song: song,
                busy: false,
                onStop: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // The test font is far wider than the real one, so at scale 1 every line
    // wraps and fills the width. At 0.35 the lines are short, like the real
    // screen, which is when a shrink-wrapped column hugs the left edge.
    for (final scale in [1.0, 0.35]) {
      for (final width in [320.0, 360.0, 411.0, 600.0]) {
        for (final song in [false, true]) {
          testWidgets(
            'is centred at ${width.toInt()}dp, song=$song, text x$scale',
            (tester) async {
              await pump(tester, width: width, song: song, textScale: scale);
              expect(tester.takeException(), isNull);
              final centre = width / 2;
              for (final finder in [
                find.text(
                  song ? 'Listening for a song' : 'Recording on Circuit',
                ),
                find.text(song ? '00:02' : '00:10'),
                find.textContaining(song ? 'Hold Circuit' : 'Speak naturally'),
                find.byTooltip(
                  song ? 'Stop listening early' : 'Stop recording',
                ),
                find.byIcon(song ? LucideIcons.music : LucideIcons.circle),
              ]) {
                expect(finder, findsOneWidget);
                expect(
                  tester.getCenter(finder).dx,
                  closeTo(centre, 1),
                  reason: '$finder is off centre at ${width}dp',
                );
              }
            },
          );
        }
      }
    }

    testWidgets('a song clip counts down and a note counts up', (tester) async {
      await pump(
        tester,
        width: 360,
        song: true,
        elapsed: const Duration(seconds: 3),
      );
      expect(find.text('00:09'), findsOneWidget);
      await pump(
        tester,
        width: 360,
        song: false,
        elapsed: const Duration(seconds: 3),
      );
      expect(find.text('00:03'), findsOneWidget);
    });

    testWidgets('after 12 seconds it says it is finishing', (tester) async {
      await pump(
        tester,
        width: 360,
        song: true,
        elapsed: const Duration(seconds: 13),
      );
      expect(find.text('Finishing up…'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
    });
  });
}
