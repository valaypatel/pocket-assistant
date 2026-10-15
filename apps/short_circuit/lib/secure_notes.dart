part of 'main.dart';

// Encrypted notes and encrypted app data. The note format is described in
// docs/security/README.md and tested against docs/security/test-vectors.json, the
// same vectors the board checks itself against.

/// Secure-storage entries: one notes key per key id the board has used, and one key
/// for the app's own data. Keys are only ever added, never replaced or removed, so
/// a note this phone has can be opened for as long as it exists.
const _noteKeyPrefix = 'note_key_';
const _appDataKeyName = 'app_data_key';

class NoteSecurityException implements Exception {
  const NoteSecurityException(this.message);
  final String message;

  @override
  String toString() => message;
}

class MissingNoteKey extends NoteSecurityException {
  const MissingNoteKey(this.keyId)
    : super(
        'This note is encrypted and this phone does not have its key. '
        'Open the app near Circuit so it can send the key.',
      );
  final int keyId;
}

/// The notes keys this phone holds, in Android's Keystore-backed secure storage.
class NoteKeys {
  const NoteKeys._();

  static String hex(int keyId) => keyId.toRadixString(16).padLeft(8, '0');

  static Future<void> save(int keyId, Uint8List key) => _secureStorage.write(
    key: '$_noteKeyPrefix${hex(keyId)}',
    value: base64Encode(key),
  );

  static Future<Uint8List?> get(int keyId) async {
    final stored = await _secureStorage.read(
      key: '$_noteKeyPrefix${hex(keyId)}',
    );
    return stored == null ? null : base64Decode(stored);
  }

  static Future<bool> has(int keyId) async => await get(keyId) != null;
}

class NoteCrypto {
  const NoteCrypto._();

  static const headerBytes = 28;
  static const tagBytes = 16;
  static final _gcm = AesGcm.with256bits();

  /// True for a file in the encrypted note format; false for an older plain WAV.
  static bool isEncrypted(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x43 &&
      bytes[1] == 0x4e &&
      bytes[2] == 0x54 &&
      bytes[3] == 0x31; // "CNT1"

  static int _u32(List<int> b, int at) =>
      b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

  /// The id of the key that sealed this note.
  static int keyIdOf(List<int> file) {
    if (!isEncrypted(file) || file.length < headerBytes) {
      throw const NoteSecurityException('This is not an encrypted note.');
    }
    return _u32(file, 8);
  }

  /// Opens a whole encrypted note and returns it as a WAV file. Any chunk that does
  /// not authenticate is an error, except a damaged last one, which is what a
  /// recording cut short by power loss leaves behind: the audio before it is kept.
  static Future<Uint8List> decryptToWav(Uint8List file, Uint8List key) async {
    if (!isEncrypted(file) ||
        file.length < headerBytes ||
        file[4] != 1 ||
        file[6] != headerBytes) {
      throw const NoteSecurityException('This note is not in a known format.');
    }
    final noteId = _u32(file, 12);
    final rate = _u32(file, 16);
    final channels = file[20] | (file[21] << 8);
    final bits = file[22] | (file[23] << 8);
    final chunk = _u32(file, 24);
    if (chunk == 0 || chunk > 1 << 20) {
      throw const NoteSecurityException('This note is damaged.');
    }
    final header = Uint8List.sublistView(file, 0, headerBytes);
    final secret = SecretKey(key);
    final pcm = BytesBuilder(copy: false);
    var pos = headerBytes;
    var index = 0;
    while (pos < file.length) {
      final take = min(chunk + tagBytes, file.length - pos);
      final last = pos + take == file.length;
      if (take < tagBytes) {
        if (last) break; // a few stray bytes of a chunk that was being written
        throw const NoteSecurityException('This note is damaged.');
      }
      final nonce = Uint8List(12)
        ..buffer.asByteData().setUint32(0, noteId, Endian.little)
        ..buffer.asByteData().setUint64(4, index, Endian.little);
      final aad = Uint8List(headerBytes + 8)
        ..setRange(0, headerBytes, header)
        ..buffer.asByteData().setUint64(headerBytes, index, Endian.little);
      try {
        final plain = await _gcm.decrypt(
          SecretBox(
            Uint8List.sublistView(file, pos, pos + take - tagBytes),
            nonce: nonce,
            mac: Mac(
              Uint8List.sublistView(file, pos + take - tagBytes, pos + take),
            ),
          ),
          secretKey: secret,
          aad: aad,
        );
        pcm.add(plain);
      } on SecretBoxAuthenticationError {
        if (last && index > 0) break;
        throw const NoteSecurityException(
          'This note failed its integrity check, so it was not opened.',
        );
      }
      pos += take;
      index++;
    }
    return wavFromPcm(pcm.takeBytes(), rate, channels, bits);
  }

  /// The raw samples of a note (or the raw payload of a Moments file), without a WAV header.
  static Future<Uint8List> decryptToPcm(Uint8List file, Uint8List key) async =>
      Uint8List.sublistView(await decryptToWav(file, key), 44);

  static Uint8List wavFromPcm(Uint8List pcm, int rate, int channels, int bits) {
    final block = channels * bits ~/ 8;
    final out = Uint8List(44 + pcm.length);
    final view = out.buffer.asByteData();
    void tag(int at, String text) => out.setRange(at, at + 4, text.codeUnits);
    tag(0, 'RIFF');
    view.setUint32(4, 36 + pcm.length, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, 1, Endian.little);
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, rate, Endian.little);
    view.setUint32(28, rate * block, Endian.little);
    view.setUint16(32, block, Endian.little);
    view.setUint16(34, bits, Endian.little);
    tag(36, 'data');
    view.setUint32(40, pcm.length, Endian.little);
    out.setRange(44, out.length, pcm);
    return out;
  }
}

