import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

// The same vectors the board and the phone's encryptor are checked against.
final _vectors = jsonDecode(
  File('../../docs/security/test-vectors.json').readAsStringSync(),
) as Map<String, dynamic>;
List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

void main() {
  sheetTests();
  backupTests();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('phone recording key and numbers', () {
    test('makes a key once and keeps it', () async {
      final preferences = await SharedPreferences.getInstance();
      final first = await PhoneRecordingIds.key(preferences);
      final second = await PhoneRecordingIds.key(preferences);
      expect(first.key.length, 32);
      expect(first.keyId, inInclusiveRange(1, 0x7ffffffe));
      expect(second.keyId, first.keyId);
      expect(second.key, first.key);
      // Stored where backup and playback look for note keys.
      expect(await NoteKeys.get(first.keyId), first.key);
    });

    test('never replaces a key, even if the saved id is lost', () async {
      final preferences = await SharedPreferences.getInstance();
      final first = await PhoneRecordingIds.key(preferences);
      await preferences.remove(PhoneRecordingIds.keyPreference);
      final second = await PhoneRecordingIds.key(preferences);
      expect(second.keyId, isNot(first.keyId));
      expect(await NoteKeys.get(first.keyId), first.key); // the old one is kept
    });

    test(
      'a saved id with no key makes a new key and keeps the id free',
      () async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setInt(PhoneRecordingIds.keyPreference, 12345);
        final made = await PhoneRecordingIds.key(preferences);
        expect(made.keyId, isNot(12345));
        expect(await NoteKeys.get(made.keyId), isNotNull);
      },
    );

    test('note numbers only grow, even when the counter is lost', () async {
      final preferences = await SharedPreferences.getInstance();
      final now = DateTime.utc(2026, 10, 6, 12);
      final a = await PhoneRecordingIds.nextNote(preferences, now: now);
      final b = await PhoneRecordingIds.nextNote(preferences, now: now);
      expect(b, a + 1); // two in the same second still differ
      await preferences.remove(PhoneRecordingIds.lastNotePreference);
      final later = await PhoneRecordingIds.nextNote(
        preferences,
        now: now.add(const Duration(seconds: 5)),
      );
      expect(later, greaterThan(b));
    });

    test('a number fits the 32-bit field with decades to spare', () {
      final far = PhoneRecordingIds.numberAfter(0, DateTime.utc(2060));
      expect(far, lessThan(0x7fffffff));
    });
  });

  test('the last part of a recording is remembered as used', () async {
    final preferences = await SharedPreferences.getInstance();
    final now = DateTime.utc(2026, 10, 6, 12);
    final first = await PhoneRecordingIds.nextNote(preferences, now: now);
    final parts = [
      for (var i = 0; i < 30; i++) '/f/phone-note-${first + i}.cnote',
    ];
    await PhoneRecordingIds.markUsed(preferences, parts);
    // Even with the clock set back to before the recording, nothing is reused.
    final next = await PhoneRecordingIds.nextNote(
      preferences,
      now: now.subtract(const Duration(hours: 1)),
    );
    expect(next, first + 30);
    expect(PhoneRecordingIds.numberOfPart('/x/phone-note-77.cnote'), 77);
    expect(PhoneRecordingIds.numberOfPart('/x/circuit-note-1-2.cnote'), isNull);
  });

  test('a cut-short file is measured from its size', () {
    expect(PhoneRecordingIds.audioMillisecondsForFile(28), 0);
    // 10 whole chunks: 10 x 4096 bytes of audio = 1.28 s.
    expect(
      PhoneRecordingIds.audioMillisecondsForFile(28 + 10 * (4096 + 16)),
      1280,
    );
  });

  test('clock text', () {
    expect(phoneRecordingClock(0), '0:00');
    expect(phoneRecordingClock(61000), '1:01');
    expect(phoneRecordingClock(600000), '10:00');
    expect(phoneRecordingClock(3723000), '1:02:03');
  });

  test('says why a recording ended when it was not the person', () {
    expect(phoneRecordingEndMessage('stopped'), isNull);
    expect(phoneRecordingEndMessage('limit'), contains('longest'));
    expect(phoneRecordingEndMessage('storage'), contains('saved'));
    expect(phoneRecordingEndMessage('error'), contains('saved'));
    expect(phoneRecordingFailureMessage('storage'), contains('storage'));
    expect(phoneRecordingFailureMessage('microphone'), contains('microphone'));
  });
}

