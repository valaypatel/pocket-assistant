part of 'main.dart';

// An encrypted backup of the notes. One file holds the notes list, tasks, groups,
// chats, the note keys and (optionally) the recordings, sealed with a key made
// from a passphrase. API keys and service settings are never included.
//
// File layout (integers little-endian):
//   0   4  "CBK1"
//   4   4  PBKDF2-HMAC-SHA256 iterations
//   8  16  salt
//   24  8  nonce prefix
//   32  4  plaintext chunk size
//   36  .. chunks, each AES-256-GCM(ciphertext + 16 byte tag)
// Chunk i uses nonce = prefix + i, and authenticates the header, its index and
// whether it is the last chunk, so reordering or cutting the file short is caught.
// The plaintext is: u32 manifest length, the manifest (JSON), then the recordings.

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

class BackupAudio {
  /// A recording held in memory (what a restore reads back).
  const BackupAudio(this.name, Uint8List this.bytes)
    : file = null,
      _fileLength = 0;

  /// A recording still on disk: it is read a piece at a time while the backup is written, so a
  /// big library is never held in memory whole.
  const BackupAudio.file(this.name, File this.file, int length)
    : bytes = null,
      _fileLength = length;

  final String name;
  final Uint8List? bytes;
  final File? file;
  final int _fileLength;

  int get length => bytes?.length ?? _fileLength;

  Stream<List<int>> open() =>
      bytes != null ? Stream.value(bytes!) : file!.openRead();
}

class BackupData {
  const BackupData({
    this.notes = const [],
    this.tasks,
    this.groups,
    this.chats = const {},
    this.noteKeys = const {},
    this.audio = const [],
    this.settings = const {},
    this.secrets = const {},
  });

  /// Notes as stored, with `audioPath` replaced by the recording's file name.
  final List<Map<String, dynamic>> notes;

  /// The task and group lists as stored (JSON text), or null when there are none.
  final String? tasks;
  final String? groups;

  /// Chat history (JSON text) by note id.
  final Map<String, String> chats;

  /// Note keys by key id (8 hex digits), base64.
  final Map<String, String> noteKeys;
  final List<BackupAudio> audio;

  /// The app's own settings (appearance, the AI switches, model and service names): nothing secret.
  final Map<String, dynamic> settings;

  /// API keys, only when the person chose to include them. Sealed in the backup with everything else.
  final Map<String, String> secrets;
}

/// Settings kept in the phone's preferences that a backup carries (all non-secret).
const _backupPrefKeys = [
  'theme_mode',
  'auto_transcribe',
  'auto_enrich',
  'use_moments',
  'share_diagnostics',
];

/// Settings kept in secure storage that are only names and addresses.
const _backupSecureSettingKeys = [
  'gemini_model',
  'hermes_base_url',
  'hermes_model',
  'music_function_url',
];

/// API keys: carried only when asked for.
const _backupSecretKeys = [
  'gemini_api_key',
  'hermes_api_key',
  'music_service_key',
];

class BackupCodec {
  const BackupCodec._();

  static const defaultIterations = 600000;
  static const minPassphraseLength = 10;
  static const _headerBytes = 36;
  static const _tagBytes = 16;
  static const _chunkSize = 1 << 20;
  static final _gcm = AesGcm.with256bits();

  static bool isBackup(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x43 &&
      bytes[1] == 0x42 &&
      bytes[2] == 0x4b &&
      bytes[3] == 0x31; // "CBK1"

  static String? passphraseProblem(String passphrase) =>
      passphrase.length < minPassphraseLength
      ? 'Use at least $minPassphraseLength characters.'
      : null;

  static Future<SecretKey> _key(String passphrase, List<int> salt, int n) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: n,
        bits: 256,
      ).deriveKeyFromPassword(password: passphrase, nonce: salt);