/// The audio of a note as a WAV, opening it first if it is encrypted. Notes from
/// older firmware are plain WAV files and come back as they are.
Future<Uint8List> readNoteAudio(String path) async {
  final bytes = await File(path).readAsBytes();
  if (!NoteCrypto.isEncrypted(bytes)) return bytes;
  final keyId = NoteCrypto.keyIdOf(bytes);
  final key = await NoteKeys.get(keyId);
  if (key == null) throw MissingNoteKey(keyId);
  return NoteCrypto.decryptToWav(bytes, key);
}

/// Text kept in SharedPreferences (the notes list, chats, tasks), sealed with a key
/// held in secure storage. Anything not written by this class, such as data from
/// before this existed, is read as plain text and sealed the next time it is read.
class SecureText {
  const SecureText._();

  static const prefix = 'enc1:';
  static final _gcm = AesGcm.with256bits();

  static Future<SecretKey>? _creating;

  static Future<SecretKey> _key() async {
    final stored = await _secureStorage.read(key: _appDataKeyName);
    if (stored != null) return SecretKey(base64Decode(stored));
    // Several parts of the app can ask for the key at the same moment on the very first run.
    // Without this, each would make its own key and the last one written would win, leaving
    // data sealed with the others unreadable. One creation runs; the rest wait for it.
    return _creating ??= _create().whenComplete(() => _creating = null);
  }

  static Future<SecretKey> _create() async {
    final stored = await _secureStorage.read(key: _appDataKeyName);
    if (stored != null) return SecretKey(base64Decode(stored));
    final fresh = await _gcm.newSecretKey();
    await _secureStorage.write(
      key: _appDataKeyName,
      value: base64Encode(await fresh.extractBytes()),
    );
    return fresh;
  }

  static Future<String> encrypt(String plain) async {
    final box = await _gcm.encrypt(utf8.encode(plain), secretKey: await _key());
    return '$prefix${base64Encode(box.concatenation())}';
  }

  /// Plain text passes through unchanged; sealed text is opened, or throws.
  static Future<String> decrypt(String stored) async {
    if (!stored.startsWith(prefix)) return stored;
    try {
      final box = SecretBox.fromConcatenation(
        base64Decode(stored.substring(prefix.length)),
        nonceLength: 12,
        macLength: 16,
      );
      return utf8.decode(await _gcm.decrypt(box, secretKey: await _key()));
    } catch (_) {
      throw const NoteSecurityException(
        'Saved data could not be opened with this phone\'s key.',
      );
    }
  }
}

/// Reads a SharedPreferences string that [_writeSecret] wrote. Plain data from an
/// earlier version is returned as it is and sealed in place, but only after the
/// sealed copy has been checked to open to exactly the same text.
Future<String?> _readSecret(SharedPreferences preferences, String key) async {
  final stored = preferences.getString(key);
  if (stored == null) return null;
  final plain = await SecureText.decrypt(stored);
  if (!stored.startsWith(SecureText.prefix)) {
    final sealed = await SecureText.encrypt(plain);
    if (await SecureText.decrypt(sealed) == plain) {
      await preferences.setString(key, sealed);
    }
  }
  return plain;
}

/// Seals [plain] and stores it. If sealing fails nothing is written, so plain text
/// is never stored in its place.
Future<void> _writeSecret(
  SharedPreferences preferences,
  String key,
  String plain,
) async {
  // The saved notes could not be opened, so the list in memory is empty or partial. Saving it
  // would replace every note that is still safely stored.
  if (key == _notesKey && _notesUnreadable) return;
  await preferences.setString(key, await SecureText.encrypt(plain));
}

/// True while the saved notes could not be read (the Android keystore can be briefly unavailable
/// right after an update). Nothing may overwrite them, and nothing is rebuilt from audio files,
/// until they open again.
bool _notesUnreadable = false;

@visibleForTesting
set notesUnreadableForTest(bool value) => _notesUnreadable = value;

// Exposed so tests can reach the private helpers above.
@visibleForTesting
Future<String?> readSecretForTest(SharedPreferences p, String key) =>
    _readSecret(p, key);

@visibleForTesting
Future<void> writeSecretForTest(
  SharedPreferences p,
  String key,
  String plain,
) => _writeSecret(p, key, plain);