Future<List<String>> _pumpSheet(
  WidgetTester tester,
  ValueNotifier<Map<String, dynamic>?> recording,
) async {
  final calls = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PhoneRecorderSheet(
          recording: recording,
          onPause: () => calls.add('pause'),
          onResume: () => calls.add('resume'),
          onStop: () => calls.add('stop'),
          onDiscard: () => calls.add('discard'),
        ),
      ),
    ),
  );
  return calls;
}

ValueNotifier<Map<String, dynamic>?> _recording(
  String state,
  int elapsedMs, {
  bool interrupted = false,
}) => ValueNotifier({
  'state': state,
  'elapsedMs': elapsedMs,
  'level': .3,
  'interrupted': interrupted,
});

void sheetTests() {
  group('recorder sheet', () {
    testWidgets('shows the time and pauses, resumes and stops', (tester) async {
      final recording = _recording('recording', 83000);
      final calls = await _pumpSheet(tester, recording);
      expect(find.text('1:23'), findsOneWidget);
      expect(
        find.text('Saved as you go. There is no time limit.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Pause'));
      recording.value = {'state': 'paused', 'elapsedMs': 83000, 'level': 0.0};
      await tester.pump();
      await tester.tap(find.text('Resume'));
      await tester.tap(find.text('Stop and save'));
      expect(calls, ['pause', 'resume', 'stop']);
    });

    testWidgets('a long recording asks before it is discarded', (tester) async {
      final calls = await _pumpSheet(tester, _recording('recording', 30000));
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('Keep recording'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(calls, ['discard']);
    });

    testWidgets('a few seconds is discarded without asking', (tester) async {
      final calls = await _pumpSheet(tester, _recording('recording', 2000));
      await tester.tap(find.text('Discard'));
      await tester.pump();
      expect(calls, ['discard']);
    });

    testWidgets('says so when another app took the microphone', (tester) async {
      await _pumpSheet(tester, _recording('paused', 9000, interrupted: true));
      expect(
        find.text('Paused because another app is using the microphone.'),
        findsOneWidget,
      );
    });

    testWidgets('controls wait until recording has started', (tester) async {
      final calls = await _pumpSheet(tester, _recording('starting', 0));
      await tester.tap(find.text('Stop and save'), warnIfMissed: false);
      await tester.tap(find.text('Pause'), warnIfMissed: false);
      expect(calls, isEmpty);
    });
  });
}

void backupTests() {
  test('a phone recording and its key survive backup and restore', () async {
    final source = Directory.systemTemp.createTempSync('phone_backup_src');
    final target = Directory.systemTemp.createTempSync('phone_backup_dst');
    addTearDown(() {
      source.deleteSync(recursive: true);
      target.deleteSync(recursive: true);
    });
    final keyId = _vectors['keyId'] as int;
    final master = Uint8List.fromList(_hex(_vectors['masterKeyHex'] as String));
    final sealed = Uint8List.fromList(
      _hex((_vectors['cases'] as List).first['fileHex'] as String),
    );
    final pcm = _hex(
      (_vectors['cases'] as List).first['plaintextHex'] as String,
    );

    // A phone recording: its own file name, sealed with a key held as a note key.
    await NoteKeys.save(keyId, master);
    final file = File('${source.path}/phone-note-7.cnote')
      ..writeAsBytesSync(sealed);
    final preferences = await SharedPreferences.getInstance();
    await writeSecretForTest(
      preferences,
      'circuit_notes',
      jsonEncode([
        {
          'id': 'p1',
          'createdAt': '2026-10-06T10:00:00.000',
          'status': 'Saved on this phone.',
          'enrichmentStatus': 'pending',
          'audioPath': file.path,
        },
      ]),
    );
    final data = await BackupStore.collect();
    expect(data.audio.map((a) => a.name), ['phone-note-7.cnote']);
    expect(data.noteKeys.keys, [NoteKeys.hex(keyId)]);

    // A fresh install: nothing but the backup.
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final result = await BackupStore.restore(data, filesDir: target);
    expect(result.notesAdded, 1);
    final restored = File('${target.path}/phone-note-7.cnote');
    expect(restored.existsSync(), isTrue);
    final wav = await readNoteAudio(restored.path);
    expect(wav.sublist(44), pcm);
  });
}
