import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('joining the text of the parts', () {
    test('joins in order and skips silent parts', () {
      expect(
        joinPartTexts(['Hello there.', '', null, 'Next bit.']),
        'Hello there. Next bit.',
      );
      expect(joinPartTexts([null, '']), '');
    });

    test('a new speaker starts a new line', () {
      expect(
        joinPartTexts(['Speaker 1: Hi.', 'Speaker 2: Hello.', 'and more']),
        'Speaker 1: Hi.\nSpeaker 2: Hello. and more',
      );
    });

    test('the earlier text sent along is only the end, cut at a word', () {
      final long = List.generate(400, (i) => 'word$i').join(' ');
      final tail = earlierTextTail([long]);
      expect(tail.startsWith('…'), isTrue);
      expect(tail.length, lessThanOrEqualTo(earlierTextLimit + 2));
      expect(tail.endsWith('word399'), isTrue);
      expect(tail, isNot(contains('word0 ')));
      expect(earlierTextTail(['short text']), 'short text');
      expect(earlierTextTail([]), '');
    });
  });

  group('transcribing the parts in order', () {
    test('sends each part with the text so far, then returns them all', () async {
      final contexts = <String>[];
      final saved = <List<String?>>[];
      final texts = await transcribeParts(
        count: 3,
        done: const [],
        transcribe: (part) async {
          contexts.add('${part.number}/${part.count}:${part.earlier}');
          return 'text${part.number}';
        },
        onProgress: (texts) async => saved.add(texts),
      );
      expect(texts, ['text1', 'text2', 'text3']);
      expect(contexts, ['1/3:', '2/3:text1', '3/3:text1 text2']);
      // Progress is reported after every part, so a crash keeps what was done.
      expect(saved.map((t) => t.where((e) => e != null).length), [1, 2, 3]);
    });

    test(
      'a failure keeps the earlier parts and the next run resumes there',
      () async {
        var saved = <String?>[];
        var calls = <int>[];
        Future<List<String?>> run({required bool failSecond}) =>
            transcribeParts(
              count: 3,
              done: saved,
              transcribe: (part) async {
                calls.add(part.number);
                if (failSecond && part.number == 2)
                  throw Exception('Gemini 503');
                return 'text${part.number}';
              },
              onProgress: (texts) async => saved = texts,
            );

        await expectLater(run(failSecond: true), throwsA(isA<Exception>()));
        expect(saved, ['text1', null, null]); // part 1 survived
        calls = [];
        final texts = await run(failSecond: false);
        expect(calls, [2, 3]); // part 1 was not asked for again
        expect(texts, ['text1', 'text2', 'text3']);
      },
    );

    test('a silent part in the middle is a pause, not a failure', () async {
      final texts = await transcribeParts(
        count: 3,
        done: const [],
        transcribe: (part) async {
          if (part.number == 2) throw const NoSpeechDetected();
          return 'text${part.number}';
        },
        onProgress: (_) async {},
      );
      expect(texts, ['text1', '', 'text3']);
      expect(joinPartTexts(texts), 'text1 text3');
    });

    test('a silent part is not asked for again on resume', () async {
      final calls = <int>[];
      await transcribeParts(
        count: 3,
        done: const ['text1', ''],
        transcribe: (part) async {
          calls.add(part.number);
          return 'text${part.number}';
        },
        onProgress: (_) async {},
      );
      expect(calls, [3]);
    });
  });

  group('playing the parts back to back', () {
    test('plays each when the one before finished', () async {
      final played = <String>[];
      var state = 'idle';
      await playPartsInOrder(
        parts: ['a', 'b', 'c'],
        poll: Duration.zero,
        isCurrent: () => true,
        play: (part) async {
          played.add(part);
          state = 'playing';
          // It finishes by itself on the next check.
          Future<void>.delayed(Duration.zero, () => state = 'completed');
          return true;
        },
        state: () async => state,
      );
      expect(played, ['a', 'b', 'c']);
    });

    test('stopping in the middle does not start the rest', () async {
      final played = <String>[];
      var state = 'idle';
      await playPartsInOrder(
        parts: ['a', 'b', 'c'],
        poll: Duration.zero,
        isCurrent: () => true,
        play: (part) async {
          played.add(part);
          state = 'playing';
          Future<void>.delayed(
            Duration.zero,
            () => state = part == 'a' ? 'completed' : 'stopped',
          );
          return true;
        },
        state: () async => state,
      );
      expect(played, ['a', 'b']);
    });

    test('starting something else ends the sequence', () async {
      final played = <String>[];
      var current = true;
      var state = 'idle';
      await playPartsInOrder(
        parts: ['a', 'b'],
        poll: Duration.zero,
        isCurrent: () => current,
        play: (part) async {
          played.add(part);
          state = 'playing';
          Future<void>.delayed(Duration.zero, () => current = false);
          return true;
        },
        state: () async => state,
      );
      expect(played, ['a']);
    });

    test('a part that cannot start ends the sequence', () async {
      final played = <String>[];
      await playPartsInOrder(
        parts: ['a', 'b'],
        poll: Duration.zero,
        isCurrent: () => true,
        play: (part) async {
          played.add(part);
          return false;
        },
        state: () async => 'idle',
      );
      expect(played, ['a']);
    });
  });

  group('the note remembers its parts', () {
    test('survives saving and loading, and old notes still load', () {
      final note = CircuitNote(
        id: '1',
        createdAt: DateTime.utc(2026, 10, 6),
        status: 'Saved',
        audioPath: '/f/p1.cnote',
        audioParts: const ['/f/p1.cnote', '/f/p2.cnote'],
        partTexts: const ['one', null],
      );
      final again = CircuitNote.fromJson(
        jsonDecode(jsonEncode(note.toJson())) as Map<String, dynamic>,
      );
      expect(again.audioFiles, ['/f/p1.cnote', '/f/p2.cnote']);
      expect(again.partTexts, ['one', null]);

      final old = CircuitNote.fromJson({
        'id': '2',
        'createdAt': '2026-10-01T00:00:00.000',
        'status': 'ok',
        'audioPath': '/f/old.cnote',
      });
      expect(old.audioFiles, ['/f/old.cnote']);
      expect(old.audioParts, isEmpty);
      expect(old.toJson().containsKey('audioParts'), isFalse);
    });
  });

  test('backup and restore keep every part of a long note, in order', () async {
    final source = Directory.systemTemp.createTempSync('parts_src');
    final target = Directory.systemTemp.createTempSync('parts_dst');
    addTearDown(() {
      source.deleteSync(recursive: true);
      target.deleteSync(recursive: true);
    });
    final files = [
      for (var i = 0; i < 3; i++)
        File('${source.path}/phone-note-${100 + i}.cnote')
          ..writeAsBytesSync(Uint8List.fromList([i, i, i])),
    ];
    final preferences = await SharedPreferences.getInstance();
    await writeSecretForTest(
      preferences,
      'circuit_notes',
      jsonEncode([
        CircuitNote(
          id: 'long',
          createdAt: DateTime.utc(2026, 10, 6),
          status: 'Saved',
          audioPath: files.first.path,
          audioParts: files.map((f) => f.path).toList(),
          partTexts: const ['a', 'b', 'c'],
        ).toJson(),
      ]),
    );
    final data = await BackupStore.collect();
    expect(data.audio.map((a) => a.name), [
      'phone-note-100.cnote',
      'phone-note-101.cnote',
      'phone-note-102.cnote',
    ]);

    SharedPreferences.setMockInitialValues({});
    final result = await BackupStore.restore(data, filesDir: target);
    expect(result.notesAdded, 1);
    final restored = (await _loadNotes()).single;
    expect(restored.audioFiles.map((p) => p.split('/').last), [
      'phone-note-100.cnote',
      'phone-note-101.cnote',
      'phone-note-102.cnote',
    ]);
    expect(restored.partTexts, ['a', 'b', 'c']);
    for (var i = 0; i < 3; i++) {
      expect(File(restored.audioFiles[i]).readAsBytesSync(), [i, i, i]);
    }
  });
}

Future<List<CircuitNote>> _loadNotes() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = await readSecretForTest(preferences, 'circuit_notes');
  return (jsonDecode(raw!) as List<dynamic>)
      .map((n) => CircuitNote.fromJson(n as Map<String, dynamic>))
      .toList();
}
