import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

// The same vectors the board checks itself against at every start.
final _vectors = jsonDecode(
  File('../../docs/security/test-vectors.json').readAsStringSync(),
) as Map<String, dynamic>;
final _master = Uint8List.fromList(_hex(_vectors['masterKeyHex'] as String));
final _moments = _vectors['moments'] as Map<String, dynamic>;
final _momentsFile = Uint8List.fromList(_hex(_moments['fileHex'] as String));
final _offsets = (_moments['offsetsMs'] as List).cast<int>();
final _noteId = _moments['noteId'] as int;
final _keyId = _vectors['keyId'] as int;

List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('moments file', () {
    test('opens the file the reference implementation made', () async {
      expect(await Moments.open(_momentsFile, _master, _noteId), _offsets);
    });

    test('refuses a file that belongs to another note', () async {
      await expectLater(
        Moments.open(_momentsFile, _master, _noteId + 1),
        throwsA(isA<NoteSecurityException>()),
      );
    });

    test('refuses a file that was changed', () async {
      final bad = Uint8List.fromList(_momentsFile)..[40] ^= 1;
      await expectLater(
        Moments.open(bad, _master, _noteId),
        throwsA(isA<NoteSecurityException>()),
      );
    });

    test('refuses the wrong key', () async {
      final other = Uint8List.fromList(_master)..[0] ^= 1;
      await expectLater(
        Moments.open(_momentsFile, other, _noteId),
        throwsA(isA<NoteSecurityException>()),
      );
    });

    test('a note audio file is not taken for a moments file', () async {
      final audio = Uint8List.fromList(
        _hex(((_vectors['cases'] as List).first as Map)['fileHex'] as String),
      );
      await expectLater(
        Moments.open(audio, _master, 7),
        throwsA(isA<NoteSecurityException>()),
      );
    });
  });

  group('moments of a note', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('moments_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    // Two one-second "parts" (board numbers 10 and 11) of 16 kHz mono 16-bit audio, sealed like
    // the board does, with a moments file for each.
    Future<List<String>> twoParts() async {
      final parts = <String>[];
      for (final id in [10, 11]) {
        final pcm = Uint8List(32000);
        final audio = await _sealAudio(id, pcm);
        final path = '${dir.path}/circuit-note-1000-$id.cnote';
        File(path).writeAsBytesSync(audio);
        parts.add(path);
      }
      File('${dir.path}/circuit-moments-10.cmom')
          .writeAsBytesSync(await _sealMoments(10, [250, 900]));
      File('${dir.path}/circuit-moments-11.cmom')
          .writeAsBytesSync(await _sealMoments(11, [100]));
      return parts;
    }

    test('part length comes from the file size', () async {
      final parts = await twoParts();
      expect(await Moments.partDurationMs(parts.first), 1000);
    });

    test(
      'moments of later parts are moved by the length of the earlier ones',
      () async {
        await NoteKeys.save(_keyId, _master);
        final parts = await twoParts();
        expect(await Moments.forNote(parts), [250, 900, 1100]);
      },
    );

    test('a part without a moments file adds none', () async {
      await NoteKeys.save(_keyId, _master);
      final parts = await twoParts();
      File('${dir.path}/circuit-moments-10.cmom').deleteSync();
      expect(await Moments.forNote(parts), [1100]);
    });

    test('without the key there are no moments, and no error', () async {
      final parts = await twoParts();
      expect(await Moments.forNote(parts), isEmpty);
    });

    test('finds the part and the place in it', () async {
      final parts = await twoParts();
      final first = await Moments.locate(parts, 250);
      expect([first.part, first.offsetMs], [0, 250]);
      final second = await Moments.locate(parts, 1100);
      expect([second.part, second.offsetMs], [1, 100]);
    });

    test('moments file is removed with its note file name pattern', () {
      final path = '${dir.path}/circuit-note-1000-10.cnote';
      expect(momentsFileFor(path)?.path, '${dir.path}/circuit-moments-10.cmom');
    });
  });
  group('moments and the AI', () {
    test('the transcription is told when each bookmark was pressed', () {
      final text = Moments.transcriptionInstruction([9216, 83000]);
      expect(text, contains('0:09, 1:23'));
      expect(text, contains('[[MOMENT]]'));
      expect(Moments.transcriptionInstruction(const []), isEmpty);
    });

    test('markers are numbered in order, and carry on from a given number', () {
      expect(
        Moments.numberMarkers(
          'First point. [[MOMENT]] Then more [[MOMENT]]talk.',
        ),
        'First point. [Moment 1] Then more [Moment 2] talk.',
      );
      expect(
        Moments.numberMarkers('Only [[MOMENT]] one', first: 3),
        'Only [Moment 3] one',
      );
      expect(Moments.numberMarkers('No markers here.'), 'No markers here.');
    });

    test(
      'the review is only told about markers that are in the transcript',
      () {
        expect(Moments.hasMarkers('Buy milk [Moment 1] and eggs'), isTrue);
        expect(Moments.hasMarkers('Buy milk and eggs'), isFalse);
        expect(Moments.reviewInstruction, contains('[Moment 1]'));
      },
    );
  });

  group('moments of one part', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('moments_part_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('forPart gives the offsets inside that part only', () async {
      await NoteKeys.save(_keyId, _master);
      final path = '${dir.path}/circuit-note-1000-10.cnote';
      File(path).writeAsBytesSync(await _sealAudio(10, Uint8List(32000)));
      File('${dir.path}/circuit-moments-10.cmom')
          .writeAsBytesSync(await _sealMoments(10, [250, 900]));
      expect(await Moments.forPart(path), [250, 900]);
    });

    test('forPart is empty without a file or without the key', () async {
      final path = '${dir.path}/circuit-note-1000-10.cnote';
      File(path).writeAsBytesSync(await _sealAudio(10, Uint8List(32000)));
      expect(await Moments.forPart(path), isEmpty);
      File('${dir.path}/circuit-moments-10.cmom')
          .writeAsBytesSync(await _sealMoments(10, [250]));
      expect(await Moments.forPart(path), isEmpty); // the key was never saved
    });
  });
}

