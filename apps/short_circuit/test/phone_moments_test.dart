import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

/// A plain 16 kHz mono 16-bit WAV [seconds] long (44-byte header), enough for part lengths.
File _wav(Directory dir, String name, int seconds) {
  const rate = 16000;
  final data = rate * 2 * seconds;
  final bytes = ByteData(44 + data);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + data, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, data, Endian.little);
  return File('${dir.path}/$name')
    ..writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  test('moments added on the phone survive a save', () {
    final note = CircuitNote(
      id: 'p',
      createdAt: DateTime(2026, 10, 13),
      status: 'Saved on this phone.',
      ownMoments: const [12000, 75000],
    );
    final back = CircuitNote.fromJson(
      jsonDecode(jsonEncode(note.toJson())) as Map<String, dynamic>,
    );
    expect(back.ownMoments, [12000, 75000]);
    expect(
      CircuitNote.fromJson({
        'id': 'q',
        'createdAt': '2026-10-01T10:00:00.000',
        'status': 's',
      }).ownMoments,
      isEmpty,
    );
  });

  test('a long phone note gives each part only its own moments', () async {
    final dir = Directory.systemTemp.createTempSync('moments');
    addTearDown(() => dir.deleteSync(recursive: true));
    final first = _wav(dir, 'a.wav', 60).path;
    final second = _wav(dir, 'b.wav', 30).path;
    final note = CircuitNote(
      id: 'p',
      createdAt: DateTime(2026, 10, 13),
      status: 'x',
      audioPath: first,
      audioParts: [first, second],
      ownMoments: const [5000, 59000, 61000, 85000],
    );
    expect(await Moments.forNoteParts(note, 0), [5000, 59000]);
    // The second part starts at 60 s: 61 s is 1 s in, 85 s is 25 s in.
    expect(await Moments.forNoteParts(note, 1), [1000, 25000]);
    expect(await Moments.allForNote(note), [5000, 59000, 61000, 85000]);
  });

  testWidgets('the recording bar has a Moment button that can be tapped', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildScTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: CaptureDock(
                mode: DockMode.recording,
                title: 'Recording · 1 Moment',
                elapsed: () => const Duration(seconds: 20),
                onMoment: () => taps++,
                onStop: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Recording · 1 Moment'), findsOneWidget);
    await tester.tap(find.byTooltip('Add a Moment'));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
