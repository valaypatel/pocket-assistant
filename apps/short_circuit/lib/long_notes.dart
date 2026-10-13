part of 'main.dart';

// A long recording is stored as an ordered series of one-minute files (see
// PartedNoteWriter on the Kotlin side). To the person it is one note: this file turns
// the parts into one transcript and one playback.
//
// Transcription goes part by part, in order, like a conversation: each request carries
// the end of the text so far (as text, not audio) so names, topics and speaker labels
// carry on. Each part's text is saved as it arrives, so a failure or a restart resumes at
// the first part that is still missing instead of starting over.

/// Raised when a part holds no speech. In the middle of a long note that is just a pause.
class NoSpeechDetected implements Exception {
  const NoSpeechDetected();

  @override
  String toString() => 'Exception: No speech detected.';
}

/// What a request for one part of a long recording needs to know.
class PartContext {
  const PartContext({
    required this.number,
    required this.count,
    required this.earlier,
  });

  /// 1-based position, and how many parts there are.
  final int number;
  final int count;

  /// The end of the text before this part ('' for the first).
  final String earlier;
}

/// How much earlier text goes with the next part. Enough for names and topics, small
/// enough that a one-hour note does not make every request bigger than the last.
const earlierTextLimit = 1500;

/// The end of the text so far, cut at a word boundary, to send with the next part.
String earlierTextTail(
  Iterable<String?> texts, {
  int limit = earlierTextLimit,
}) {
  final joined = joinPartTexts(texts);
  if (joined.length <= limit) return joined;
  var tail = joined.substring(joined.length - limit);
  final space = tail.indexOf(RegExp(r'\s'));
  if (space > 0 && space < 80) tail = tail.substring(space + 1);
  return '…$tail';
}

/// The parts' text as one: silent parts add nothing, and a new speaker starts a new line.
String joinPartTexts(Iterable<String?> texts) {
  final buffer = StringBuffer();
  for (final raw in texts) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) continue;
    if (buffer.isNotEmpty) {
      buffer.write(RegExp(r'^Speaker \d+:').hasMatch(text) ? '\n' : ' ');
    }
    buffer.write(text);
  }
  return buffer.toString();
}

/// Transcribes parts in order and returns every part's text. Parts already in [done] are
/// not repeated. [onProgress] runs after each part so the caller can save it. If a part
/// fails, the error is thrown and everything before it has already been reported.
Future<List<String?>> transcribeParts({
  required int count,
  required List<String?> done,
  required Future<String> Function(PartContext part) transcribe,
  required Future<void> Function(List<String?> texts) onProgress,
}) async {
  final texts = List<String?>.generate(
    count,
    (index) => index < done.length ? done[index] : null,
  );
  for (var index = 0; index < count; index++) {
    if (texts[index] != null) continue;
    try {
      texts[index] = await transcribe(
        PartContext(
          number: index + 1,
          count: count,
          earlier: earlierTextTail(texts.take(index)),
        ),
      );
    } on NoSpeechDetected {
      texts[index] = '';
    }
    await onProgress(List<String?>.of(texts));
  }
  return texts;
}

/// Plays the parts one after another. [play] starts one part, and [state] says how it
/// went ('completed' when it reached the end; anything else means it was stopped, or
/// another recording took over, so the rest must not start; 'paused' just waits).
/// [isCurrent] turns false when the person starts something else.
Future<void> playPartsInOrder({
  required List<String> parts,
  required Future<bool> Function(String part) play,
  required Future<String?> Function() state,
  required bool Function() isCurrent,
  Duration poll = const Duration(milliseconds: 300),
}) async {
  for (final part in parts) {
    if (!isCurrent()) return;
    if (!await play(part)) return;
    // Paused is still part of playing it: the sequence waits for the person to resume.
    while (isCurrent()) {
      final now = await state();
      if (now != 'playing' && now != 'paused') break;
      await Future<void>.delayed(poll);
    }
    if (!isCurrent() || await state() != 'completed') return;
  }
}

mixin _LongNoteState {
  /// Bumped whenever playback is started or stopped, so an older part-by-part playback
  /// notices it has been replaced.
  int _playbackToken = 0;
}

