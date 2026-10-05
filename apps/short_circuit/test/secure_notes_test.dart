import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

// The same vectors the board checks itself against at every start.
final _vectors = jsonDecode(
  File('../../docs/security/test-vectors.json').readAsStringSync(),
) as Map<String, dynamic>;
final _master = Uint8List.fromList(_hex(_vectors['masterKeyHex'] as String));
final _cases = (_vectors['cases'] as List).cast<Map<String, dynamic>>();

List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

Uint8List _file(int i) =>
    Uint8List.fromList(_hex(_cases[i]['fileHex'] as String));
Uint8List _pcm(int i) =>
    Uint8List.fromList(_hex(_cases[i]['plaintextHex'] as String));
Uint8List _pcmOf(Uint8List wav) => Uint8List.sublistView(wav, 44);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('note format', () {
    test('opens the files the reference implementation made', () async {
      for (var i = 0; i < _cases.length; i++) {
        final wav = await NoteCrypto.decryptToWav(_file(i), _master);
        expect(_pcmOf(wav), _pcm(i), reason: _cases[i]['name'] as String);
        expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      }
    });

    test('knows an encrypted note from a plain WAV', () {
      expect(NoteCrypto.isEncrypted(_file(0)), isTrue);
      expect(
        NoteCrypto.isEncrypted(NoteCrypto.wavFromPcm(_pcm(0), 16000, 1, 16)),
        isFalse,
      );
      expect(NoteCrypto.isEncrypted(Uint8List(2)), isFalse);
      expect(NoteCrypto.keyIdOf(_file(0)), _vectors['keyId']);
    });

    test('rejects a flipped bit in any chunk before the last', () async {
      final file = _file(0);
      // Chunks 0 and 1 (a damaged last chunk is treated as a recording cut short).
      for (final at in [28, 60, 100, 108, 150, 187]) {
        final bad = Uint8List.fromList(file)..[at] ^= 1;
        await expectLater(
          NoteCrypto.decryptToWav(bad, _master),
          throwsA(isA<NoteSecurityException>()),
          reason: 'byte $at',
        );
      }
    });

    test('rejects a changed header', () async {
      for (final at in [8, 12, 16, 24]) {
        final bad = Uint8List.fromList(_file(0))..[at] ^= 1;
        await expectLater(
          NoteCrypto.decryptToWav(bad, _master),
          throwsA(isA<NoteSecurityException>()),
          reason: 'header byte $at',
        );
      }
    });

    test('rejects a wrong key', () async {
      final wrong = Uint8List.fromList(List.generate(32, (i) => i + 1));
      await expectLater(
        NoteCrypto.decryptToWav(_file(0), wrong),
        throwsA(isA<NoteSecurityException>()),
      );
    });

    test('rejects chunks that were swapped', () async {
      final file = _file(0);
      const header = 28, sealed = 64 + 16;
      final swapped = Uint8List.fromList([
        ...file.sublist(0, header),
        ...file.sublist(header + sealed, header + 2 * sealed),
        ...file.sublist(header, header + sealed),
        ...file.sublist(header + 2 * sealed),
      ]);
      await expectLater(
        NoteCrypto.decryptToWav(swapped, _master),
        throwsA(isA<NoteSecurityException>()),
      );
    });

    test(
      'keeps the audio before a last chunk cut short by power loss',
      () async {
        final file = _file(0);
        final cut = Uint8List.sublistView(file, 0, 28 + 80 + 80 + 7);
        final wav = await NoteCrypto.decryptToWav(cut, _master);
        expect(_pcmOf(wav), _pcm(0).sublist(0, 128));
      },
    );

    test('a damaged middle chunk is never skipped', () async {
      final bad = Uint8List.fromList(_file(0))..[28 + 5] ^= 1;
      await expectLater(
        NoteCrypto.decryptToWav(bad, _master),
        throwsA(isA<NoteSecurityException>()),
      );
    });
  });

  group('readNoteAudio', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('notes'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<String> write(String name, List<int> bytes) async {
      final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return file.path;
    }

    test('opens an encrypted note with the key stored for it', () async {
      await NoteKeys.save(_vectors['keyId'] as int, _master);
      final wav = await readNoteAudio(await write('a.cnote', _file(0)));
      expect(_pcmOf(wav), _pcm(0));
    });

    test('says what is missing when the phone has no key', () async {
      await expectLater(
        readNoteAudio(await write('a.cnote', _file(0))),
        throwsA(isA<MissingNoteKey>()),
      );
    });

    test('older plain notes come back unchanged', () async {
      final plain = NoteCrypto.wavFromPcm(_pcm(1), 16000, 1, 16);
      expect(await readNoteAudio(await write('old.wav', plain)), plain);
    });

    test(
      'keys for earlier notes stay usable after a newer key arrives',
      () async {
        final other = Uint8List.fromList(List.filled(32, 9));
        await NoteKeys.save(_vectors['keyId'] as int, _master);
        await NoteKeys.save(0x0badf00d, other);
        expect(await NoteKeys.has(_vectors['keyId'] as int), isTrue);
        expect(await NoteKeys.has(0x0badf00d), isTrue);
        final wav = await readNoteAudio(await write('a.cnote', _file(0)));
        expect(_pcmOf(wav), _pcm(0));
      },
    );
  });

  group('SecureText', () {
    test('round-trips and is not stored as plain text', () async {
      const text = '[{"id":"1","transcript":"call the plumber"}]';
      final sealed = await SecureText.encrypt(text);
      expect(sealed.startsWith(SecureText.prefix), isTrue);
      expect(sealed.contains('plumber'), isFalse);
      expect(await SecureText.decrypt(sealed), text);
    });

    test('seals the same text differently each time', () async {
      expect(
        await SecureText.encrypt('x'),
        isNot(await SecureText.encrypt('x')),
      );
    });

    test(
      'rejects tampering and a different key instead of returning junk',
      () async {
        final sealed = await SecureText.encrypt('secret');
        final bytes = base64Decode(sealed.substring(SecureText.prefix.length));
        bytes[bytes.length - 1] ^= 1;
        await expectLater(
          SecureText.decrypt('${SecureText.prefix}${base64Encode(bytes)}'),
          throwsA(isA<NoteSecurityException>()),
        );
        FlutterSecureStorage.setMockInitialValues(
          {},
        ); // a new key, as after a reinstall
        await expectLater(
          SecureText.decrypt(sealed),
          throwsA(isA<NoteSecurityException>()),
        );
      },
    );

    test(
      'plain data from an earlier version is read, then sealed in place',
      () async {
        SharedPreferences.setMockInitialValues({
          'circuit_notes': '[{"id":"1"}]',
        });
        final prefs = await SharedPreferences.getInstance();
        expect(await readSecretForTest(prefs, 'circuit_notes'), '[{"id":"1"}]');
        final stored = prefs.getString('circuit_notes')!;
        expect(stored.startsWith(SecureText.prefix), isTrue);
        expect(await readSecretForTest(prefs, 'circuit_notes'), '[{"id":"1"}]');
      },
    );

    test('stored values can be read back after a write', () async {
      final prefs = await SharedPreferences.getInstance();
      await writeSecretForTest(prefs, 'k', 'hello');
      expect(prefs.getString('k'), isNot('hello'));
      expect(await readSecretForTest(prefs, 'k'), 'hello');
    });

    test(
      'a value that cannot be opened is left in place, not deleted',
      () async {
        final sealed = await SecureText.encrypt('keep me');
        SharedPreferences.setMockInitialValues({'k': sealed});
        final prefs = await SharedPreferences.getInstance();
        FlutterSecureStorage.setMockInitialValues({}); // key lost
        await expectLater(
          readSecretForTest(prefs, 'k'),
          throwsA(isA<NoteSecurityException>()),
        );
        expect(prefs.getString('k'), sealed);
      },
    );
  });
}