// ---- sealing helpers: a Dart copy of the board's format, for building test files ----

Future<Uint8List> _sealAudio(int id, Uint8List pcm) =>
    _seal(id, pcm, rate: 16000, channels: 1, bits: 16);

Future<Uint8List> _sealMoments(int id, List<int> offsets) {
  final payload = ByteData(4 + 4 * offsets.length)
    ..setUint32(0, offsets.length, Endian.little);
  for (var i = 0; i < offsets.length; i++) {
    payload.setUint32(4 + 4 * i, offsets[i], Endian.little);
  }
  return _seal(
    id | 0x80000000,
    payload.buffer.asUint8List(),
    rate: 0,
    channels: 0,
    bits: 0,
  );
}

Future<Uint8List> _seal(
  int noteId,
  Uint8List pcm, {
  required int rate,
  required int channels,
  required int bits,
}) async {
  const chunk = 4096;
  final header = ByteData(28);
  header.buffer.asUint8List().setRange(0, 4, 'CNT1'.codeUnits);
  header.setUint8(4, 1);
  header.setUint16(6, 28, Endian.little);
  header.setUint32(8, _keyId, Endian.little);
  header.setUint32(12, noteId, Endian.little);
  header.setUint32(16, rate, Endian.little);
  header.setUint16(20, channels, Endian.little);
  header.setUint16(22, bits, Endian.little);
  header.setUint32(24, chunk, Endian.little);
  final head = header.buffer.asUint8List();
  final out = BytesBuilder()..add(head);
  final gcm = AesGcm.with256bits();
  var index = 0;
  for (var pos = 0; pos < pcm.length; pos += chunk) {
    final end = pos + chunk < pcm.length ? pos + chunk : pcm.length;
    final nonce = ByteData(12)
      ..setUint32(0, noteId, Endian.little)
      ..setUint64(4, index, Endian.little);
    final aad = ByteData(36)..setUint64(28, index, Endian.little);
    aad.buffer.asUint8List().setRange(0, 28, head);
    final box = await gcm.encrypt(
      pcm.sublist(pos, end),
      secretKey: SecretKey(_master),
      nonce: nonce.buffer.asUint8List(),
      aad: aad.buffer.asUint8List(),
    );
    out
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    index++;
  }
  return out.toBytes();
}
