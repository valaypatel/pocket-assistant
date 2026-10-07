part of 'main.dart';

// A long recording made with Circuit's button is stored on the board as one-minute parts:
// ordinary notes with consecutive numbers. The sync tells the app, for each part, which
// recording it belongs to (the number of the first part), its position, and whether it is
// the last. To the person it is one note: this file collects the parts as they arrive,
// in any order and over several syncs, and starts the transcription once every part is here.

/// What Circuit says about one downloaded file: it is part [part] of the recording whose
/// first part is [first], and [last] is true on the final part.
class BoardPart {
  const BoardPart({
    required this.first,
    required this.part,
    required this.last,
  });

  final int first;
  final int part;
  final bool last;

  /// "<first>,<part>,<1 if last>", as the sync writes it next to the file. Null for
  /// anything that does not make sense, which is then treated as a plain note.
  static BoardPart? parse(String text) {
    final fields = text.trim().split(',');
    if (fields.length != 3) return null;
    final first = int.tryParse(fields[0]);
    final part = int.tryParse(fields[1]);
    final last = fields[2] == '1' ? true : (fields[2] == '0' ? false : null);
    if (first == null || part == null || last == null) return null;
    if (first < 1 || part < 1) return null;
    return BoardPart(first: first, part: part, last: last);
  }
}

/// The number Circuit gave a downloaded note file ("circuit-note-<epoch>-<number>.cnote").
int? boardFileId(String notePath) => int.tryParse(
  RegExp(r'circuit-note-\d+-(\d+)\.(?:wav|cnote)$')
          .firstMatch(notePath)
          ?.group(1) ??
      '',
);

File? _boardPartFile(String notePath) {
  final id = boardFileId(notePath);
  if (id == null) return null;
  return File('${File(notePath).parent.path}/circuit-group-$id.txt');
}

/// The part description saved next to a downloaded note, if it is part of a longer recording.
Future<BoardPart?> readBoardPart(String notePath) async {
  try {
    final file = _boardPartFile(notePath);
    if (file == null || !await file.exists()) return null;
    return BoardPart.parse(await file.readAsString());
  } catch (_) {
    return null;
  }
}

/// The parts of one recording that are here so far.
class BoardPartsArrived {
  BoardPartsArrived(this.byPart, this.lastPart);

  /// File of each part, by part number.
  final Map<int, String> byPart;

  /// The number of the final part, once it has arrived.
  final int? lastPart;

  /// Every part from 1 to the last is here.
  bool get complete {
    final last = lastPart;
    if (last == null) return false;
    for (var part = 1; part <= last; part++) {
      if (!byPart.containsKey(part)) return false;
    }
    return true;
  }

  /// The files in playing order.
  List<String> get ordered {
    final numbers = byPart.keys.toList()..sort();
    return [for (final number in numbers) byPart[number]!];
  }

  /// The first part that is not here yet, once the end of the recording is known.
  int? get firstMissing {
    final last = lastPart;
    if (last == null) return null;
    for (var part = 1; part <= last; part++) {
      if (!byPart.containsKey(part)) return part;
    }
    return null;
  }

  /// What the note says while it is still arriving.
  String get statusText {
    final missing = firstMissing;
    if (missing != null) return 'Waiting for part $missing from Circuit…';
    final last = lastPart;
    return last == null
        ? 'Receiving part ${byPart.length} from Circuit…'
        : 'Receiving $last parts from Circuit…';
  }
}

/// Collects the files with their descriptions into what has arrived.
BoardPartsArrived collectBoardParts(Map<String, BoardPart> described) {
  final byPart = <int, String>{};
  int? lastPart;
  described.forEach((path, part) {
    byPart[part.part] = path;
    if (part.last) lastPart = part.part;
  });
  return BoardPartsArrived(byPart, lastPart);
}

extension _BoardParts on _CircuitHomePageState {
  /// Files sitting in the notes of this recording, with what the sync said about each.
  Future<Map<String, BoardPart>> _describedParts(Iterable<String> paths) async {
    final described = <String, BoardPart>{};
    for (final path in paths) {
      final part = await readBoardPart(path);
      if (part != null) described[path] = part;
    }
    return described;
  }

  /// A downloaded file that is one part of a longer recording. Returns false if the file is
  /// not usable as a part (the caller then treats it as a plain note).
  Future<bool> _attachBoardPart(
    String path,
    int? epochSeconds,
    BoardPart part,
  ) async {
    final fileId = boardFileId(path);
    if (fileId == null) return false;
    if (_pendingBoardDeletes.contains(part.first) ||
        _pendingBoardDeletes.contains(fileId)) {
      // Deleted in the app; Circuit's copy has not been removed yet. Do not let it come back.
      try {
        await File(path).delete();
      } catch (_) {}
      return true;
    }
    final recordedAt = epochSeconds != null && epochSeconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000)
        : null;
    // The recording's number names it. Numbers start again if Circuit is reset, so a note
    // from another day is not this recording; a long one can end hours after its parts.
    final note = _notes.where((n) {
      if (n.boardId != part.first) return false;
      return recordedAt == null ||
          n.createdAt.difference(recordedAt).abs() < const Duration(hours: 12);
    }).firstOrNull;
    if (note != null && note.audioParts.contains(path)) return true;
    final noteId =
        note?.id ??
        await _addPendingNote(
          'Receiving a long recording from Circuit…',
          createdAt: recordedAt,
          boardId: part.first,
        );
    final known = <String>{...?note?.audioParts};
    final firstPath = note?.audioPath;
    if (known.isEmpty && firstPath != null) known.add(firstPath);
    final described = await _describedParts({...known, path});
    described[path] = part;
    final arrived = collectBoardParts(described);
    final ordered = arrived.ordered;
    await _updateNote(
      noteId,
      (n) => n.copyWith(
        audioParts: ordered,
        audioPath: ordered.first,
        status: arrived.statusText,
      ),
    );
    if (!arrived.complete) return true;
    await _transcribeAfterSync(noteId, ordered.first);
    return true;
  }

  /// Every number Circuit gave the parts of this note, so deleting the note deletes them all
  /// on the board.
  Set<int> _boardPartIds(CircuitNote? note) {
    final ids = <int>{};
    for (final path in note?.audioFiles ?? const <String>[]) {
      final id = boardFileId(path);
      if (id != null) ids.add(id);
    }
    return ids;
  }
}