  static List<int> _u32(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

  static int _read32(List<int> b, int at) =>
      b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

  static List<int> _manifest(BackupData data) => utf8.encode(
    jsonEncode({
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'notes': data.notes,
      if (data.tasks != null) 'tasks': data.tasks,
      if (data.groups != null) 'groups': data.groups,
      'chats': data.chats,
      'noteKeys': data.noteKeys,
      if (data.settings.isNotEmpty) 'settings': data.settings,
      if (data.secrets.isNotEmpty) 'secrets': data.secrets,
      'audio': [
        for (final a in data.audio) {'name': a.name, 'length': a.length},
      ],
    }),
  );

  /// More recordings than this and a backup is refused: the finished file (and, on restore, the
  /// file plus what is read from it) has to fit in the phone's memory.
  static const maxAudioBytes = 400 * 1024 * 1024;

  /// The plaintext, a piece at a time: the manifest's length and text, then each recording.
  static Stream<List<int>> _plainStream(
    List<int> manifest,
    BackupData data,
  ) async* {
    yield _u32(manifest.length);
    yield manifest;
    for (final a in data.audio) {
      yield* a.open();
    }
  }

  static BackupData _parse(Uint8List plain) {
    if (plain.length < 4) throw const BackupException('This backup is empty.');
    final manifestLength = _read32(plain, 0);
    if (manifestLength < 0 || 4 + manifestLength > plain.length) {
      throw const BackupException('This backup is damaged.');
    }
    final Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(
        utf8.decode(plain.sublist(4, 4 + manifestLength)),
      ) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupException('This backup is damaged.');
    }
    if (manifest['version'] != 1) {
      throw const BackupException(
        'This backup was made by a newer version of the app.',
      );
    }
    var pos = 4 + manifestLength;
    final audio = <BackupAudio>[];
    for (final entry in (manifest['audio'] as List<dynamic>? ?? const [])) {
      final map = entry as Map<String, dynamic>;
      final length = map['length'] as int;
      if (length < 0 || pos + length > plain.length) {
        throw const BackupException('This backup is damaged.');
      }
      audio.add(
        BackupAudio(
          map['name'] as String,
          Uint8List.sublistView(plain, pos, pos + length),
        ),
      );
      pos += length;
    }
    Map<String, String> strings(Object? value) => {
      for (final e in (value as Map<String, dynamic>? ?? const {}).entries)
        e.key: e.value as String,
    };
    return BackupData(
      notes: (manifest['notes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(),
      tasks: manifest['tasks'] as String?,
      groups: manifest['groups'] as String?,
      chats: strings(manifest['chats']),
      noteKeys: strings(manifest['noteKeys']),
      audio: audio,
      settings: Map<String, dynamic>.from(
        manifest['settings'] as Map<String, dynamic>? ?? const {},
      ),
      secrets: strings(manifest['secrets']),
    );
  }

  static Future<Uint8List> encode(
    BackupData data,
    String passphrase, {
    int iterations = defaultIterations,
  }) async {
    final random = Random.secure();
    List<int> randomBytes(int n) =>
        List.generate(n, (_) => random.nextInt(256));
    final salt = randomBytes(16);
    final prefix = randomBytes(8);
    final header = Uint8List.fromList([
      0x43, 0x42, 0x4b, 0x31, //
      ..._u32(iterations),
      ...salt,
      ...prefix,
      ..._u32(_chunkSize),
    ]);
    final key = await _key(passphrase, salt, iterations);
    final manifest = _manifest(data);
    // The size is known before anything is read, so the last chunk can be marked as the last.
    final total =
        4 +
        manifest.length +
        data.audio.fold<int>(0, (sum, a) => sum + a.length);
    final chunks = max(1, (total + _chunkSize - 1) ~/ _chunkSize);
    final out = BytesBuilder(copy: false)..add(header);

    var index = 0;
    var read = 0;
    final chunk = Uint8List(_chunkSize);
    var filled = 0;
    Future<void> seal(int length) async {
      if (index >= chunks)
        throw const BackupException(
          'A recording changed while backing up. Try again.',
        );
      final box = await _gcm.encrypt(
        Uint8List.sublistView(chunk, 0, length),
        secretKey: key,
        nonce: [...prefix, ..._u32(index)],
        aad: [...header, ..._u32(index), if (index == chunks - 1) 1 else 0],
      );
      out
        ..add(box.cipherText)
        ..add(box.mac.bytes);
      index++;
    }

    await for (final piece in _plainStream(manifest, data)) {
      var from = 0;
      while (from < piece.length) {
        final take = min(piece.length - from, _chunkSize - filled);
        chunk.setRange(filled, filled + take, piece, from);
        filled += take;
        from += take;
        read += take;
        if (filled == _chunkSize) {
          await seal(_chunkSize);
          filled = 0;
        }
      }
    }
    if (read != total)
      throw const BackupException(
        'A recording changed while backing up. Try again.',
      );
    if (filled > 0 || index == 0) await seal(filled);
    if (index != chunks)
      throw const BackupException(
        'A recording changed while backing up. Try again.',
      );
    return out.takeBytes();
  }

  static Future<BackupData> decode(Uint8List file, String passphrase) async {
    if (!isBackup(file) || file.length < _headerBytes + _tagBytes) {
      throw const BackupException('This is not a Short-Circuit backup.');
    }
    final iterations = _read32(file, 4);
    final chunkSize = _read32(file, 32);
    if (iterations < 1 || iterations > 10000000 || chunkSize != _chunkSize) {
      throw const BackupException('This backup is in an unknown format.');
    }
    final header = Uint8List.sublistView(file, 0, _headerBytes);
    final key = await _key(passphrase, file.sublist(8, 24), iterations);
    final prefix = file.sublist(24, 32);
    final plain = BytesBuilder(copy: false);
    var pos = _headerBytes;
    var index = 0;
    while (pos < file.length) {
      final remaining = file.length - pos;
      final last = remaining <= chunkSize + _tagBytes;
      final size = last ? remaining : chunkSize + _tagBytes;
      if (size < _tagBytes) {
        throw const BackupException('This backup is damaged.');
      }
      try {
        plain.add(
          await _gcm.decrypt(
            SecretBox(
              file.sublist(pos, pos + size - _tagBytes),
              nonce: [...prefix, ..._u32(index)],
              mac: Mac(file.sublist(pos + size - _tagBytes, pos + size)),
            ),
            secretKey: key,
            aad: [...header, ..._u32(index), if (last) 1 else 0],
          ),
        );
      } on SecretBoxAuthenticationError {
        throw const BackupException(
          'Wrong passphrase, or the backup is damaged.',
        );
      }
      pos += size;
      index++;
    }
    return _parse(plain.takeBytes());
  }
}

/// What a restore did.
class RestoreResult {
  const RestoreResult({
    this.notesAdded = 0,
    this.notesSkipped = 0,
    this.tasksAdded = 0,
    this.groupsAdded = 0,
    this.chatsAdded = 0,
    this.keysAdded = 0,
    this.settingsAdded = 0,
    this.secretsAdded = 0,
  });

  final int notesAdded;
  final int notesSkipped;
  final int tasksAdded;
  final int groupsAdded;
  final int chatsAdded;
  final int keysAdded;
  final int settingsAdded;
  final int secretsAdded;
}

class BackupStore {
  const BackupStore._();

  static List<Map<String, dynamic>> _maps(String? json) {
    if (json == null) return [];
    try {
      return (jsonDecode(json) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Gathers everything a backup holds. Recordings are copied as stored (still
  /// sealed with their note key), never decrypted.
  static Future<BackupData> collect({
    bool includeAudio = true,
    bool includeKeys = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final notes = <Map<String, dynamic>>[];
    final audio = <BackupAudio>[];
    final names = <String>{};
    // The Moments Circuit sealed beside a recording (a few hundred bytes, sealed with the note key) travel
    // with it; without them a restored note would keep its audio but lose its bookmarks.
    Future<void> addMoments(String recordingPath) async {
      final moments = momentsFileFor(recordingPath);
      if (moments == null || !await moments.exists()) return;
      final name = _basename(moments.path);
      if (names.add(name)) {
        audio.add(BackupAudio.file(name, moments, await moments.length()));
      }
    }

    for (final note in _maps(await _readSecret(preferences, _notesKey))) {
      final copy = Map<String, dynamic>.from(note);
      final path = copy.remove('audioPath') as String?;
      final partPaths =
          (copy.remove('audioParts') as List<dynamic>? ?? const [])
              .map((part) => part.toString())
              .toList();
      if (path != null && includeAudio) {
        final file = File(path);
        if (await file.exists()) {
          final name = _basename(path);
          copy['audioPath'] = name;
          if (names.add(name)) {
            audio.add(BackupAudio.file(name, file, await file.length()));
          }
          await addMoments(path);
        }
        // A long note is several files; each goes in, in order.
        final partNames = <String>[];
        for (final partPath in partPaths) {
          final part = File(partPath);
          if (!await part.exists()) continue;
          final name = _basename(partPath);
          partNames.add(name);
          if (names.add(name)) {
            audio.add(BackupAudio.file(name, part, await part.length()));
          }
          await addMoments(partPath);
        }
        if (partNames.length > 1) copy['audioParts'] = partNames;
      }
      notes.add(copy);
    }
    final chats = <String, String>{};
    for (final note in notes) {
      final id = note['id'] as String?;
      if (id == null) continue;
      final chat = await _readSecret(preferences, 'note_chat_$id');
      if (chat != null) chats[id] = chat;
    }
    // The keys only matter with the recordings, so they travel together.
    final keys = <String, String>{};
    if (includeAudio) {
      for (final e in (await _secureStorage.readAll()).entries) {
        if (e.key.startsWith(_noteKeyPrefix)) {
          keys[e.key.substring(_noteKeyPrefix.length)] = e.value;
        }
      }
    }
    final settings = <String, dynamic>{
      for (final key in _backupPrefKeys)
        if (preferences.get(key) != null) key: preferences.get(key),
    };
    for (final key in _backupSecureSettingKeys) {
      final value = await _secureStorage.read(key: key);
      if (value != null && value.isNotEmpty) settings[key] = value;
    }
    final secrets = <String, String>{};
    if (includeKeys) {
      for (final key in _backupSecretKeys) {
        final value = await _secureStorage.read(key: key);
        if (value != null && value.isNotEmpty) secrets[key] = value;
      }
    }
    return BackupData(
      notes: notes,
      tasks: await _readSecret(preferences, _tasksKey),
      groups: await _readSecret(preferences, _groupsKey),
      chats: chats,
      noteKeys: keys,
      audio: audio,
      settings: settings,
      secrets: secrets,
    );
  }

  /// Adds what the phone is missing and changes nothing it already has: a note,
  /// task, group, chat or key that exists here is left exactly as it is. A note
  /// counts as already here if it has the same id, or the same board number
  /// recorded within ten minutes of the same time (the same recording synced again).
  static Future<RestoreResult> restore(
    BackupData data, {
    required Directory filesDir,
  }) async {
    final preferences = await SharedPreferences.getInstance();

    var keysAdded = 0;
    for (final e in data.noteKeys.entries) {
      final id = int.tryParse(e.key, radix: 16);
      if (id == null) continue;
      if (await NoteKeys.has(id)) continue;
      await NoteKeys.save(id, base64Decode(e.value));
      keysAdded++;
    }

    final existing = _maps(await _readSecret(preferences, _notesKey));
    final byId = {for (final n in existing) n['id'] as String: n};
    bool sameRecording(Map<String, dynamic> a, Map<String, dynamic> b) {
      final boardA = a['boardId']?.toString();
      if (boardA == null || boardA != b['boardId']?.toString()) return false;
      final timeA = DateTime.tryParse(a['createdAt'] as String? ?? '');
      final timeB = DateTime.tryParse(b['createdAt'] as String? ?? '');
      return timeA != null &&
          timeB != null &&
          timeA.difference(timeB).abs() < const Duration(minutes: 10);
    }

    final idMap = <String, String>{};
    final added = <Map<String, dynamic>>[];
    var skipped = 0;
    final audioByName = {for (final a in data.audio) _basename(a.name): a};
    // A recording made by decoding a backup is in memory; one gathered from this phone is on disk.
    Future<Uint8List> bytesOf(BackupAudio a) async =>
        a.bytes ?? await a.file!.readAsBytes();
    await filesDir.create(recursive: true);
    // The Moments file that goes with a restored recording, if the backup has it and the phone does not.
    Future<void> restoreMoments(String recordingPath) async {
      final moments = momentsFileFor(recordingPath);
      if (moments == null) return;
      final saved = audioByName[_basename(moments.path)];
      if (saved != null && !await moments.exists()) {
        await moments.writeAsBytes(await bytesOf(saved));
      }
    }

    for (final note in data.notes) {
      final id = note['id'] as String?;
      if (id == null) continue;
      final match = byId.containsKey(id)
          ? id
          : existing
                .where((e) => sameRecording(e, note))
                .map((e) => e['id'] as String)
                .firstOrNull;
      if (match != null) {
        idMap[id] = match;
        skipped++;
        continue;
      }
      final copy = Map<String, dynamic>.from(note);
      final name = copy.remove('audioPath') as String?;
      final partNames =
          (copy.remove('audioParts') as List<dynamic>? ?? const [])
              .map((part) => part.toString())
              .toList();
      final audio = name == null ? null : audioByName[_basename(name)];
      if (audio != null) {
        final target = File('${filesDir.path}/${_basename(name!)}');
        if (!await target.exists())
          await target.writeAsBytes(await bytesOf(audio));
        copy['audioPath'] = target.path;
        await restoreMoments(target.path);
        final restored = <String>[];
        for (final partName in partNames) {
          final partAudio = audioByName[_basename(partName)];
          if (partAudio == null) continue;
          final part = File('${filesDir.path}/${_basename(partName)}');
          if (!await part.exists())
            await part.writeAsBytes(await bytesOf(partAudio));
          await restoreMoments(part.path);
          restored.add(part.path);
        }
        if (restored.length > 1) copy['audioParts'] = restored;
        // Saved text lines up with the parts; if any part is missing it no longer does.
        if (restored.length != partNames.length) copy.remove('partTexts');
      }
      idMap[id] = id;
      added.add(copy);
    }

    var chatsAdded = 0;
    for (final e in data.chats.entries) {
      final target = idMap[e.key];
      if (target == null || preferences.containsKey('note_chat_$target')) {
        continue;
      }
      await _writeSecret(preferences, 'note_chat_$target', e.value);
      chatsAdded++;
    }

    final groups = _maps(await _readSecret(preferences, _groupsKey));
    final groupIds = {for (final g in groups) g['id']};
    var groupsAdded = 0;
    for (final g in _maps(data.groups)) {
      if (groupIds.contains(g['id'])) continue;
      final ids = (g['noteIds'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map((id) => idMap[id])
          .whereType<String>()
          .toSet()
          .toList();
      groups.add({...g, 'noteIds': ids});
      groupsAdded++;
    }
    if (groupsAdded > 0) {
      await _writeSecret(preferences, _groupsKey, jsonEncode(groups));
    }

    final tasks = _maps(await _readSecret(preferences, _tasksKey));
    final taskIds = {for (final t in tasks) t['id']};
    var tasksAdded = 0;
    for (final t in _maps(data.tasks)) {
      if (taskIds.contains(t['id'])) continue;
      tasks.add(t);
      tasksAdded++;
    }
    if (tasksAdded > 0) {
      await _writeSecret(preferences, _tasksKey, jsonEncode(tasks));
    }

    // Settings and keys: only what this phone has not set itself, like everything else in a restore.
    var settingsAdded = 0;
    for (final e in data.settings.entries) {
      if (_backupPrefKeys.contains(e.key)) {
        if (preferences.containsKey(e.key)) continue;
        final value = e.value;
        if (value is bool) {
          await preferences.setBool(e.key, value);
        } else if (value is String) {
          await preferences.setString(e.key, value);
        } else {
          continue;
        }
        settingsAdded++;
      } else if (_backupSecureSettingKeys.contains(e.key) &&
          e.value is String) {
        if ((await _secureStorage.read(key: e.key)) != null) continue;
        await _secureStorage.write(key: e.key, value: e.value as String);
        settingsAdded++;
      }
    }
    var secretsAdded = 0;
    for (final e in data.secrets.entries) {
      if (!_backupSecretKeys.contains(e.key)) continue;
      final existing = await _secureStorage.read(key: e.key);
      if (existing != null && existing.isNotEmpty) continue;
      await _secureStorage.write(key: e.key, value: e.value);
      secretsAdded++;
    }

    // Last, so a note never shows up before the things it points at.
    if (added.isNotEmpty) {
      await _writeSecret(
        preferences,
        _notesKey,
        jsonEncode([...existing, ...added]),
      );
    }
    return RestoreResult(
      notesAdded: added.length,
      notesSkipped: skipped,
      tasksAdded: tasksAdded,
      groupsAdded: groupsAdded,
      chatsAdded: chatsAdded,
      keysAdded: keysAdded,
      settingsAdded: settingsAdded,
      secretsAdded: secretsAdded,
    );
  }
}