extension _LongNotes on _CircuitHomePageState {
  Future<GeminiTranscription?> _transcribeLongNote(String id) async {
    final note = _notes.where((item) => item.id == id).firstOrNull;
    final files = note?.audioFiles ?? const <String>[];
    if (files.length < 2) return null;
    if (_transcribingNoteId != null) return null;
    _update(() => _transcribingNoteId = id);
    final timer = Stopwatch()..start();
    var sawPhoneCall =
        false; // any part that sounded like a phone call makes the note one
    try {
      final texts = await transcribeParts(
        count: files.length,
        // Asking again for a note that already has its transcript means start over. After a
        // failure there is no transcript yet, so it carries on from the parts that have
        // text; a part saved as blank is asked for again, since the blank may have been a
        // failed attempt and not real silence.
        done: note!.transcript == null
            ? [
                for (final text in note.partTexts)
                  (text == null || text.isEmpty) ? null : text,
              ]
            : const [],
        transcribe: (part) async {
          await _setNoteStatus(
            id,
            'Transcribing part ${part.number} of ${part.count} with Gemini…',
          );
          final audio = await readNoteAudio(files[part.number - 1]);
          final result = await _gemini.transcribeWav(
            audio,
            detectMusic: false,
            part: part,
            momentsMs: _useMoments
                ? await Moments.forNoteParts(note, part.number - 1)
                : const [],
          );
          if (result.isCall) sawPhoneCall = true;
          return result.transcript;
        },
        onProgress: (texts) =>
            _updateNote(id, (n) => n.copyWith(partTexts: texts)),
      );
      final joined = joinPartTexts(texts);
      if (joined.isEmpty) throw const NoSpeechDetected();
      final transcription = GeminiTranscription(
        category: 'note',
        title: const GeminiClient()._fallbackHeading(joined),
        transcript: joined,
        isCall: sawPhoneCall,
      );
      Telemetry.event('transcription_done', {
        'ok': true,
        'seconds': timer.elapsed.inSeconds,
        'parts': files.length,
      });
      await _setNoteTranscript(id, transcription);
      if (shouldEnrichAutomatically(
        aiConnected: _aiConnected,
        autoEnrich: _autoEnrich,
      )) {
        unawaited(_enrichNote(id));
      }
      return transcription;
    } catch (error, stack) {
      Telemetry.event('transcription_done', {
        'ok': false,
        'seconds': timer.elapsed.inSeconds,
        'parts': files.length,
      });
      Telemetry.nonFatal('transcription', error, stack);
      final message = error.toString().replaceFirst('Exception: ', '');
      final noSpeech = message.toLowerCase().contains('no speech');
      final done = _notes
          .where((item) => item.id == id)
          .firstOrNull
          ?.partTexts
          .where((text) => text != null)
          .length;
      // What was done is kept; running it again carries on from there.
      final status = noSpeech
          ? 'No speech detected. Audio kept for review.'
          : 'Transcription stopped after ${done ?? 0} of ${files.length} '
                'parts: $message. Run it again to carry on.';
      await _setNoteStatus(id, status);
      _setStatus(noSpeech ? status : 'Transcription failed: $message');
      return null;
    } finally {
      if (mounted) _update(() => _transcribingNoteId = null);
    }
  }

  /// Plays a long note's parts back to back.
  Future<void> _playNoteParts(
    List<String> parts,
    String title, {
    int firstPart = 0,
    int startMs = 0,
  }) async {
    final token = ++_playbackToken;
    _sequencePlaying = true; // the player bar stays up between the parts
    _setStatus('Playing this voice note on your phone.');
    try {
      await playPartsInOrder(
        parts: parts.sublist(firstPart),
        isCurrent: () => token == _playbackToken && mounted,
        play: (part) async {
          final started = await _relayChannel.invokeMethod<bool>(
            'playWavBytes',
            {'bytes': await readNoteAudio(part)},
          );
          if (started == true) {
            _startNowPlaying(
              title,
              part: parts.indexOf(part) + 1,
              parts: parts.length,
            );
            // Playing from a Moment: only the first part starts part-way in.
            if (startMs > 0 && parts.indexOf(part) == firstPart) {
              await _relayChannel.invokeMethod<void>('seekPlayback', {
                'positionMs': startMs,
              });
            }
          }
          return started == true;
        },
        state: () async =>
            (await _relayChannel.invokeMapMethod<String, dynamic>(
                  'playbackStatus',
                ))?['state']
                as String?,
      );
    } on NoteSecurityException catch (error) {
      _setStatus('$error');
    } finally {
      // Only the sequence that is still current clears the bar; a newer play owns it.
      if (token == _playbackToken) {
        _sequencePlaying = false;
        _nowPlaying.value = null;
        _nowPlayingTimer?.cancel();
      }
    }
  }
}
