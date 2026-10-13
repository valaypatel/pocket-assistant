part of 'main.dart';

// Moments: bookmarks added with Circuit's lower key during a recording. The board seals a small
// file for each one-minute part that has any (docs/security/README.md, "Moments"), the sync brings
// it next to the note as circuit-moments-<number>.cmom, and the note page lists them. Each offset
// in the file is milliseconds from the start of its own part; [Moments.forNote] turns them into
// offsets from the start of the whole note.

const _momentsIdFlag = 0x80000000;
const _momentsMax = 120;

/// The file the sync saved beside a downloaded note part, whether or not it exists.
File? momentsFileFor(String notePath) {
  final id = boardFileId(notePath);
  if (id == null) return null;
  return File('${File(notePath).parent.path}/circuit-moments-$id.cmom');
}

/// Where in a note's parts a moment falls.
class MomentSpot {
  const MomentSpot(this.part, this.offsetMs);

  /// Index into the note's parts, from 0.
  final int part;

  /// Milliseconds from the start of that part.
  final int offsetMs;
}

class Moments {
  const Moments._();

  /// Opens one part's Moments file and returns its offsets in ms from the start of that part.
  /// [boardId] is the part's note number on the board: the file names it in its header, so one
  /// moved to another note does not open.
  static Future<List<int>> open(
    Uint8List file,
    Uint8List key,
    int boardId,
  ) async {
    if (!NoteCrypto.isEncrypted(file) || file.length < NoteCrypto.headerBytes) {
      throw const NoteSecurityException('These moments are not readable.');
    }
    if (NoteCrypto._u32(file, 12) != (boardId | _momentsIdFlag)) {
      throw const NoteSecurityException(
        'These moments belong to another note.',
      );
    }
    // Rate, channels and bits are 0: this is never audio.
    if (NoteCrypto._u32(file, 16) != 0 ||
        file[20] != 0 ||
        file[21] != 0 ||
        file[22] != 0 ||
        file[23] != 0) {
      throw const NoteSecurityException('This is not a moments file.');
    }
    final payload = await NoteCrypto.decryptToPcm(file, key);
    if (payload.length < 4) {
      throw const NoteSecurityException('These moments are damaged.');
    }
    final data = ByteData.sublistView(payload);
    final count = data.getUint32(0, Endian.little);
    if (count == 0 || count > _momentsMax || payload.length != 4 + 4 * count) {
      throw const NoteSecurityException('These moments are damaged.');
    }
    return [
      for (var i = 0; i < count; i++) data.getUint32(4 + 4 * i, Endian.little),
    ];
  }

  /// How long a part plays, worked out from its size (so nothing has to be opened). 0 for a plain
  /// WAV or a file that is not a note.
  static Future<int> partDurationMs(String path) async {
    final file = File(path);
    final length = await file.length();
    final handle = await file.open();
    final Uint8List head;
    try {
      head = await handle.read(NoteCrypto.headerBytes);
    } finally {
      await handle.close();
    }
    if (!NoteCrypto.isEncrypted(head) || head.length < NoteCrypto.headerBytes) {
      return 0;
    }
    final rate = NoteCrypto._u32(head, 16);
    final channels = head[20] | (head[21] << 8);
    final bits = head[22] | (head[23] << 8);
    final chunk = NoteCrypto._u32(head, 24);
    final bytesPerSecond = rate * channels * bits ~/ 8;
    if (bytesPerSecond == 0 || chunk == 0) return 0;
    final sealed = length - NoteCrypto.headerBytes;
    if (sealed <= 0) return 0;
    final step = chunk + NoteCrypto.tagBytes;
    final chunks = (sealed + step - 1) ~/ step;
    final pcm = sealed - chunks * NoteCrypto.tagBytes;
    return pcm <= 0 ? 0 : pcm * 1000 ~/ bytesPerSecond;
  }

  /// The moments of one part, in ms from the start of that part. None when it has no Moments file,
  /// or the file cannot be opened (no key, damaged, another note's).
  static Future<List<int>> forPart(String path) async {
    final id = boardFileId(path);
    final file = momentsFileFor(path);
    if (id == null || file == null || !await file.exists()) return const [];
    try {
      final bytes = await file.readAsBytes();
      final key = await NoteKeys.get(NoteCrypto.keyIdOf(bytes));
      return key == null ? const [] : await open(bytes, key, id);
    } on NoteSecurityException {
      return const [];
    }
  }

  /// A note's moments in ms from the start of the whole note, oldest first. [parts] are the note's
  /// files in playing order (one file for a short note). A part without a Moments file, or one that
  /// cannot be opened (no key, damaged), simply contributes none.
  static Future<List<int>> forNote(List<String> parts) async {
    final joined = <int>[];
    var base = 0;
    for (final path in parts) {
      for (final offset in await forPart(path)) {
        joined.add(base + offset);
      }
      base += await partDurationMs(path);
    }
    joined.sort();
    return joined;
  }

  /// What the transcription is told about a part's Moments: when the bookmark button was pressed, so
  /// the model can put a marker at that point. Empty when there are none.
  static String transcriptionInstruction(List<int> momentsMs) {
    if (momentsMs.isEmpty) return '';
    final times = momentsMs.map(nowPlayingClock).join(', ');
    return ' The person pressed a bookmark button while recording, at $times (minutes:seconds from '
        'the start of this audio). Put the marker [[MOMENT]] in the transcript at the point where each of '
        'those times falls, between the words being said then. Use each marker once, add nothing else '
        'around it, and never write the times out.';
  }

  /// Replaces the model's [[MOMENT]] markers with numbered ones, [Moment 1], [Moment 2]..., counting
  /// from [first] so the numbers run on across the parts of a long note.
  static String numberMarkers(String text, {int first = 1}) {
    var next = first;
    return text
        .replaceAllMapped(
          RegExp(r'\s*\[\[MOMENT\]\]\s*'),
          (_) => ' [Moment ${next++}] ',
        )
        .trim();
  }

  /// Added to the AI review's instructions when the transcript carries Moment markers.
  static const reviewInstruction =
      ' The speaker pressed a bookmark button while recording, shown in the transcript as markers like '
      '[Moment 1]. Treat the sentences just before and after each marker as the most important in the '
      'note: make sure the summary covers them, and consider them first for actions. Never put a marker '
      'in the title, tags, summary or action titles.';

  static bool hasMarkers(String transcript) =>
      RegExp(r'\[Moment \d+\]').hasMatch(transcript);

  /// Which part, and where in it, a time from the start of the whole note falls.
  static Future<MomentSpot> locate(List<String> parts, int noteMs) async {
    var base = 0;
    for (var i = 0; i < parts.length; i++) {
      final duration = await partDurationMs(parts[i]);
      if (noteMs < base + duration || i == parts.length - 1) {
        final offset = noteMs - base;
        return MomentSpot(i, offset < 0 ? 0 : offset);
      }
      base += duration;
    }
    return const MomentSpot(0, 0);
  }
}
