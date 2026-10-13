import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

const _pass = 'correct horse battery';

Map<String, dynamic> _note(
  String id, {
  String? audio,
  int? boardId,
  String at = '2026-10-04T10:00:00.000',
  String title = 'A note',
}) => {
  'id': id,
  'createdAt': at,
  'status': 'ok',
  'title': title,
  'enrichmentStatus': 'ready',
  'audioPath': ?audio,
  'boardId': ?boardId?.toString(),
};

Future<void> _store(String key, Object value) async {
  final p = await SharedPreferences.getInstance();
  await writeSecretForTest(p, key, jsonEncode(value));
}

Future<List<dynamic>> _load(String key) async {
  final p = await SharedPreferences.getInstance();
  final raw = await readSecretForTest(p, key);
  return raw == null ? [] : jsonDecode(raw) as List<dynamic>;
}

void main() {
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('backup_test');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('the file', () {
    test('round trips notes, chats, keys and recordings', () async {
      final audio = Uint8List.fromList(List.generate(3000, (i) => i % 251));
      final data = BackupData(
        notes: [_note('n1', audio: 'a.cnote')],
        tasks: '[{"id":"t1","title":"x"}]',
        groups: '[{"id":"g1","name":"G","noteIds":["n1"]}]',
        chats: {'n1': '[]'},
        noteKeys: {
          '0000000a': base64Encode([1, 2, 3]),
        },
        audio: [BackupAudio('a.cnote', audio)],
      );
      final file = await BackupCodec.encode(data, _pass, iterations: 10);
      expect(BackupCodec.isBackup(file), isTrue);

      final back = await BackupCodec.decode(file, _pass);
      expect(back.notes.single['id'], 'n1');
      expect(back.tasks, data.tasks);
      expect(back.groups, data.groups);
      expect(back.chats['n1'], '[]');
      expect(back.noteKeys['0000000a'], data.noteKeys['0000000a']);
      expect(back.audio.single.name, 'a.cnote');
      expect(back.audio.single.bytes, audio);
    });

    test('spans several chunks', () async {
      final big = Uint8List.fromList(
        List.generate((1 << 20) * 2 + 5, (i) => i),
      );
      final file = await BackupCodec.encode(
        BackupData(audio: [BackupAudio('big', big)]),
        _pass,
        iterations: 10,
      );
      final back = await BackupCodec.decode(file, _pass);
      expect(back.audio.single.bytes, big);
    });

    test(
      'a recording read from disk makes the same backup as one in memory',
      () async {
        final tmp = Directory.systemTemp.createTempSync('backup-stream');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final big = Uint8List.fromList(
          List.generate((1 << 20) * 2 + 77, (i) => i * 7),
        );
        final small = Uint8List.fromList([4, 5, 6]);
        final bigFile = File('${tmp.path}/big')..writeAsBytesSync(big);
        final smallFile = File('${tmp.path}/small')..writeAsBytesSync(small);
        final file = await BackupCodec.encode(
          BackupData(
            audio: [
              BackupAudio.file('big', bigFile, big.length),
              BackupAudio.file('small', smallFile, small.length),
            ],
          ),
          _pass,
          iterations: 10,
        );
        final back = await BackupCodec.decode(file, _pass);
        expect(back.audio.map((a) => a.name), ['big', 'small']);
        expect(back.audio[0].bytes, big);
        expect(back.audio[1].bytes, small);
      },
    );

    test(
      'a recording that changes while the backup is written is caught',
      () async {
        final tmp = Directory.systemTemp.createTempSync('backup-change');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final f = File('${tmp.path}/a')..writeAsBytesSync([1, 2, 3, 4]);
        // The backup was told the file is longer than it is.
        expect(
          BackupCodec.encode(
            BackupData(audio: [BackupAudio.file('a', f, 9)]),
            _pass,
            iterations: 10,
          ),
          throwsA(isA<BackupException>()),
        );
      },
    );

    test(
      'a 24 MB recording on disk is backed up and restored intact',
      () async {
        final tmp = Directory.systemTemp.createTempSync('backup-big');
        addTearDown(() => tmp.deleteSync(recursive: true));
        // 24 whole chunks and a partial one, with content that does not repeat.
        final size = (1 << 20) * 24 + 12345;
        final f = File('${tmp.path}/big.cnote');
        final sink = f.openWrite();
        var seed = 12345;
        for (var done = 0; done < size; done += 65536) {
          final n = min(65536, size - done);
          final block = Uint8List(n);
          for (var i = 0; i < n; i++) {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff;
            block[i] = seed >> 16;
          }
          sink.add(block);
        }
        await sink.close();
        final file = await BackupCodec.encode(
          BackupData(audio: [BackupAudio.file('big.cnote', f, size)]),
          _pass,
          iterations: 10,
        );
        final back = await BackupCodec.decode(file, _pass);
        expect(back.audio.single.bytes!.length, size);
        expect(back.audio.single.bytes, f.readAsBytesSync());
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('the wrong passphrase is refused', () async {
      final file = await BackupCodec.encode(
        BackupData(notes: [_note('n1')]),
        _pass,
        iterations: 10,
      );
      expect(
        () => BackupCodec.decode(file, 'a different passphrase'),
        throwsA(isA<BackupException>()),
      );
    });

    test('a changed byte is refused', () async {
      final file = await BackupCodec.encode(
        BackupData(notes: [_note('n1')]),
        _pass,
        iterations: 10,
      );
      file[file.length - 20] ^= 1;
      expect(
        () => BackupCodec.decode(file, _pass),
        throwsA(isA<BackupException>()),
      );
    });

    test('a file cut short is refused', () async {
      final big = Uint8List((1 << 20) + 100);
      final file = await BackupCodec.encode(
        BackupData(audio: [BackupAudio('big', big)]),
        _pass,
        iterations: 10,
      );
      // Drop the last chunk entirely: the new last chunk was not sealed as final.
      final cut = Uint8List.sublistView(file, 0, 36 + (1 << 20) + 16);
      expect(
        () => BackupCodec.decode(cut, _pass),
        throwsA(isA<BackupException>()),
      );
    });

    test('something that is not a backup is refused', () {
      expect(
        () => BackupCodec.decode(Uint8List.fromList([1, 2, 3]), _pass),
        throwsA(isA<BackupException>()),
      );
    });

    test('the file does not contain the note text', () async {
      final file = await BackupCodec.encode(
        BackupData(notes: [_note('n1', title: 'SecretTitleXyz')]),
        _pass,
        iterations: 10,
      );
      expect(
        utf8.decode(file, allowMalformed: true),
        isNot(contains('SecretTitleXyz')),
      );
    });

    test('short passphrases are flagged', () {
      expect(BackupCodec.passphraseProblem('short'), isNotNull);
      expect(BackupCodec.passphraseProblem(_pass), isNull);
    });
  });

  group('collect', () {
    test(
      'gathers notes, recordings, chats, keys and leaves API keys out',
      () async {
        final wav = File('${dir.path}/circuit-note-1-7.cnote')
          ..writeAsBytesSync([9, 8, 7]);
        await _store('circuit_notes', [_note('n1', audio: wav.path)]);
        await _store('circuit_tasks', [
          {'id': 't1', 'title': 'x'},
        ]);
        await _store('note_chat_n1', []);
        await NoteKeys.save(0xab, Uint8List.fromList([5, 5, 5]));
        await const FlutterSecureStorage().write(
          key: 'gemini_api_key',
          value: 'SECRET',
        );

        final data = await BackupStore.collect();
        expect(data.notes.single['audioPath'], 'circuit-note-1-7.cnote');
        // The recording stays on disk until the backup is written; it is not read into memory here.
        expect(data.audio.single.bytes, isNull);
        expect(data.audio.single.length, 3);
        expect(await data.audio.single.open().expand((b) => b).toList(), [
          9,
          8,
          7,
        ]);
        expect(data.chats.keys, ['n1']);
        expect(data.noteKeys.keys, ['000000ab']);
        expect(jsonEncode(data.noteKeys), isNot(contains('SECRET')));

        final without = await BackupStore.collect(includeAudio: false);
        expect(without.audio, isEmpty);
        expect(without.noteKeys, isEmpty);
        expect(without.notes.single.containsKey('audioPath'), isFalse);
      },
    );
  });

  group('restore', () {
    test('onto an empty phone brings everything back', () async {
      final data = BackupData(
        notes: [
          _note('n1', audio: 'a.cnote'),
          _note('n2'),
        ],
        tasks: '[{"id":"t1","title":"x"}]',
        groups: '[{"id":"g1","name":"G","noteIds":["n1","n2"],"createdAt":"2026-10-04T10:00:00.000"}]',
        chats: {'n1': '[{"x":1}]'},
        noteKeys: {
          '0000000a': base64Encode([1, 2, 3]),
        },
        audio: [
          BackupAudio('a.cnote', Uint8List.fromList([1, 2])),
        ],
      );
      final result = await BackupStore.restore(data, filesDir: dir);

      expect(result.notesAdded, 2);
      expect(result.keysAdded, 1);
      final notes = await _load('circuit_notes');
      expect(notes, hasLength(2));
      final path = (notes.first as Map)['audioPath'] as String;
      expect(File(path).readAsBytesSync(), [1, 2]);
      expect(await NoteKeys.has(0xa), isTrue);
      expect(await _load('circuit_tasks'), hasLength(1));
      expect(await _load('circuit_groups'), hasLength(1));
      expect(await _load('note_chat_n1'), hasLength(1));
    });

    test('never changes what the phone already has', () async {
      await _store('circuit_notes', [_note('n1', title: 'Mine, edited')]);
      await _store('circuit_tasks', [
        {'id': 't1', 'title': 'Mine'},
      ]);
      await _store('note_chat_n1', [
        {'mine': true},
      ]);
      await NoteKeys.save(0xa, Uint8List.fromList([9, 9, 9]));

      final data = BackupData(
        notes: [_note('n1', title: 'Backup copy')],
        tasks: '[{"id":"t1","title":"Backup"}]',
        chats: {'n1': '[{"backup":true}]'},
        noteKeys: {
          '0000000a': base64Encode([1, 2, 3]),
        },
      );
      final result = await BackupStore.restore(data, filesDir: dir);

      expect(result.notesAdded, 0);
      expect(result.notesSkipped, 1);
      expect((await _load('circuit_notes')).single['title'], 'Mine, edited');
      expect((await _load('circuit_tasks')).single['title'], 'Mine');
      expect((await _load('note_chat_n1')).single, {'mine': true});
      expect(await NoteKeys.get(0xa), [9, 9, 9]);
    });

    test('restoring twice adds nothing the second time', () async {
      final data = BackupData(
        notes: [_note('n1'), _note('n2')],
        tasks: '[{"id":"t1","title":"x"}]',
      );
      await BackupStore.restore(data, filesDir: dir);
      final again = await BackupStore.restore(data, filesDir: dir);
      expect(again.notesAdded, 0);
      expect(again.tasksAdded, 0);
      expect(await _load('circuit_notes'), hasLength(2));
    });

    test('the same recording under another id is not duplicated, and its group follows', () async {
      await _store('circuit_notes', [
        _note('local', boardId: 42, at: '2026-10-04T10:02:00.000'),
      ]);
      final data = BackupData(
        notes: [_note('old', boardId: 42, at: '2026-10-04T10:00:00.000')],
        groups: '[{"id":"g1","name":"G","noteIds":["old"],"createdAt":"2026-10-04T10:00:00.000"}]',
        chats: {'old': '[{"c":1}]'},
      );
      final result = await BackupStore.restore(data, filesDir: dir);

      expect(result.notesAdded, 0);
      expect(await _load('circuit_notes'), hasLength(1));
      expect((await _load('circuit_groups')).single['noteIds'], ['local']);
      expect(await _load('note_chat_local'), hasLength(1));
    });

    test('a different recording with the same board number is kept', () async {
      await _store('circuit_notes', [
        _note('local', boardId: 42, at: '2026-10-04T10:00:00.000'),
      ]);
      final data = BackupData(
        notes: [_note('other', boardId: 42, at: '2026-10-09T10:00:00.000')],
      );
      final result = await BackupStore.restore(data, filesDir: dir);
      expect(result.notesAdded, 1);
    });

    test('a recording name cannot escape the files folder', () async {
      final inner = Directory('${dir.path}/files')..createSync();
      final data = BackupData(
        notes: [_note('n1', audio: '../evil.cnote')],
        audio: [
          BackupAudio('../evil.cnote', Uint8List.fromList([6, 6])),
        ],
      );
      await BackupStore.restore(data, filesDir: inner);
      expect(File('${dir.path}/evil.cnote').existsSync(), isFalse);
      expect(File('${inner.path}/evil.cnote').readAsBytesSync(), [6, 6]);
    });

    test('an existing recording file is not overwritten', () async {
      File('${dir.path}/a.cnote').writeAsBytesSync([7, 7]);
      final data = BackupData(
        notes: [_note('n1', audio: 'a.cnote')],
        audio: [
          BackupAudio('a.cnote', Uint8List.fromList([1, 1])),
        ],
      );
      await BackupStore.restore(data, filesDir: dir);
      expect(File('${dir.path}/a.cnote').readAsBytesSync(), [7, 7]);
    });
  });

  group('the page', () {
    Widget page({
      required BackupSaver save,
      BackupPicker? pick,
      Future<void> Function()? onRestored,
    }) => MaterialApp(
      theme: buildScTheme(),
      home: BackupPage(
        onRestored: onRestored ?? () async {},
        save: save,
        pick: pick ?? () async => null,
        filesDirectory: () async => dir,
        iterations: 10,
      ),
    );

    testWidgets('refuses a short passphrase and saves nothing', (tester) async {
      var saved = false;
      await tester.pumpWidget(
        page(
          save: (_, _) async {
            saved = true;
            return true;
          },
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase').first,
        'short',
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Create backup'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Create backup'));
      await tester.pump();
      expect(find.textContaining('at least'), findsWidgets);
      expect(saved, isFalse);
    });

    testWidgets('refuses passphrases that differ', (tester) async {
      await tester.pumpWidget(page(save: (_, _) async => true));
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase').first,
        _pass,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase again'),
        '$_pass!',
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Create backup'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Create backup'));
      await tester.pump();
      expect(find.textContaining('do not match'), findsWidgets);
    });

    testWidgets('creates a file that opens with the passphrase', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await _store('circuit_notes', [_note('n1')]);
      });
      Uint8List? written;
      await tester.pumpWidget(
        page(
          save: (name, bytes) async {
            written = bytes;
            return true;
          },
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase').first,
        _pass,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase again'),
        _pass,
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Create backup'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Create backup'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();

      expect(written, isNotNull);
      final back = await tester.runAsync(
        () => BackupCodec.decode(written!, _pass),
      );
      expect(back!.notes.single['id'], 'n1');
    });

    testWidgets('a wrong passphrase on restore says so and restores nothing', (
      tester,
    ) async {
      final file = await tester.runAsync(
        () => BackupCodec.encode(
          BackupData(notes: [_note('n1')]),
          _pass,
          iterations: 10,
        ),
      );
      var reloaded = false;
      await tester.pumpWidget(
        page(
          save: (_, _) async => true,
          pick: () async => file,
          onRestored: () async => reloaded = true,
        ),
      );
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase').last,
        'not the right one',
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Choose backup file'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Choose backup file'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();

      expect(find.textContaining('Wrong passphrase'), findsWidgets);
      expect(reloaded, isFalse);
      expect(await tester.runAsync(() => _load('circuit_notes')), isEmpty);
    });
  });

  group('Moments', () {
    test('travel with their recording and come back beside it', () async {
      final note = File('${dir.path}/circuit-note-1791834086-204.cnote')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final moments = File('${dir.path}/circuit-moments-204.cmom')
        ..writeAsBytesSync([9, 9, 9]);
      await _store('circuit_notes', [_note('n1', audio: note.path)]);

      final data = await BackupStore.collect();
      expect(
        data.audio.map((a) => a.name),
        containsAll([
          'circuit-note-1791834086-204.cnote',
          'circuit-moments-204.cmom',
        ]),
      );

      // Another phone: an empty folder.
      final other = Directory('${dir.path}/other')..createSync();
      SharedPreferences.setMockInitialValues({});
      await BackupStore.restore(data, filesDir: other);
      final back = File('${other.path}/circuit-moments-204.cmom');
      expect(back.existsSync(), isTrue);
      expect(back.readAsBytesSync(), [9, 9, 9]);
      expect(moments.existsSync(), isTrue);
    });

    test('a recording without Moments backs up as before', () async {
      final note = File('${dir.path}/circuit-note-5-9.cnote')
        ..writeAsBytesSync([1]);
      await _store('circuit_notes', [_note('n1', audio: note.path)]);
      final data = await BackupStore.collect();
      expect(data.audio.map((a) => a.name), ['circuit-note-5-9.cnote']);
    });
  });
}
