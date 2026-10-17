import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show lerpDouble;

import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'broadcast_audio.dart';
import 'firmware_image.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'telemetry.dart';
part 'backup.dart';
part 'board_parts.dart';
part 'sync_state.dart';
part 'circuit_playback.dart';
part 'groups.dart';
part 'long_notes.dart';
part 'moments.dart';
part 'music.dart';
part 'note_dates.dart';
part 'note_source.dart';
part 'now_playing.dart';
part 'phone_recording.dart';
part 'secure_notes.dart';
part 'ui/backup_page.dart';
part 'ui/capture_dock.dart';
part 'ui/broadcast_dialog.dart';
part 'ui/chat_page.dart';
part 'ui/detail_pages.dart';
part 'ui/onboarding.dart';
part 'ui/pages.dart';
part 'ui/recording_view.dart';
part 'ui/song_page.dart';
part 'ui/theme.dart';
part 'ui/tokens.dart';
part 'test_control.dart';
part 'ui/status_overlay.dart';

const _circuitName = 'Circuit';
final _textServiceId = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
final _textCharacteristicId = Guid('0000fff1-0000-1000-8000-00805f9b34fb');
final _relayCharacteristicId = Guid('0000fff2-0000-1000-8000-00805f9b34fb');
const _relayChannel = MethodChannel('circuit/relay');
const _audioStatusEvents = EventChannel('circuit/audio_status');
const _savedCircuitIdKey = 'saved_circuit_id';
const _notesKey = 'circuit_notes';
const _geminiApiKey = 'gemini_api_key';
const _geminiModelKey = 'gemini_model';
const _defaultGeminiModel = 'gemini-3.5-flash-lite';

/// The model that turns text into speech for Broadcast (separate from the one that reads notes).
const _speechModel = 'gemini-2.5-flash-preview-tts';
const _aiApiKey = 'hermes_api_key';
const _aiBaseUrlKey = 'hermes_base_url';
const _aiModelKey = 'hermes_model';
const _defaultAiModel = 'hermes-agent';
const _defaultAiBaseUrl = 'https://hermes.yourdomain.com/v1';
const _secureStorage = FlutterSecureStorage();

/// Pairing opens Android's pairing dialog, so it must only follow a deliberate tap on
/// Connect or Repair pairing, never an automatic reconnect.
bool shouldStartCircuitPairing({
  required bool isBonded,
  required bool userRequestedPairing,
}) => !isBonded && userRequestedPairing;

/// Tapping Connect on a Circuit found by scanning means "pair this one". If Android
/// already lists it as paired, that record may be stale (the board forgot the phone, but
/// the phone did not forget the board) and Samsung hides such devices from its settings,
/// so the person cannot remove it by hand. The old record is replaced, as Repair does.
bool shouldReplaceCircuitPairing({
  required bool isBonded,
  required bool userRequestedPairing,
}) => isBonded && userRequestedPairing;

/// 'Phone' or 'Circuit' from the recording's file. This phone's recorder names its files
/// phone-note-<number>.cnote; everything else, from Circuit's synced files (circuit-note-...)
/// to a recording still waiting to sync or a song clip, was made by the board.
String noteSourceOf(String? audioPath) =>
    (audioPath?.split('/').last ?? '').startsWith('phone-note-')
    ? 'Phone'
    : 'Circuit';

/// The two counts Circuit shows on its own screen: notes still waiting to reach the phone,
/// and notes that have. They are Circuit's notes only. A recording made on the phone never
/// went through the board, so it must not appear in the board's totals.
({int pending, int synced}) boardNoteCounts(Iterable<CircuitNote> notes) {
  var pending = 0;
  var synced = 0;
  for (final note in notes) {
    if (note.source == 'Phone') continue;
    note.audioPath == null ? pending++ : synced++;
  }
  return (pending: pending, synced: synced);
}

/// How far along a note is, from its audio to its AI review. "Transcribed" means the text is
/// there but the AI review has not run; once it has, the note says so.
String noteStageLabel(CircuitNote note) {
  if (note.enrichmentStatus == 'enriching') return 'AI reviewing';
  if (note.enrichmentStatus == 'failed') return 'AI review failed';
  if (note.actionSuggestions.any((item) => item.state == 'pending')) {
    return 'Action to review';
  }
  if (note.transcript != null) {
    return note.enrichmentStatus == 'ready' ? 'AI reviewed' : 'Transcribed';
  }
  if (note.audioPath != null) return 'Ready to transcribe';
  return 'Waiting to sync';
}

/// What the phone's link to Circuit is doing, read from the background service's status.
/// "Running" is not "connected": the service also runs while it is still trying.
enum RelayLink { off, trying, connected, needsRepair }

RelayLink relayLinkFromStatus(String? status) {
  if (status == null || status == 'Stopped') return RelayLink.off;
  if (status.startsWith('Circuit needs repair')) return RelayLink.needsRepair;
  // Bluetooth is up in both; the second only means the phone has no internet to sync with.
  if (status == 'Connected to Circuit' ||
      status == 'Phone internet unavailable') {
    return RelayLink.connected;
  }
  return RelayLink
      .trying; // connecting, securing, waiting to reconnect, Bluetooth off
}

/// Whether a note should get its AI review without being asked: only with an AI service set up
/// and the Settings toggle on. The "Run AI review" button always works.
bool shouldEnrichAutomatically({
  required bool aiConnected,
  required bool autoEnrich,
}) => aiConnected && autoEnrich;

/// The text of Gemini's answer. An answer with no text because the request was blocked or
/// cut short is an error to report, not "no speech": silence comes back as an empty or
/// [[NOISE]] answer to a request that went through.
String? geminiAnswerText(Map<String, dynamic> decoded) {
  final candidates = decoded['candidates'] as List<dynamic>?;
  if (candidates == null || candidates.isEmpty) {
    final blocked =
        (decoded['promptFeedback'] as Map<String, dynamic>?)?['blockReason'];
    throw Exception(
      'Gemini gave no answer${blocked == null ? '' : ' (blocked: $blocked)'}.',
    );
  }
  final candidate = candidates.first as Map<String, dynamic>;
  final parts =
      (candidate['content'] as Map<String, dynamic>?)?['parts']
          as List<dynamic>?;
  final text = parts
      ?.whereType<Map<String, dynamic>>()
      .map((part) => part['text'])
      .whereType<String>()
      .join()
      .trim();
  final reason = candidate['finishReason'] as String?;
  if ((text == null || text.isEmpty) &&
      reason != null &&
      reason != 'STOP' &&
      reason != 'FINISH_REASON_UNSPECIFIED') {
    throw Exception('Gemini stopped without an answer ($reason).');
  }
  return text;
}

class GeminiClient {
  const GeminiClient();

  Future<String?> apiKey() => _secureStorage.read(key: _geminiApiKey);

  Future<String> model() async =>
      await _secureStorage.read(key: _geminiModelKey) ?? _defaultGeminiModel;

  Future<void> save({required String apiKey, required String model}) async {
    await _secureStorage.write(key: _geminiApiKey, value: apiKey.trim());
    await _secureStorage.write(
      key: _geminiModelKey,
      value: model.trim().isEmpty ? _defaultGeminiModel : model.trim(),
    );
  }

  Future<void> clear() async {
    await _secureStorage.delete(key: _geminiApiKey);
    await _secureStorage.delete(key: _geminiModelKey);
  }

  Future<void> testConnection() async {
    final key = await apiKey();
    if (key == null || key.trim().isEmpty) {
      throw Exception('Enter a Gemini API key first.');
    }
    final selectedModel = await model();
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$selectedModel:generateContent?key=${Uri.encodeQueryComponent(key)}',
    );
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': 'Reply with exactly: Circuit connected.'},
                ],
              },
            ],
            'generationConfig': {'responseMimeType': 'application/json'},
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Gemini ${response.statusCode}: ${response.body}');
    }
  }

  /// Speaks [text] with Gemini and returns a clip Circuit can play (see broadcast_audio.dart).
  Future<Uint8List> speakWav(String text) async {
    final key = await apiKey();
    if (key == null || key.trim().isEmpty) {
      throw Exception('Add a Gemini API key in Settings first.');
    }
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$_speechModel:generateContent?key=${Uri.encodeQueryComponent(key)}',
    );
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': text},
                ],
              },
            ],
            'generationConfig': {
              'responseModalities': ['AUDIO'],
              'speechConfig': {
                'voiceConfig': {
                  'prebuiltVoiceConfig': {'voiceName': 'Charon'},
                },
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Gemini ${response.statusCode}: ${response.body}');
    }
    return broadcastWavFromGeminiReply(response.body);
  }

  Future<GeminiTranscription> transcribeWav(
    Uint8List wavBytes, {
    bool detectMusic = true,
    PartContext? part,
    List<int> momentsMs = const [],
  }) async {
    final key = await apiKey();
    if (key == null || key.trim().isEmpty) {
      throw Exception('Add a Gemini API key in Settings first.');
    }
    final selectedModel = await model();
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$selectedModel:generateContent?key=${Uri.encodeQueryComponent(key)}',
    );
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {
                    'text':
                        'Transcribe this voice note exactly, in the language or languages actually spoken. Write Hindi in Devanagari script, Gujarati in Gujarati script, English in English, and mixed speech as it is spoken, switching script with the language. Never translate it, and never write Hindi or Gujarati in Roman letters: for example, Hindi speech that sounds like "mujhe yeh kaam kal karna hai" must be written "मुझे यह काम कल करना है", while English words spoken inside Hindi speech stay in English letters. Return the complete transcription only. Do not summarise, classify, translate, or add a title.'
                        '${detectMusic ? ' Exception: if the recording is mainly music or a song playing, with no one speaking to record a note, reply with exactly [[MUSIC]] and nothing else.' : ''}'
                        ' If two or more different people clearly speak, start each change of speaker on a new line labelled "Speaker 1:", "Speaker 2:" and so on, using the same label for the same voice throughout. If only one person speaks, add no label.'
                        ' If the recording sounds like a phone call (a conversation heard through a phone, with telephone-quality audio, ringing, or a call being answered or ended), begin your reply with [[CALL]] followed by the transcription.'
                        ' If it is only silence or background noise, reply with exactly [[NOISE]].'
                        '${_partInstruction(part)}'
                        '${Moments.transcriptionInstruction(momentsMs)}',
                  },
                  {
                    'inline_data': {
                      'mime_type': 'audio/wav',
                      'data': base64Encode(wavBytes),
                    },
                  },
                ],
              },
            ],
            'generationConfig': {'responseMimeType': 'text/plain'},
          }),
        )
        .timeout(const Duration(minutes: 2));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Gemini ${response.statusCode}: ${response.body}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return parseTranscriptionText(
      geminiAnswerText(decoded),
      allowMusic: detectMusic,
    );
  }

  /// For one part of a long recording: where it sits, and the text before it, so the
  /// model carries names, topics and speaker labels on without repeating anything.
  static String _partInstruction(PartContext? part) {
    if (part == null) return '';
    final buffer = StringBuffer(
      ' This is part ${part.number} of ${part.count} of one longer recording, in order. '
      'It may begin or end in the middle of a sentence: transcribe exactly what is said in this part only.',
    );
    if (part.earlier.isNotEmpty) {
      buffer.write(
        ' The transcript so far ends with the text between the markers, for context only; '
        'do not repeat it, and keep the same speaker labels for the same voices.'
        '\n<<<\n${part.earlier}\n>>>',
      );
    }
    return buffer.toString();
  }

  /// Turns Gemini's plain-text answer into a transcription. A recording of
  /// music comes back as the [[MUSIC]] marker, silence as [[NOISE]], and a phone
  /// call as a [[CALL]] prefix ahead of the transcript.
  static GeminiTranscription parseTranscriptionText(
    String? answer, {
    bool allowMusic = true,
  }) {
    final result = answer?.trim() ?? '';
    if (result.isEmpty ||
        result.startsWith('[[NOISE]]') ||
        (!allowMusic && result.startsWith('[[MUSIC]]'))) {
      throw const NoSpeechDetected();
    }
    if (result.startsWith('[[MUSIC]]')) {
      return const GeminiTranscription(
        category: 'music',
        title: 'Song',
        transcript: '',
        audioType: 'music',
      );
    }
    final isCall = result.startsWith('[[CALL]]');
    final text = isCall ? result.substring('[[CALL]]'.length).trim() : result;
    if (text.isEmpty) throw Exception('No speech detected.');
    return GeminiTranscription(
      category: 'note',
      title: const GeminiClient()._fallbackHeading(text),
      transcript: text,
      isCall: isCall,
    );
  }

  String _fallbackHeading(String transcript) {
    final words = transcript
        .replaceAll(RegExp(r'Speaker \d+:\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((word) => word.isNotEmpty)
        .take(7)
        .toList();
    if (words.isEmpty) return 'Voice note';
    final heading = words.join(' ');
    return heading.length > 48 ? '${heading.substring(0, 48)}…' : heading;
  }
}

/// Extracts the user-facing fields from Gemini's JSON response.
///
/// Gemini can return a fenced JSON block, a JSON object surrounded by a short
/// explanation, or (with some model versions) a JSON envelope whose useful
/// object is nested in `result`/`data`. Never show that envelope as the note
/// transcript.
Map<String, dynamic>? parseGeminiTranscriptionPayload(String value) {
  var text = value.trim();
  text = text.replaceFirst(
    RegExp(r'^```(?:json)?\s*', caseSensitive: false),
    '',
  );
  text = text.replaceFirst(RegExp(r'\s*```$'), '').trim();

  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }
  if (decoded is! Map) return null;

  final map = Map<String, dynamic>.from(decoded);
  final nested = map['result'] ?? map['data'] ?? map['output'];
  if (nested is Map) {
    final parsedNested = parseGeminiTranscriptionPayload(jsonEncode(nested));
    if (parsedNested != null) return parsedNested;
  }

  final rawTranscript = map['transcript'] ?? map['text'] ?? map['content'];
  if (rawTranscript is! String || rawTranscript.trim().isEmpty) return null;
  var transcript = rawTranscript.trim();

  // Some responses put the actual transcription JSON inside `text`.
  final nestedTranscript = parseGeminiTranscriptionPayload(transcript);
  if (nestedTranscript != null) {
    return nestedTranscript;
  }
  return {
    'category': map['category'] is String ? map['category'] : 'note',
    'title': map['title'] is String ? map['title'] : null,
    'transcript': transcript,
  };
}

const _gemini = GeminiClient();

class NoteActionSuggestion {
  const NoteActionSuggestion({
    required this.id,
    required this.type,
    required this.title,
    required this.details,
    this.scheduledAt,
    this.state = 'pending',
  });

  final String id;
  final String type;
  final String title;
  final String details;
  final String? scheduledAt;
  final String state;

  factory NoteActionSuggestion.fromJson(Map<String, dynamic> json) =>
      NoteActionSuggestion(
        id:
            json['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        type: json['type']?.toString() ?? 'task',
        title: json['title']?.toString() ?? 'Suggested action',
        details: json['details']?.toString() ?? '',
        scheduledAt: json['scheduledAt']?.toString(),
        state: json['state']?.toString() ?? 'pending',
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'details': details,
    if (scheduledAt != null) 'scheduledAt': scheduledAt,
    'state': state,
  };

  NoteActionSuggestion copyWith({String? state}) => NoteActionSuggestion(
    id: id,
    type: type,
    title: title,
    details: details,
    scheduledAt: scheduledAt,
    state: state ?? this.state,
  );
}

class AiEnrichment {
  const AiEnrichment({
    required this.title,
    required this.category,
    required this.categories,
    required this.tags,
    required this.summary,
    required this.englishTranslation,
    required this.language,
    required this.actions,
  });

  final String title;
  final String category;
  final List<String> categories;
  final List<String> tags;
  final String summary;
  final String englishTranslation;
  final String language;
  final List<NoteActionSuggestion> actions;
}

class ChatMessage {
  const ChatMessage({required this.role, required this.text, required this.at});

  /// 'user' or 'assistant'.
  final String role;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'at': at.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role']?.toString() == 'user' ? 'user' : 'assistant',
    text: json['text']?.toString() ?? '',
    at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
  );
}

class AiClient {
  const AiClient();

  Future<String?> apiKey() => _secureStorage.read(key: _aiApiKey);
  Future<String> baseUrl() async {
    final saved = (await _secureStorage.read(key: _aiBaseUrlKey))?.trim();
    return saved == null || saved.isEmpty ? _defaultAiBaseUrl : saved;
  }

  Future<String> model() async =>
      await _secureStorage.read(key: _aiModelKey) ?? _defaultAiModel;

  Future<void> save({
    required String apiKey,
    required String baseUrl,
    required String model,
  }) async {
    await _secureStorage.write(key: _aiApiKey, value: apiKey.trim());
    await _secureStorage.write(key: _aiBaseUrlKey, value: baseUrl.trim());
    await _secureStorage.write(
      key: _aiModelKey,
      value: model.trim().isEmpty ? _defaultAiModel : model.trim(),
    );
  }

  Future<void> clear() async {
    await _secureStorage.delete(key: _aiApiKey);
    await _secureStorage.delete(key: _aiBaseUrlKey);
    await _secureStorage.delete(key: _aiModelKey);
  }

  /// Sends a chat-completions request and returns the reply text.
  Future<String> _send(
    List<Map<String, String>> messages, {
    required bool json,
    double temperature = 0.2,
  }) async {
    final key = await apiKey();
    if (key == null || key.trim().isEmpty)
      throw Exception('Add an AI service API key in Settings first.');
    final base = (await baseUrl()).replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) throw Exception('Add your AI service base URL first.');
    final response = await http
        .post(
          Uri.parse('$base/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${key.trim()}',
          },
          body: jsonEncode({
            'model': await model(),
            'messages': messages,
            'temperature': temperature,
            if (json) 'response_format': {'type': 'json_object'},
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('AI service ${response.statusCode}: ${response.body}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>?;
    String? content;
    if (choices != null && choices.isNotEmpty) {
      final choice = choices.first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>?;
      content = message?['content']?.toString();
    }
    if (content == null || content.trim().isEmpty)
      throw Exception('AI service returned no response.');
    return content;
  }

  Future<Map<String, dynamic>> _completion(
    List<Map<String, String>> messages,
  ) async {
    final content = await _send(messages, json: true);
    final start = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (start < 0 || end <= start)
      throw Exception('AI service returned invalid data.');
    return jsonDecode(content.substring(start, end + 1))
        as Map<String, dynamic>;
  }

  /// Answers a question about one note, using only that note as context.
  Future<String> chatAboutNote(
    CircuitNote note,
    List<ChatMessage> history,
  ) async {
    final context = StringBuffer()
      ..writeln('Title: ${note.title ?? 'Voice note'}')
      ..writeln('Recorded: ${note.createdAt.toLocal()}');
    if ((note.language ?? '').isNotEmpty) {
      context.writeln('Language: ${note.language}');
    }
    if ((note.summary ?? '').isNotEmpty) {
      context.writeln('Summary: ${note.summary}');
    }
    context
      ..writeln('Transcript:')
      ..writeln(note.transcript ?? '');
    if ((note.englishTranslation ?? '').isNotEmpty &&
        note.englishTranslation != note.transcript) {
      context
        ..writeln('English translation:')
        ..writeln(note.englishTranslation);
    }
    final recent = history.length > 12
        ? history.sublist(history.length - 12)
        : history;
    final reply = await _send(
      [
        {
          'role': 'system',
          'content':
              'You answer questions about one private voice note. Use only the note below. The transcript may label different voices as "Speaker 1:", "Speaker 2:"; use the labels when saying who said something, and do not guess real names unless the note states them. If the answer is not in the note, say so plainly instead of guessing. Be brief. Reply in the language the user writes in. Plain text, no markdown headings.\n\n--- NOTE ---\n$context',
        },
        for (final message in recent)
          {'role': message.role, 'content': message.text},
      ],
      json: false,
      temperature: 0.3,
    );
    return reply.trim();
  }

  Future<void> testConnection() async {
    await _completion([
      {'role': 'user', 'content': 'Reply as JSON only: {"ok":true}.'},
    ]);
  }

  /// Looks for a reminder with a date and time in a voice note.
  Future<ReminderDraft> extractReminder(
    String transcript, {
    DateTime? recordedAt,
  }) async {
    final response = await _completion([
      {
        'role': 'system',
        'content': 'You detect reminders in private voice-note transcripts. Return JSON only: {"hasReminder":true|false,"title":"short title in English","scheduledAt":"ISO-8601 local date-time or null","details":"brief detail in English"}. Set scheduledAt only when the note clearly states a date or time; never invent one. Preserve the meaning of Hindi and Gujarati.',
      },
      {
        'role': 'user',
        'content': '${_whenText(recordedAt)} Transcript:\n$transcript',
      },
    ]);
    final when = response['scheduledAt']?.toString();
    return ReminderDraft(
      hasReminder: response['hasReminder'] == true,
      title: (response['title']?.toString().trim().isNotEmpty ?? false)
          ? response['title'].toString().trim()
          : 'Reminder',
      scheduledAt: when == null || when == 'null'
          ? null
          : DateTime.tryParse(when),
      details: response['details']?.toString().trim() ?? transcript,
    );
  }

  Future<AiEnrichment> enrich(
    String transcript, {
    bool highlightMoments = true,
    DateTime? recordedAt,
  }) async {
    final response = await _completion([
      {
        'role': 'system',
        'content':
            'You analyse private voice-note transcripts. Return JSON only: {"title":"short heading in English","category":"primary category","categories":["primary category","optional secondary categories"],"tags":["short English searchable tags"],"summary":"one short English sentence","englishTranslation":"faithful English translation; if already English, repeat it","language":"language or mixed","actions":[{"type":"task|reminder|calendar_event","title":"action title in English","details":"brief detail in English","scheduledAt":"ISO-8601 local time or null"}]}. Categories may include note, idea, task, reminder, calendar_event, shopping, journal, project, meeting, reference. Translate Hindi/Gujarati faithfully but never alter the original transcript. The transcript may label voices as "Speaker 1:", "Speaker 2:"; keep those labels in englishTranslation, say who said or agreed to what in the summary and action details when it matters, and never use a speaker label as a title or tag. Suggest an action only when the speaker says they themselves must do, remember or attend something. News, commentary, opinions and events involving other people are not actions: for those return an empty actions list. Never invent dates. Use reminder or calendar_event only when the note states a date or time that has not passed yet when the note was recorded; otherwise the action type must be task, or leave it out.'
            '${highlightMoments && Moments.hasMarkers(transcript) ? Moments.reviewInstruction : ''}',
      },
      {
        'role': 'user',
        'content': '${_whenText(recordedAt)} Transcript:\n$transcript',
      },
    ]);
    const valid = {
      'note',
      'idea',
      'task',
      'reminder',
      'calendar_event',
      'shopping',
      'journal',
      'project',
      'meeting',
      'reference',
    };
    final categories = (response['categories'] as List<dynamic>? ?? const [])
        .map((value) => value.toString().trim().toLowerCase())
        .where((value) => valid.contains(value))
        .toSet()
        .toList();
    final primary = valid.contains(response['category']?.toString())
        ? response['category'].toString()
        : 'note';
    if (!categories.contains(primary)) categories.insert(0, primary);
    final tags = (response['tags'] as List<dynamic>? ?? const [])
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .take(8)
        .toSet()
        .toList();
    final actions = (response['actions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (item) => NoteActionSuggestion(
            id:
                DateTime.now().microsecondsSinceEpoch.toString() +
                item.hashCode.toString(),
            // Anything without a usable date or time is a plain task.
            type:
                {'reminder', 'calendar_event'}.contains(item['type']) &&
                    DateTime.tryParse(item['scheduledAt']?.toString() ?? '') !=
                        null
                ? item['type'].toString()
                : 'task',
            title: item['title']?.toString().trim().isNotEmpty == true
                ? item['title'].toString().trim()
                : 'Suggested task',
            details: item['details']?.toString().trim() ?? '',
            scheduledAt: item['scheduledAt']?.toString() == 'null'
                ? null
                : item['scheduledAt']?.toString(),
          ),
        )
        .toList();
    return AiEnrichment(
      title: response['title']?.toString().trim().isNotEmpty == true
          ? response['title'].toString().trim()
          : 'Voice note',
      category: primary,
      categories: categories,
      tags: tags,
      summary: response['summary']?.toString().trim() ?? '',
      englishTranslation:
          response['englishTranslation']?.toString().trim() ?? transcript,
      language: response['language']?.toString().trim() ?? '',
      actions: dropPastActions(actions, recordedAt ?? DateTime.now()),
    );
  }
}

/// Keeps the actions that can still be acted on. A reminder or event for a time that had already
/// passed when the note was recorded is something the AI misread (often a news item).
List<NoteActionSuggestion> dropPastActions(
  List<NoteActionSuggestion> actions,
  DateTime recordedAt,
) => [
  for (final action in actions)
    if (action.type == 'task' ||
        DateTime.tryParse(action.scheduledAt ?? '') == null ||
        DateTime.parse(action.scheduledAt!)
            .isAfter(recordedAt.subtract(const Duration(minutes: 5))))
      action,
];

/// Tells the AI when the note was spoken, so "tomorrow" or "on Friday" means the right day
/// even when the note is transcribed later.
String _whenText(DateTime? recordedAt) {
  const days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  final spoken = (recordedAt ?? DateTime.now()).toLocal();
  final now = DateTime.now();
  return 'The note was recorded on ${days[spoken.weekday - 1]} ${spoken.toIso8601String()}; '
      'it is now ${days[now.weekday - 1]} ${now.toIso8601String()}. '
      'Work out relative dates from when it was recorded.';
}

const _ai = AiClient();
const _songClipSeconds = 12;
final _music = MusicClient();

class GeminiTranscription {
  const GeminiTranscription({
    required this.category,
    required this.title,
    required this.transcript,
    this.audioType = 'speech',
    this.isCall = false,
  });

  final String category;
  final String title;
  final String transcript;

  /// 'speech', or 'music' when the recording is a song rather than a note.
  final String audioType;

  /// The recording sounds like a phone call.
  final bool isCall;

  bool get isMusic => audioType == 'music';
}

class ReminderDraft {
  const ReminderDraft({
    required this.hasReminder,
    required this.title,
    required this.scheduledAt,
    required this.details,
  });

  final bool hasReminder;
  final String title;
  final DateTime? scheduledAt;
  final String details;
}

/// One transcription of a note: which model wrote it, when, and exactly what it said. Kept apart from the
/// working transcript (which the person can edit) so the original is never lost and runs by different
/// models can be compared.
class TranscriptRun {
  const TranscriptRun({
    required this.model,
    required this.text,
    required this.at,
  });
  final String model;
  final String text;
  final DateTime at;

  factory TranscriptRun.fromJson(Map<String, dynamic> json) => TranscriptRun(
    model: json['model']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'model': model,
    'text': text,
    'at': at.toIso8601String(),
  };
}

class CircuitNote {
  const CircuitNote({
    required this.id,
    required this.createdAt,
    required this.status,
    this.audioPath,
    this.transcript,
    this.title,
    this.category,
    this.categories = const [],
    this.tags = const [],
    this.summary,
    this.englishTranslation,
    this.language,
    this.enrichmentStatus = 'pending',
    this.actionSuggestions = const [],
    this.boardId,
    this.kind = 'voice',
    this.song,
    this.titleEdited = false,
    this.audioParts = const [],
    this.partTexts = const [],
    this.isCall = false,
    this.transcriptRuns = const [],
    this.transcriptEdited = false,
    this.reviewStale = false,
    this.reviewModel,
    this.ownMoments = const [],
  });

  final String id;
  final DateTime createdAt;
  final String status;
  final String? audioPath;
  final String? transcript;
  final String? title;
  final String? category;
  final List<String> categories;
  final List<String> tags;
  final String? summary;
  final String? englishTranslation;
  final String? language;

  /// pending, enriching, ready, failed. Transcript remains usable on failure.
  final String enrichmentStatus;
  final List<NoteActionSuggestion> actionSuggestions;

  /// Number Circuit gave the recording; identifies it exactly once.
  final int? boardId;

  /// 'voice' for a spoken note, 'song' for a clip sent to song recognition.
  final String kind;
  final SongResult? song;

  /// True once the user has chosen the title; AI review then leaves it alone.
  final bool titleEdited;

  /// A long recording is stored as an ordered series of one-minute files. This lists all
  /// of them (the first is also [audioPath]); it is empty for a note with a single file.
  final List<String> audioParts;

  /// The text of each part, in order, kept as transcription goes so that a failure
  /// resumes at the first part still missing. null = not done yet, '' = silent part.
  final List<String?> partTexts;

  /// Every audio file the note owns, in playing order.
  List<String> get audioFiles => audioParts.isNotEmpty
      ? audioParts
      : (audioPath == null ? const [] : [audioPath!]);

  /// Transcription judged this recording to be a phone call.
  final bool isCall;

  /// Every transcription made of this note, oldest first. [transcript] is the working copy: it starts as
  /// the latest run and is what AI review reads; the person may edit it without touching the runs.
  final List<TranscriptRun> transcriptRuns;

  /// The working transcript differs from the latest run because the person edited it.
  final bool transcriptEdited;

  /// The transcript changed after the last AI review, so the summary may be out of date.
  final bool reviewStale;

  /// The model that wrote the current AI review.
  final String? reviewModel;

  /// Moments added in this app while it recorded (the phone's own recorder), in ms from the start of the
  /// whole note. A Circuit recording's Moments are in files beside its parts instead (moments.dart).
  final List<int> ownMoments;

  bool get isSong => kind == 'song';

  /// A note written on the phone: it never had audio and never comes from Circuit.
  bool get isText => kind == 'text';

  /// Where the recording was made: 'Phone' (this phone's own recorder) or 'Circuit'.
  String get source => isText ? 'Phone' : noteSourceOf(audioPath);

  factory CircuitNote.fromJson(Map<String, dynamic> json) => CircuitNote(
    id: json['id'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: json['status'] as String,
    audioPath: json['audioPath'] as String?,
    transcript: json['transcript'] as String?,
    title: json['title'] as String?,
    category: json['category'] as String?,
    categories: (json['categories'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(),
    tags: (json['tags'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(),
    summary: json['summary'] as String?,
    englishTranslation: json['englishTranslation'] as String?,
    language: json['language'] as String?,
    enrichmentStatus: json['enrichmentStatus']?.toString() ?? 'pending',
    actionSuggestions: (json['actionSuggestions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(NoteActionSuggestion.fromJson)
        .toList(),
    boardId: int.tryParse(json['boardId']?.toString() ?? ''),
    kind: switch (json['kind']?.toString()) {
      'song' => 'song',
      'text' => 'text',
      _ => 'voice',
    },
    song: json['song'] is Map<String, dynamic>
        ? SongResult.fromJson(json['song'] as Map<String, dynamic>)
        : null,
    titleEdited: json['titleEdited'] == true,
    audioParts: (json['audioParts'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(),
    partTexts: (json['partTexts'] as List<dynamic>? ?? const [])
        .map((value) => value?.toString())
        .toList(),
    isCall: json['isCall'] == true,
    transcriptRuns: (json['transcriptRuns'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TranscriptRun.fromJson)
        .toList(),
    transcriptEdited: json['transcriptEdited'] == true,
    reviewStale: json['reviewStale'] == true,
    reviewModel: json['reviewModel'] as String?,
    ownMoments: (json['moments'] as List<dynamic>? ?? const [])
        .whereType<num>()
        .map((value) => value.toInt())
        .toList(),
  );

  CircuitNote copyWith({
    String? status,
    String? audioPath,
    String? transcript,
    String? title,
    String? category,
    List<String>? categories,
    List<String>? tags,
    String? summary,
    String? englishTranslation,
    String? language,
    String? enrichmentStatus,
    List<NoteActionSuggestion>? actionSuggestions,
    int? boardId,
    SongResult? song,
    String? kind,
    bool? titleEdited,
    List<String>? audioParts,
    List<String?>? partTexts,
    bool? isCall,
    List<TranscriptRun>? transcriptRuns,
    bool? transcriptEdited,
    bool? reviewStale,
    String? reviewModel,
    List<int>? ownMoments,
    bool clearSong = false,
  }) => CircuitNote(
    id: id,
    createdAt: createdAt,
    status: status ?? this.status,
    audioPath: audioPath ?? this.audioPath,
    transcript: transcript ?? this.transcript,
    title: title ?? this.title,
    category: category ?? this.category,
    categories: categories ?? this.categories,
    tags: tags ?? this.tags,
    summary: summary ?? this.summary,
    englishTranslation: englishTranslation ?? this.englishTranslation,
    language: language ?? this.language,
    enrichmentStatus: enrichmentStatus ?? this.enrichmentStatus,
    actionSuggestions: actionSuggestions ?? this.actionSuggestions,
    boardId: boardId ?? this.boardId,
    kind: kind ?? this.kind,
    song: clearSong ? null : (song ?? this.song),
    titleEdited: titleEdited ?? this.titleEdited,
    audioParts: audioParts ?? this.audioParts,
    partTexts: partTexts ?? this.partTexts,
    isCall: isCall ?? this.isCall,
    transcriptRuns: transcriptRuns ?? this.transcriptRuns,
    transcriptEdited: transcriptEdited ?? this.transcriptEdited,
    reviewStale: reviewStale ?? this.reviewStale,
    reviewModel: reviewModel ?? this.reviewModel,
    ownMoments: ownMoments ?? this.ownMoments,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'status': status,
    if (audioPath != null) 'audioPath': audioPath!,
    if (transcript != null) 'transcript': transcript!,
    if (title != null) 'title': title!,
    if (category != null) 'category': category!,
    if (categories.isNotEmpty) 'categories': categories,
    if (tags.isNotEmpty) 'tags': tags,
    if (summary != null) 'summary': summary!,
    if (englishTranslation != null) 'englishTranslation': englishTranslation!,
    if (language != null) 'language': language!,
    'enrichmentStatus': enrichmentStatus,
    if (actionSuggestions.isNotEmpty)
      'actionSuggestions': actionSuggestions
          .map((item) => item.toJson())
          .toList(),
    if (boardId != null) 'boardId': boardId.toString(),
    if (isSong || isText) 'kind': kind,
    if (song != null) 'song': song!.toJson(),
    if (titleEdited) 'titleEdited': true,
    if (audioParts.isNotEmpty) 'audioParts': audioParts,
    if (partTexts.isNotEmpty) 'partTexts': partTexts,
    if (isCall) 'isCall': true,
    if (transcriptRuns.isNotEmpty)
      'transcriptRuns': transcriptRuns.map((r) => r.toJson()).toList(),
    if (transcriptEdited) 'transcriptEdited': true,
    if (reviewStale) 'reviewStale': true,
    if (reviewModel != null) 'reviewModel': reviewModel!,
    if (ownMoments.isNotEmpty) 'moments': ownMoments,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterCryptography.enable(); // native AES-GCM, much faster than Dart on long notes
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  await Telemetry.init();
  runApp(const ShortCircuitApp());
}

/// Circuit's Wi-Fi status: "@wifi-status", the state, the network name, then the detail (its IP
/// address when connected, the reason when not) and, from newer firmware, a last "mac=" line.
class WifiStatus {
  const WifiStatus(this.state, this.ssid, this.detail, this.mac);
  final String state;
  final String ssid;
  final String detail;
  final String mac;
}

WifiStatus? parseWifiStatus(String message) {
  final lines = message.split('\n');
  if (lines.length < 2) return null;
  var tail = lines.length > 3 ? lines.sublist(3) : <String>[];
  var mac = '';
  if (tail.isNotEmpty && tail.last.startsWith('mac=')) {
    mac = tail.last.substring(4).trim();
    tail = tail.sublist(0, tail.length - 1);
  }
  return WifiStatus(
    lines[1],
    lines.length > 2 ? lines[2] : '',
    tail.join('\n'),
    mac,
  );
}

enum _AppPage { notes, tasks, settings, circuit, wifi, hiddenWifi, group }

const _tasksKey = 'circuit_tasks';
const _boardDeletesKey = 'pending_board_deletes';
const _autoTranscribeKey = 'auto_transcribe';
const _autoEnrichKey = 'auto_enrich';
const _useMomentsKey = 'use_moments';

class CircuitTask {
  const CircuitTask({
    required this.id,
    required this.title,
    this.detail,
    this.done = false,
    this.dueAt,
  });

  final String id;
  final String title;
  final String? detail;
  final bool done;

  /// When the app should ring a reminder; null for a task with no time.
  final DateTime? dueAt;

  CircuitTask copyWith({bool? done, DateTime? dueAt, bool clearDue = false}) =>
      CircuitTask(
        id: id,
        title: title,
        detail: detail,
        done: done ?? this.done,
        dueAt: clearDue ? null : dueAt ?? this.dueAt,
      );

  factory CircuitTask.fromJson(Map<String, dynamic> json) => CircuitTask(
    id: json['id'] as String,
    title: json['title'] as String,
    detail: json['detail'] as String?,
    done: json['done'] == true,
    dueAt: DateTime.tryParse(json['dueAt']?.toString() ?? ''),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (detail != null) 'detail': detail,
    'done': done,
    if (dueAt != null) 'dueAt': dueAt!.toIso8601String(),
  };
}

class ShortCircuitApp extends StatelessWidget {
  const ShortCircuitApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Light, dark or the phone's setting (Settings > Appearance). Screens read their colours from
    // context.sc (tokens.dart).
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Short-Circuit',
        theme: buildScTheme(),
        darkTheme: buildScDarkTheme(),
        themeMode: mode,
        navigatorObservers: [statusRouteObserver],
        builder: (context, child) =>
            StatusOverlay(child: child ?? const SizedBox.shrink()),
        home: const CircuitHomePage(),
      ),
    );
  }
}

class CircuitHomePage extends StatefulWidget {
  const CircuitHomePage({super.key});

  @override
  State<CircuitHomePage> createState() => _CircuitHomePageState();
}

class _CircuitHomePageState extends State<CircuitHomePage>
    with
        WidgetsBindingObserver,
        _PhoneRecordingState,
        _NowPlayingState,
        _LongNoteState {
  final _wifiSsidController = TextEditingController();
  final _wifiPasswordController = TextEditingController();
  final _noteSearchController = TextEditingController();
  final Map<String, ScanResult> _circuits = {};

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _relaySubscription;
  StreamSubscription<String>? _audioStatusSubscription;
  Timer? _relayStatusTimer;
  Timer? _homeStatusTimer;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _textCharacteristic;
  BluetoothCharacteristic? _relayCharacteristic;
  bool _scanning = false;
  bool _connecting = false;
  bool _provisioningWifi = false;
  bool _scanningWifi = false;
  _AppPage _page = _AppPage.notes;
  final List<_AppPage> _pageHistory = [];
  List<CircuitTask> _tasks = [];
  bool _autoTranscribe = true;
  bool _autoEnrich =
      true; // AI review (title, summary, tags, actions) after a transcript
  bool _useMoments =
      true; // tell the AI where Circuit's Moments (bookmarks) fall

  /// How long each note plays, shown on its card. Worked out from the file sizes, once per note
  /// and number of parts, and kept here so a card does not read files every time it is drawn.
  final Map<String, int> _noteLengthMs = {};
  final Set<String> _noteLengthLoading = {};
  bool _shareDiagnostics = true;
  bool _testMode = false; // lets adb drive the app, see test_control.dart
  bool _geminiConnected = false;
  bool _aiConnected = false;
  bool _musicConnected = false;

  /// Id of the newest notes key this phone holds, or null if Circuit has not sent one.
  int? _noteKeyId;
  DateTime? _lastKeyRequestAt;

  /// True from tapping Identify song until Circuit reports that clip saved, so
  /// the new recording is kept as a song rather than a voice note.
  /// It lapses on its own, so a refused or lost request cannot turn the next
  /// ordinary recording into a song.
  DateTime? _songArmedAt;
  bool get _songClipArmed {
    final armedAt = _songArmedAt;
    return armedAt != null &&
        DateTime.now().difference(armedAt) <
            Duration(seconds: _songClipSeconds + 30);
  }

  set _songClipArmed(bool armed) =>
      _songArmedAt = armed ? DateTime.now() : null;

  final Set<String> _identifyingSongs = {};
  bool _showOnboarding = false; // first run: the welcome screens
  bool _circuitDetailsOpen = false;
  bool _dockCollapsed = false;

  /// How far each note is through its download, by Circuit's number for it, while a sync runs; and which note
  /// of how many it is. The phone reports it as "Sync note #172: 40% (2 of 5)".
  final Map<int, int> _noteProgress = {};
  int _syncNoteIndex = 0;
  int _syncNoteCount = 0;
  bool _searchOpen = false;
  bool _developerOpen =
      false; // the Developer rows in Settings are folded away until asked for
  DateTime? _recordingStartedAt;
  Timer? _clockTicker;
  // Automatic retry of AI review: how often each note was tried, and when.
  final Map<String, int> _enrichAttempts = {};
  final Map<String, DateTime> _enrichLastAttempt = {};
  // Notes deleted in the app whose copy on Circuit still has to be removed.
  final Set<int> _pendingBoardDeletes = {};
  NoteDeleteChoice?
  _pendingDeleteChoice; // what the person picked in the delete dialog
  DateTime? _lastBoardDeleteSent;
  String? _lastHomeCounts;
  DateTime? _lastHomeSentAt;
  // Sync health, shown to the user so a failed or stuck sync is never silent.
  bool _syncActive = false;
  String? _syncError;
  DateTime? _lastSyncActivity;
  DateTime? _lastSyncOk;
  int? _boardWaiting; // notes Circuit says are still waiting to sync
  DateTime? _waitingSince;
  int? _boardReset; // esp_reset_reason of Circuit's last start
  int _boardUptime = 0;

  /// Circuit's battery, 0 to 100, from its last status; null until it has reported one.
  int? _boardBattery;
  ({String version, String built})? _boardFirmware;
  ({String version, String built})? _boardPrevious;
  ({int usedKb, int totalKb})? _boardStorage;
  bool _resetNoticeShown = false;
  // What Circuit reports about its own Wi-Fi: none, connecting, connected, failed.
  String _wifiState = 'none';
  String _wifiSsid = '';
  String _wifiDetail = '';
  String _wifiMac = ''; // Circuit's Wi-Fi MAC address, once it has said
  bool _showWifiPassword = false;
  DateTime? _wifiConnectingSince;
  Timer? _wifiPollTimer;
  bool _audioBusy = false;
  CircuitPlaybackPhase _circuitPlayback = CircuitPlaybackPhase.idle;
  String? _circuitPlaybackFeedback;
  bool _circuitPlaybackSupportsStop = false;
  Timer? _playbackRequestTimer;
  bool _recordingAudio = false;
  bool _relayActive = false; // the background service is running
  RelayLink _relayLink = RelayLink.off; // what its link to Circuit is doing
  String _noteSource =
      noteSourceAll; // the Notes page filter: All, Phone or Circuit
  // Android no longer holds Circuit's pairing; the user chooses when to pair again.
  bool _needsPairingRepair = false;
  List<String> _wifiNetworks = [];
  List<CircuitNote> _notes = [];
  List<NoteGroup> _groups = [];
  // Choosing notes to group, on the Notes tab.
  bool _selecting = false;
  bool _groupsExpanded =
      false; // Notes tab shows the first few groups until asked for all
  final Set<String> _selectedNoteIds = {};
  String?
  _openGroupId; // the group page's group (allNotesGroupId for everything)
  String? _savedCircuitId;
  String? _lastAudioStatus;
  String? _syncingNoteId;
  String? _transcribingNoteId;
  bool _broadcasting = false;
  bool _updatingFirmware = false;
  FirmwareImage?
  _bundledFirmwareImage; // the firmware that came with this app, once read
  int? _syncProgress;
  String _status = 'Tap Scan to find your Circuit.';

  @override
  void initState() {
    super.initState();
    unawaited(
      _bundledFirmware().then((image) {
        if (mounted) setState(() => _bundledFirmwareImage = image);
      }),
    );
    WidgetsBinding.instance.addObserver(this);
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      _onScanResults,
      onError: (Object error) => _setStatus('Scan failed: $error'),
    );
    _nowPlaying.addListener(_publishStatusUi);
    _phoneRecording.addListener(_publishStatusUi);
    _restoreLastCircuit();
    _initTestControl();
    unawaited(_openNotesAtStart());
    unawaited(_loadGroups());
    unawaited(_relayChannel.invokeMethod<bool>('requestLocalNetwork'));
    _loadPreferences();
    _loadGeminiState();
    _loadAiState();
    _loadMusicState();
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // Keeps the recording timer moving.
      if (mounted && _recordingAudio) setState(() {});
    });
    _wifiPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Circuit pushes its own changes, so it is only asked while a page that shows its Wi-Fi is on screen
      // (each question wakes the board and makes it answer with several packets).
      final watchingCircuit =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          (_page == _AppPage.circuit ||
              _page == _AppPage.wifi ||
              _page == _AppPage.hiddenWifi);
      if (watchingCircuit) _requestWifiStatus();
      _checkSyncHealth();
      _processBoardDeletes();
      _retryEnrichmentIfDue();
    });
    _clearAudioOnce();
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), _clearAudioOnce),
    );
    _audioStatusSubscription = _audioStatusEvents
        .receiveBroadcastStream()
        .cast<String>()
        .listen(_handleAudioStatus);
    _refreshRelayStatus();
    _relayStatusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshRelayStatus(),
    );
    _homeStatusTimer = Timer.periodic(
      const Duration(
        minutes: 5,
      ), // a slow refresh: the app also sends it whenever a count changes
      (_) => _sendHomeStatus(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back on screen: the widget may have opened the app to record, or may have recorded
    // while the app was away.
    if (state == AppLifecycleState.resumed) {
      unawaited(_recoverPhoneRecording().then((_) => _checkLaunchAction()));
      unawaited(_takeReminderEvents());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nowPlaying.removeListener(_publishStatusUi);
    _phoneRecording.removeListener(_publishStatusUi);
    statusPill.value = null;
    statusSnack.value = null;
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _relaySubscription?.cancel();
    _phoneRecorderSubscription?.cancel();
    _phoneRecording.dispose();
    _nowPlayingTimer?.cancel();
    _nowPlaying.dispose();
    _playbackRequestTimer?.cancel();
    _audioStatusSubscription?.cancel();
    _relayStatusTimer?.cancel();
    _homeStatusTimer?.cancel();
    _wifiPollTimer?.cancel();
    _clockTicker?.cancel();
    _wifiSsidController.dispose();
    _wifiPasswordController.dispose();
    _noteSearchController.dispose();
    super.dispose();
  }

  Future<void> _refreshRelayStatus() async {
    try {
      final status = await _relayChannel.invokeMethod<String>('status');
      if (!mounted || status == null) return;
      final needsRepair = status.startsWith('Circuit needs repair');
      if (needsRepair && !_needsPairingRepair) {
        Telemetry.event('pairing_repair_needed');
      }
      final active = status != 'Stopped' && !needsRepair;
      final link = relayLinkFromStatus(status);
      if (link != _relayLink) setState(() => _relayLink = link);
      if (active || _relayActive || needsRepair) {
        setState(() {
          _relayActive = active;
          _needsPairingRepair = needsRepair;
          if (_syncingNoteId == null) {
            _status = active
                ? status
                : (needsRepair ? status : 'Stay connected is off.');
          }
        });
      }
    } on PlatformException {
      // The app can still be used normally if the native relay is unavailable.
    }
  }

  /// Opens the saved notes. Returns false when they exist but could not be read; the stored
  /// copy is then left alone (see [_notesUnreadable]) and the caller must not rebuild the list.
  Future<bool> _loadNotes() async {
    final preferences = await SharedPreferences.getInstance();
    final String? storedNotes;
    try {
      storedNotes = await _readSecret(preferences, _notesKey);
    } catch (error) {
      // Never delete what could not be read: the data is still there.
      _notesUnreadable = true;
      _setStatus(
        'Saved notes could not be opened ($error). They have not been deleted.',
      );
      return false;
    }
    _notesUnreadable = false;
    if (storedNotes == null || !mounted) return true;
    try {
      final decoded = jsonDecode(storedNotes) as List<dynamic>;
      var changed = false;
      final notes = decoded.whereType<Map<String, dynamic>>().map((json) {
        var note = CircuitNote.fromJson(json);
        // Older builds could persist Gemini's JSON envelope directly as the
        // transcript. Repair those notes on load so they are readable without
        // forcing the user to transcribe them again.
        final transcript = note.transcript;
        if (transcript != null) {
          final parsed = parseGeminiTranscriptionPayload(transcript);
          if (parsed != null) {
            changed = true;
            note = CircuitNote(
              id: note.id,
              createdAt: note.createdAt,
              status: note.status == 'Transcription ready'
                  ? note.status
                  : 'Transcription ready',
              audioPath: note.audioPath,
              transcript: parsed['transcript'] as String,
              title: (parsed['title'] as String?)?.trim(),
              category: (parsed['category'] as String?)?.trim(),
              boardId: note.boardId,
            );
          }
        }
        // A process restart means no transfer can still be running. Make an
        // old persisted progress message explicitly retryable.
        if (note.status.startsWith('Sync started') ||
            note.status.startsWith('Sync in progress') ||
            note.status.startsWith('Recording saved on Circuit')) {
          changed = true;
          return note.copyWith(status: 'Sync interrupted. Tap Sync to retry.');
        }
        // Identification cannot still be running after a restart.
        if (note.isSong &&
            (note.song?.busy ?? false) &&
            note.audioPath != null) {
          changed = true;
          return note.copyWith(
            song: note.song!.withState(
              'failed',
              error: 'Identification was interrupted. Try again.',
            ),
          );
        }
        return note;
      }).toList();
      setState(() {
        _notes = notes;
      });
      unawaited(_sendHomeStatus());
      if (changed) {
        await _writeSecret(
          preferences,
          _notesKey,
          jsonEncode(notes.map((item) => item.toJson()).toList()),
        );
      }
      return true;
    } catch (error) {
      // Leave the stored notes untouched so nothing is lost; they can be recovered.
      _notesUnreadable = true;
      debugPrint('Short-Circuit: saved notes could not be read: $error');
      _setStatus('Saved notes could not be read. They have not been deleted.');
      return false;
    }
  }

  /// Opens the saved notes at start. A failed read is tried again a few times, because the
  /// keystore is sometimes not ready for a moment right after an update; audio files are only
  /// matched to notes once the notes are open.
  Future<void> _openNotesAtStart() async {
    for (final wait in const [0, 2, 5, 12]) {
      if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
      if (!mounted) return;
      if (await _loadNotes()) {
        _reconcileSyncedNotes();
        _listenForPhoneRecording();
        return;
      }
    }
  }

  Future<String> _addPendingNote(
    String status, {
    DateTime? createdAt,
    int? boardId,
    bool song = false,
  }) async {
    final note = CircuitNote(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: createdAt ?? DateTime.now(),
      status: status,
      boardId: boardId,
      kind: song ? 'song' : 'voice',
      song: song ? const SongResult() : null,
    );
    final notes = [note, ..._notes];
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
    return note.id;
  }

  Future<void> _setNoteStatus(
    String id,
    String status, {
    String? audioPath,
  }) async {
    final notes = _notes
        .map(
          (note) => note.id == id
              ? note.copyWith(status: status, audioPath: audioPath)
              : note,
        )
        .toList();
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
  }

  Future<void> _setNoteTranscript(
    String id,
    GeminiTranscription transcription,
  ) async {
    final model = await const GeminiClient().model();
    final text = Moments.numberMarkers(transcription.transcript);
    final notes = _notes
        .map(
          (note) => note.id == id
              ? note.copyWith(
                  transcriptRuns: [
                    ...note.transcriptRuns,
                    TranscriptRun(model: model, text: text, at: DateTime.now()),
                  ].reversed.take(8).toList().reversed.toList(),
                  transcriptEdited: false,
                  reviewStale: false,
                  status: _aiConnected
                      ? 'Transcribed. Analysing…'
                      : 'Transcribed. Add an AI service for smart review.',
                  // [[MOMENT]] markers from the model become [Moment 1], [Moment 2]... across the whole note
                  transcript: text,
                  title: note.titleEdited ? note.title : transcription.title,
                  category: transcription.category,
                  isCall: transcription.isCall,
                  enrichmentStatus: 'pending',
                )
              : note,
        )
        .toList();
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
  }

  /// With [asSpeech], a clip wrongly taken for a song is turned back into a
  /// voice note and transcribed without the music check.
  Future<GeminiTranscription?> _transcribeNote(
    String id, {
    bool asSpeech = false,
  }) async {
    if (_transcribingNoteId != null) return null;
    final note = _notes.where((item) => item.id == id).firstOrNull;
    if ((note?.audioFiles.length ?? 0) > 1) return _transcribeLongNote(id);
    final path = note?.audioPath;
    if (path == null || ((note?.isSong ?? false) && !asSpeech)) return null;
    if (asSpeech && (note?.isSong ?? false)) {
      await _updateNote(id, (n) => n.copyWith(kind: 'voice', clearSong: true));
    }
    setState(() => _transcribingNoteId = id);
    await _setNoteStatus(id, 'Transcribing with Gemini…');
    final timer = Stopwatch()..start();
    try {
      final audio = await readNoteAudio(path);
      final moments = _useMoments
          ? await Moments.forNoteParts(note!, 0)
          : const <int>[];
      final transcription = await _gemini.transcribeWav(
        audio,
        detectMusic: !asSpeech,
        momentsMs: moments,
      );
      Telemetry.event('transcription_done', {
        'ok': true,
        'seconds': timer.elapsed.inSeconds,
        'audio_mb': Telemetry.megabytes(audio.length),
      });
      if (transcription.isMusic) {
        // Not a spoken note: keep the clip, drop the transcript, and look it up.
        await _updateNote(
          id,
          (n) => n.copyWith(
            kind: 'song',
            status: 'Sounds like music. Identifying…',
            song: const SongResult(),
          ),
        );
        unawaited(_identifySongNote(id));
        return transcription;
      }
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
      });
      Telemetry.nonFatal('transcription', error, stack);
      final message = error.toString().replaceFirst('Exception: ', '');
      final noSpeech =
          message.toLowerCase().contains('no speech') ||
          message.toLowerCase().contains('no transcription');
      final status = noSpeech
          ? 'No speech detected. Audio kept for review.'
          : 'Transcription error: $message';
      await _setNoteStatus(id, status);
      _setStatus(noSpeech ? status : 'Transcription failed: $message');
      return null;
    } finally {
      if (mounted) setState(() => _transcribingNoteId = null);
    }
  }

  /// Tries again, in the background, for notes whose AI review failed or was
  /// waiting for the service to be set up. Back-off: 1, 2, 4, 8, 16 minutes, then
  /// it stops and leaves the manual "Retry AI review" button.
  void _retryEnrichmentIfDue() {
    if (!shouldEnrichAutomatically(
      aiConnected: _aiConnected,
      autoEnrich: _autoEnrich,
    )) {
      return;
    }
    if (_notes.any((note) => note.enrichmentStatus == 'enriching')) return;
    final now = DateTime.now();
    for (final note in _notes) {
      if ((note.transcript ?? '').trim().isEmpty) continue;
      if (note.enrichmentStatus != 'failed' &&
          note.enrichmentStatus != 'pending')
        continue;
      final attempts = _enrichAttempts[note.id] ?? 0;
      if (attempts >= 5) continue;
      final last = _enrichLastAttempt[note.id];
      final wait = Duration(
        minutes: attempts == 0 && note.enrichmentStatus == 'pending'
            ? 0
            : 1 << attempts,
      );
      if (last != null && now.difference(last) < wait) continue;
      unawaited(_enrichNote(note.id));
      return; // one at a time
    }
  }

  Future<void> _enrichNote(String id) async {
    final note = _notes.where((item) => item.id == id).firstOrNull;
    final transcript = note?.transcript;
    if (transcript == null || transcript.trim().isEmpty) return;
    _enrichLastAttempt[id] = DateTime.now();
    await _updateNote(
      id,
      (item) => item.copyWith(
        status: 'Transcribed. Analysing…',
        enrichmentStatus: 'enriching',
      ),
    );
    final reviewModel = await const GeminiClient().model();
    try {
      final enrichment = await _ai.enrich(
        transcript,
        highlightMoments: _useMoments,
        recordedAt: note?.createdAt,
      );
      _enrichAttempts.remove(id);
      await _updateNote(id, (item) {
        // Running the review again must not undo decisions already made: keep
        // approved and dismissed suggestions, and only add ones not seen before.
        final decided = item.actionSuggestions
            .where((old) => old.state != 'pending')
            .toList();
        final fresh = enrichment.actions.where(
          (action) => !decided.any(
            (old) =>
                old.type == action.type &&
                old.title.trim().toLowerCase() ==
                    action.title.trim().toLowerCase(),
          ),
        );
        final merged = [...decided, ...fresh];
        return item.copyWith(
          status: merged.any((a) => a.state == 'pending')
              ? 'Ready for review'
              : 'Transcription ready',
          title: item.titleEdited ? item.title : enrichment.title,
          category: enrichment.category,
          categories: enrichment.categories,
          tags: enrichment.tags,
          summary: enrichment.summary,
          englishTranslation: enrichment.englishTranslation,
          language: enrichment.language,
          enrichmentStatus: 'ready',
          reviewStale: false,
          reviewModel: reviewModel,
          actionSuggestions: merged,
        );
      });
    } catch (error) {
      _enrichAttempts[id] = (_enrichAttempts[id] ?? 0) + 1;
      await _updateNote(
        id,
        (item) => item.copyWith(
          status: 'Transcribed. AI review needs retry.',
          enrichmentStatus: 'failed',
        ),
      );
      _setStatus(
        'AI review failed: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  Future<void> _updateNote(
    String id,
    CircuitNote Function(CircuitNote note) update,
  ) async {
    final notes = _notes
        .map((note) => note.id == id ? update(note) : note)
        .toList();
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
  }

  void _onScanResults(List<ScanResult> results) {
    var changed = false;
    for (final result in results) {
      final name = result.advertisementData.advName;
      if (name == _circuitName || result.device.platformName == _circuitName) {
        _circuits[result.device.remoteId.str] = result;
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {});
    }
  }

  /// A line in the phone's private Bluetooth log (read back with the test command `btlog`).
  void _btLog(String line) {
    unawaited(
      _relayChannel
          .invokeMethod<void>('btLog', {'line': line})
          .catchError((Object _) {}),
    );
  }

  Future<void> _restoreLastCircuit() async {
    final preferences = await SharedPreferences.getInstance();
    final deviceId = preferences.getString(_savedCircuitIdKey);
    if (deviceId == null || !mounted) return;
    final savedDevice = BluetoothDevice.fromId(deviceId);
    if (await savedDevice.bondState.first != BluetoothBondState.bonded) {
      _btLog(
        'start-up: saved Circuit is not bonded on this phone -> Repair pairing',
      );
      // Keep the saved Circuit: only the user's "Repair pairing" starts pairing.
      if (mounted) {
        setState(() {
          _savedCircuitId = deviceId;
          _needsPairingRepair = true;
          _status =
              'Circuit needs repair. Tap Repair pairing to pair it again.';
        });
      }
      return;
    }
    final relayStatus = await _relayChannel.invokeMethod<String>('status');
    if (relayStatus != null && relayStatus != 'Stopped') {
      setState(() {
        _savedCircuitId = deviceId;
        _relayActive = true;
        _status = relayStatus;
      });
      return;
    }
    setState(() {
      _savedCircuitId = deviceId;
      _status = 'Reconnecting to your saved Circuit…';
    });
    await _connect(savedDevice, savedReconnect: true);
  }

  Future<void> _scan() async {
    final permissionGranted = await _requestBluetoothPermissions();
    if (!permissionGranted) {
      _setStatus('Nearby Devices permission is needed to scan for Circuit.');
      return;
    }
    // adapterStateNow begins as `unknown` until FlutterBluePlus has queried
    // Android. Await the stream's first value so an already-on adapter is not
    // incorrectly shown as off on the first scan attempt.
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _setStatus('Turn on Bluetooth, then try again.');
      return;
    }
    setState(() {
      _circuits.clear();
      _scanning = true;
      _status = 'Scanning for Circuit…';
    });
    try {
      await FlutterBluePlus.startScan(
        withNames: const [_circuitName],
        timeout: const Duration(seconds: 10),
      );
    } catch (error) {
      _setStatus('Scan failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          if (_circuits.isEmpty && _status == 'Scanning for Circuit…') {
            _status = 'No Circuit found. Keep it powered and nearby, then scan again.';
          }
        });
      }
    }
  }

  Future<bool> _requestBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    await Permission.notification.request();
    return statuses.values.every((status) => status.isGranted);
  }

  Future<void> _connect(
    BluetoothDevice device, {
    bool savedReconnect = false,
    bool userRequestedPairing = false,
  }) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting to Circuit…';
    });
    try {
      await FlutterBluePlus.stopScan();
      var isBonded = await device.bondState.first == BluetoothBondState.bonded;
      if (shouldReplaceCircuitPairing(
        isBonded: isBonded,
        userRequestedPairing: userRequestedPairing,
      )) {
        _setStatus('Replacing the old pairing…');
        _btLog('connect: replacing the old pairing (removing the phone bond)');
        await _removeAndroidPairing(device);
        isBonded = false;
      }
      if (!isBonded && !userRequestedPairing) {
        debugPrint('Short-Circuit: not bonded; waiting for Repair pairing');
        _btLog('connect: not bonded on this phone -> Repair pairing');
        if (mounted) {
          setState(() {
            _needsPairingRepair = true;
            _status =
                'Circuit needs repair. Tap Repair pairing to pair it again.';
          });
        }
        return;
      }
      // Connect first: flutter_blue_plus can only pair a device that is connected, and
      // createBond on a disconnected one fails at once with "device is not connected".
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      if (shouldStartCircuitPairing(
        isBonded: isBonded,
        userRequestedPairing: userRequestedPairing,
      )) {
        _setStatus(
          'Enter Circuit’s six-digit code in the Android pairing prompt…',
        );
        // Waits (up to 90 s) until Android reports the pairing finished.
        await device.createBond(timeout: 90);
      }
      final preferences = await SharedPreferences.getInstance();
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _device = null;
            _textCharacteristic = null;
            _relayCharacteristic = null;
            _status = 'Circuit disconnected.';
          });
        }
      });

      final services = await device.discoverServices();
      final service = services
          .where((item) => item.uuid == _textServiceId)
          .firstOrNull;
      final characteristic = service?.characteristics
          .where((item) => item.uuid == _textCharacteristicId)
          .firstOrNull;
      if (characteristic == null) {
        await device.disconnect();
        throw StateError('Circuit text service was not found.');
      }
      await device.requestMtu(185);
      final relay = service?.characteristics
          .where((item) => item.uuid == _relayCharacteristicId)
          .firstOrNull;
      if (relay != null) {
        await relay.setNotifyValue(true);
        _relaySubscription?.cancel();
        _relaySubscription = relay.lastValueStream.listen(_onRelayMessage);
      }
      if (!mounted) return;
      setState(() {
        _device = device;
        _textCharacteristic = characteristic;
        _relayCharacteristic = relay;
        _needsPairingRepair = false;
        _status = 'Connected. Send text to the e-ink screen.';
      });
      await preferences.setString(_savedCircuitIdKey, device.remoteId.str);
      _savedCircuitId = device.remoteId.str;
      await _startPhoneRelay();
    } catch (error) {
      _setStatus(
        savedReconnect
            ? 'Your saved Circuit is not nearby. Tap Scan only if you need to find it again.'
            : 'Connection failed: $error',
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Removes Android's pairing record for this Circuit. Nothing on the board or in the
  /// notes changes; the next pairing makes a new record.
  Future<void> _removeAndroidPairing(BluetoothDevice device) async {
    try {
      if (await device.bondState.first == BluetoothBondState.bonded) {
        await device.removeBond();
      }
    } catch (error) {
      debugPrint('Short-Circuit: could not clear the old pairing: $error');
    }
  }

  /// The user's choice to pair again. Only Android's own pairing record is replaced:
  /// notes, keys and settings on the phone and the board are not touched.
  Future<void> _repairPairing() async {
    _btLog('Repair pairing tapped');
    final deviceId = _savedCircuitId;
    if (deviceId == null) {
      _setStatus('Scan for Circuit first.');
      return;
    }
    final device = BluetoothDevice.fromId(deviceId);
    await _removeAndroidPairing(device);
    await _connect(device, savedReconnect: true, userRequestedPairing: true);
  }

  Future<void> _provisionWifi() async {
    final characteristic = _textCharacteristic;
    final ssid = _wifiSsidController.text.trim();
    final password = _wifiPasswordController.text;
    if ((characteristic == null && !_relayActive) || ssid.isEmpty) {
      _setStatus('Connect to Circuit and enter a Wi-Fi name first.');
      return;
    }
    if (ssid.contains('\n') || password.contains('\n')) {
      _setStatus('Wi-Fi name and password cannot contain a new line.');
      return;
    }
    final command = '@wifi\n$ssid\n$password';
    if (utf8.encode(command).length > 160) {
      _setStatus('Wi-Fi details are too long for Circuit.');
      return;
    }
    setState(() {
      _provisioningWifi = true;
      _wifiState = 'connecting';
      _wifiSsid = ssid;
      _wifiDetail = '';
      _wifiConnectingSince = DateTime.now();
    });
    try {
      await _writeCircuit(command);
      _wifiPasswordController.clear();
      _setStatus('Wi-Fi details sent. Watch Circuit\'s Wi-Fi status above.');
    } catch (error) {
      _setStatus('Wi-Fi setup failed: $error');
      if (mounted) {
        setState(() {
          _wifiState = 'failed';
          _wifiDetail = 'Could not send the details to Circuit';
        });
      }
    } finally {
      if (mounted) setState(() => _provisioningWifi = false);
    }
  }

  Future<void> _scanWifi() async {
    final characteristic = _textCharacteristic;
    if ((characteristic == null && !_relayActive) ||
        (_relayCharacteristic == null && !_relayActive)) {
      _setStatus('Update Circuit first, then reconnect to scan Wi-Fi.');
      return;
    }
    setState(() {
      _scanningWifi = true;
      _wifiNetworks = [];
      _status = 'Circuit is scanning nearby Wi-Fi…';
    });
    try {
      await _writeCircuit('@wifi-scan');
      if (_relayActive) {
        await Future<void>.delayed(const Duration(seconds: 3));
        final rawNetworks =
            await _relayChannel.invokeMethod<List<dynamic>>('wifiNetworks') ??
            [];
        _setWifiNetworks(rawNetworks.whereType<String>().toList());
      }
    } catch (error) {
      _setStatus('Wi-Fi scan failed: $error');
      if (mounted) setState(() => _scanningWifi = false);
    }
  }

  /// The board's notes key arrives as "@sec-key\n1\n<key id, hex>\n<key, base64>", over
  /// the encrypted, bonded link only. Returns true if the message was a security one.
  bool _handleSecurityMessage(String message) {
    if (message.startsWith('@sec-none')) {
      _setStatus('Circuit has no notes key yet. Pair it first.');
      return true;
    }
    if (!message.startsWith('@sec-key\n')) return false;
    final parts = message.split('\n');
    final id = parts.length > 2 ? int.tryParse(parts[2], radix: 16) : null;
    Uint8List? key;
    try {
      key = parts.length > 3 ? base64Decode(parts[3].trim()) : null;
    } catch (_) {}
    if (parts.length > 3 &&
        parts[1] == '1' &&
        id != null &&
        id != 0 &&
        key != null &&
        key.length == 32) {
      unawaited(
        NoteKeys.save(id, key).then((_) {
          if (mounted) setState(() => _noteKeyId = id);
          _setStatus('Notes are encrypted. This phone has the key.');
        }),
      );
    }
    return true;
  }

  /// Asks Circuit for its notes key. Cheap, and safe to repeat: only an encrypted,
  /// bonded link can make Circuit answer.
  Future<void> _requestNoteKey() async {
    final last = _lastKeyRequestAt;
    final now = DateTime.now();
    if (last != null &&
        now.difference(last) < const Duration(minutes: 10) &&
        _noteKeyId != null) {
      return;
    }
    _lastKeyRequestAt = now;
    try {
      await _writeCircuit('@sec-hello\n1');
    } catch (_) {}
  }

  void _onRelayMessage(List<int> value) {
    final message = utf8.decode(value, allowMalformed: true);
    if (_handleSecurityMessage(message)) return;
    if (message.startsWith('@wifi-status\n')) {
      _applyWifiStatus(message);
      return;
    }
    if (message.startsWith('@audio-status\n')) {
      _handleAudioStatus(message.substring('@audio-status\n'.length));
      return;
    }
    if (!message.startsWith('@wifi-list')) return;
    final networks =
        message
            .split('\n')
            .skip(1)
            .map((ssid) => ssid.trim())
            .where((ssid) => ssid.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    _setWifiNetworks(networks);
  }

  void _handleAudioStatus(String status) {
    if (_handleSecurityMessage(status)) return;
    if (status.startsWith('@wifi-status\n')) {
      _applyWifiStatus(status);
      return;
    }
    if (status.startsWith('@sync-status\n')) {
      _applySyncStatus(status);
      return;
    }
    if (!mounted) return;
    final noteProgress = RegExp(r'^Sync note #(\d+): (\d+)% \((\d+) of (\d+)\)')
        .firstMatch(status);
    if (noteProgress != null) {
      setState(() {
        _noteProgress[int.parse(noteProgress.group(1)!)] = int.parse(
          noteProgress.group(2)!,
        );
        _syncNoteIndex = int.parse(noteProgress.group(3)!);
        _syncNoteCount = int.parse(noteProgress.group(4)!);
        _syncActive = true;
        _lastSyncActivity = DateTime.now();
      });
      return;
    }
    if (status.startsWith('Sync started') ||
        status.startsWith('Sync complete: all notes saved') ||
        status.startsWith('Sync complete: no new notes') ||
        status.startsWith('Sync failed') ||
        status.startsWith('Sync needs Wi-Fi')) {
      _noteProgress.clear();
      _syncNoteIndex = 0;
      _syncNoteCount = 0;
    }
    if (_applyCircuitPlaybackStatus(status)) return;
    if (status == _lastAudioStatus) return;
    _lastAudioStatus = status;
    if (status.startsWith('Recording started') && !_recordingAudio) {
      // Started with Circuit's button rather than from the app.
      setState(() {
        _recordingAudio = true;
        _recordingStartedAt = DateTime.now();
      });
    }
    setState(() {
      _status = status;
      if (status.startsWith('Recording saved') ||
          status.startsWith('Recording stopped') ||
          status.startsWith('Recording failed')) {
        _recordingAudio = false;
        if (status.startsWith('Recording failed')) _songClipArmed = false;
      }
      if (status.startsWith('Audio is busy')) {
        // Circuit refused the request, so no song clip is coming.
        _songClipArmed = false;
      }
    });
    if (status.startsWith('Recording saved') ||
        status.startsWith('Recording stopped')) {
      final boardId = int.tryParse(
        RegExp(r'#(\d+)').firstMatch(status)?.group(1) ?? '',
      );
      // Circuit's last status is replayed whenever the app screen reopens, so
      // the same recording can be reported again. Its number says it is known.
      if (boardId != null && _knownBoardNote(boardId, DateTime.now())) return;
      final isSong = _songClipArmed;
      _songClipArmed = false;
      _addPendingNote(
        'Recording saved on Circuit. Hold Circuit\'s button for 2 seconds to bring it to this phone (same Wi-Fi).',
        boardId: boardId,
        song: isSong,
      );
      return;
    }
    if (status.startsWith('Force sync requested')) {
      final pendingNoteId = _pendingSyncNoteId();
      if (pendingNoteId == null) return;
      setState(() {
        _syncingNoteId = pendingNoteId;
        _syncProgress = 0;
        _audioBusy = true;
      });
      unawaited(_setNoteStatus(pendingNoteId, 'Sync queued…'));
      return;
    }
    if (status.startsWith('Sync started') ||
        status.startsWith('Sync in progress')) {
      setState(() {
        _syncActive = true;
        _syncError = null;
        _lastSyncActivity = DateTime.now();
      });
    }
    if (status.startsWith('Sync failed') ||
        status.startsWith('Sync interrupted')) {
      _failSync(
        status.replaceFirst(RegExp(r'^Sync (failed|interrupted):?\s*'), ''),
      );
      return;
    }
    if ((_syncingNoteId == null) &&
        (status.startsWith('Sync started') ||
            status.startsWith('Sync in progress'))) {
      final pendingNoteId = _pendingSyncNoteId();
      if (pendingNoteId != null) {
        _syncingNoteId = pendingNoteId;
        _syncProgress = 0;
        _audioBusy = true;
      }
    }
    if (status.startsWith('Sync complete') && status.contains('|')) {
      // "Sync complete: ready on phone|<path>|<epoch seconds>": one note arrived.
      final fields = status.split('|');
      final path = fields.length > 1 ? fields[1] : null;
      final epoch = fields.length > 2 ? int.tryParse(fields[2]) : null;
      final syncingId = _syncingNoteId;
      _syncingNoteId = null;
      _lastSyncActivity = DateTime.now();
      _lastSyncOk = DateTime.now();
      unawaited(_attachSyncedFile(path, epoch, preferNoteId: syncingId));
      return;
    }
    if (status.startsWith('Note deleted #')) {
      final id = int.tryParse(
        RegExp(r'#(\d+)').firstMatch(status)?.group(1) ?? '',
      );
      if (id != null && _pendingBoardDeletes.remove(id)) {
        unawaited(_saveBoardDeletes());
        _lastBoardDeleteSent = null;
        _processBoardDeletes(); // next one, if any
      }
      return;
    }
    if (status.startsWith('Sync: nothing waiting for #')) {
      // Asked for one note and Circuit has nothing waiting for it (it may have synced already).
      // Unlike "no new notes" this says nothing about the other notes, so nothing is pruned.
      final noteId = _syncingNoteId;
      setState(() {
        _audioBusy = false;
        _syncActive = false;
        _syncingNoteId = null;
        _syncProgress = null;
      });
      if (noteId != null) {
        unawaited(
          _setNoteStatus(noteId, 'Circuit has nothing waiting for this note.'),
        );
      }
      return;
    }
    if (status.startsWith('Sync: no new notes')) {
      // Circuit has nothing waiting.
      setState(() {
        _audioBusy = false;
        _syncingNoteId = null;
        _syncProgress = null;
      });
      unawaited(_pruneLostNotes());
      return;
    }
    if (status.startsWith('Sync complete: all notes saved') ||
        status.startsWith('Sync complete: no new notes')) {
      setState(() {
        _syncActive = false;
        _syncError = null;
        _lastSyncOk = DateTime.now();
        _audioBusy = false;
        _syncingNoteId = null;
        _syncProgress = null;
      });
      unawaited(_pruneLostNotes());
      return;
    }
    if (status.startsWith('Sync needs Wi-Fi')) {
      final waitingNoteId = _syncingNoteId ?? _pendingSyncNoteId();
      setState(() {
        _syncActive = false;
        _syncError =
            'Circuit and this phone need to be on the same Wi-Fi to sync.';
        _audioBusy = false;
        _syncingNoteId = null;
        _syncProgress = null;
      });
      if (waitingNoteId != null) {
        unawaited(_setNoteStatus(waitingNoteId, 'Waiting for Wi-Fi to sync'));
      }
      return;
    }
    if (status.startsWith('Sync started') ||
        status.startsWith('Sync in progress')) {
      // The figure is kept whatever the sync is for: after the first note of several has arrived
      // no note is "being synced" any more, but the sync is still going and still has a progress.
      final match = RegExp(r'(\d+)%').firstMatch(status);
      if (match != null) {
        setState(() => _syncProgress = int.parse(match.group(1)!));
      } else if (_syncProgress == null) {
        setState(() => _syncProgress = 0);
      }
      // Progress shows in the banner; rewriting the saved note on every tick is
      // slow and used to flood Circuit with status updates.
      final syncingNoteId = _syncingNoteId;
      if (syncingNoteId != null && status.startsWith('Sync started')) {
        _setNoteStatus(syncingNoteId, status.replaceAll('\n', ' • '));
      }
    }
  }

  // ---- sync health ---------------------------------------------------------

  void _failSync(String reason) {
    final noteId = _syncingNoteId;
    setState(() {
      _syncActive = false;
      _syncError = reason.isEmpty ? 'The sync did not finish.' : reason;
      _audioBusy = false;
      _syncingNoteId = null;
      _syncProgress = null;
    });
    if (noteId != null)
      unawaited(_setNoteStatus(noteId, 'Sync failed: $reason'));
  }

  /// "@sync-status\nwaiting=N\nreset=R\nuptime=S" from Circuit.
  void _applySyncStatus(String message) {
    if (!mounted) return;
    _applyCircuitPlaybackSnapshot(message);
    int? field(String name) => int.tryParse(
      RegExp('$name=(-?\\d+)').firstMatch(message)?.group(1) ?? '',
    );
    final waiting = field('waiting');
    final reset = field('reset');
    final uptime = field('uptime');
    final battery = field('bat');
    setState(() {
      if (battery != null) _boardBattery = battery >= 0 ? battery : null;
      _boardFirmware = FirmwareImage.runningFrom(message) ?? _boardFirmware;
      // These two arrive together in one packet; an empty one means "none" (no earlier firmware, no card).
      if (message.contains('\nprev=')) {
        _boardPrevious = BoardReport.previousFrom(message);
      }
      if (message.contains('\nsd=')) {
        _boardStorage = BoardReport.storageFrom(message);
      }
      if (waiting != null) {
        if (waiting > 0 && (_boardWaiting ?? 0) == 0)
          _waitingSince = DateTime.now();
        if (waiting == 0) {
          _waitingSince = null;
          if (!_syncActive) _syncError = null; // everything made it across
          unawaited(_pruneLostNotes());
        }
        _boardWaiting = waiting;
      }
      if (reset != null) _boardReset = reset;
      if (uptime != null) _boardUptime = uptime;
    });
    const abnormal = {4, 5, 6, 7, 9, 15};
    final code = _boardReset;
    if (!_resetNoticeShown &&
        code != null &&
        abnormal.contains(code) &&
        _boardUptime < 900) {
      _resetNoticeShown = true;
      _toast('Circuit restarted unexpectedly (${_resetReasonText(code)})');
    }
  }

  /// Called every few seconds: turns silence into a visible failure.
  void _checkSyncHealth() {
    final now = DateTime.now();
    if (_syncActive &&
        _lastSyncActivity != null &&
        now.difference(_lastSyncActivity!) > const Duration(seconds: 45)) {
      _failSync('No progress from Circuit for 45 seconds.');
      return;
    }
    final waiting = _boardWaiting ?? 0;
    if (waiting > 0 &&
        !_syncActive &&
        _syncError == null &&
        _waitingSince != null &&
        now.difference(_waitingSince!) > const Duration(minutes: 3)) {
      setState(() {
        _syncError =
            '$waiting note${waiting == 1 ? ' is' : 's are'} waiting on Circuit and ${waiting == 1 ? 'has' : 'have'} not synced.';
      });
    }
  }

  /// Pull down on Notes or Circuit: ask Circuit whether anything is waiting (and sync it), or try to
  /// reach it when it is not connected. Says what happened, so the pull never feels like nothing.
  Future<void> _pullRefresh() async {
    if (!_circuitAvailable) {
      if (_savedCircuitId != null && !_connecting && !_needsPairingRepair) {
        unawaited(
          _connect(
            BluetoothDevice.fromId(_savedCircuitId!),
            savedReconnect: true,
          ),
        );
        _toast('Looking for Circuit…');
      } else {
        _toast('Circuit is not connected');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      return;
    }
    if (_syncActive) return;
    try {
      await _writeCircuit('@audio-sync');
    } catch (error) {
      _toast('Could not reach Circuit');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (!mounted) return;
    if (_syncActive || _syncingNoteId != null) {
      _toast('Syncing new notes…');
    } else if ((_boardWaiting ?? 0) == 0) {
      _toast('Up to date. Nothing new on Circuit.');
    }
  }

  Future<void> _retrySync() async {
    setState(() {
      _syncError = null;
      _syncActive = false;
    });
    try {
      await _writeCircuit('@audio-sync');
      _toast('Asking Circuit to sync…');
    } catch (error) {
      _failSync('Could not reach Circuit: $error');
    }
  }

  String _resetReasonText(int code) => switch (code) {
    1 => 'power on',
    3 => 'software restart',
    4 => 'crash',
    5 || 6 || 7 => 'watchdog',
    9 || 15 => 'low power',
    11 => 'USB reset',
    _ => 'code $code',
  };

  /// Notes created when Circuit reported a recording, still waiting for audio.
  /// Circuit syncs oldest-first and the list is newest-first.
  Iterable<CircuitNote> _pendingNotes() => _notes.reversed.where(
    (note) =>
        note.audioPath == null &&
        (note.status.startsWith('Recording saved on Circuit') ||
            note.status.startsWith('Sync queued') ||
            note.status.startsWith('Sync started') ||
            note.status.startsWith('Sync in progress') ||
            note.status.startsWith('Sync interrupted') ||
            note.status.startsWith('Waiting for Wi-Fi') ||
            note.status.startsWith('Sync failed')),
  );

  String? _pendingSyncNoteId() => _pendingNotes().firstOrNull?.id;

  /// Circuit has confirmed it has nothing waiting, so a note that still has no
  /// audio after a few minutes can never receive any (for example one recorded
  /// before Circuit kept every note). Remove those instead of leaving a card
  /// that can never sync.
  Iterable<CircuitNote> _notesWithoutAudio(DateTime cutoff) => _notes.where(
    (note) =>
        note.audioPath == null &&
        !note.isText &&
        note.createdAt.isBefore(cutoff) &&
        // A long recording whose parts are still arriving has none of its audio in the note yet.
        !note.status.startsWith('Receiving') &&
        !note.status.startsWith('Waiting for part'),
  );

  /// Notes still to arrive from Circuit: what it says it holds, or the notes here still waiting for their
  /// audio, whichever is more. One number for every screen, so none says "synced" while another says "waiting".
  int get _waitingCount =>
      max(_boardWaiting ?? 0, _notesWithoutAudio(DateTime.now()).length);

  Future<void> _pruneLostNotes() async {
    // Only when Circuit itself says nothing at all is waiting. A sync of one note ends with the
    // same "saved" message, and the other notes are then still on the board.
    if (_boardWaiting != 0) return;
    // Two minutes is time enough for a sync that is on its way to start; after that nothing is coming.
    final cutoff = DateTime.now().subtract(const Duration(minutes: 2));
    final lost = _notesWithoutAudio(cutoff)
        .where(
          (note) =>
              note.createdAt.isBefore(cutoff) &&
              note.id != _syncingNoteId &&
              note.id != _transcribingNoteId,
        )
        .map((note) => note.id)
        .toList();
    debugPrint('Short-Circuit: pruning ${lost.length} note(s) without audio');
    if (lost.isEmpty) return;
    final notes = _notes.where((note) => !lost.contains(note.id)).toList();
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (!mounted) return;
    setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
    _toast(
      lost.length == 1
          ? 'Removed a note whose recording was lost'
          : 'Removed ${lost.length} notes whose recordings were lost',
    );
  }

  /// A synced file belongs to the oldest note still waiting for audio; if the
  /// recording happened while the app was closed there is none, so make one.
  /// True if a note for this Circuit recording already exists. Numbers restart
  /// if Circuit is reset, so only a note from the last ten minutes counts.
  bool _knownBoardNote(int boardId, DateTime around) => _notes.any(
    (note) =>
        note.boardId == boardId &&
        note.createdAt.difference(around).abs() <
            // A recording made of parts is dated by its first part, which can be hours earlier.
            (note.audioParts.isEmpty
                ? const Duration(minutes: 10)
                : const Duration(hours: 12)),
  );

  Future<void> _attachSyncedFile(
    String? path,
    int? epochSeconds, {
    String? preferNoteId,
  }) async {
    if (path == null || path.isEmpty) return;
    if (_notes.any((note) => note.audioPath == path)) return;
    // Match the recording to the pending note made when Circuit reported it,
    // using the time it was recorded. Taking the oldest pending note would hand
    // the audio to a stale note whose own recording no longer exists.
    String? noteId;
    // circuit-note-<epoch>-<number>.wav: the number names the exact recording.
    final boardId = int.tryParse(
      RegExp(r'circuit-note-\d+-(\d+)\.(?:wav|cnote)$')
              .firstMatch(path)
              ?.group(1) ??
          '',
    );
    if (boardId != null && _pendingBoardDeletes.contains(boardId)) {
      // Deleted in the app; Circuit's copy has not been removed yet. Do not let
      // it come back as a new note.
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }
    // One minute of a longer recording made on Circuit: collected into one note.
    final boardPart = await readBoardPart(path);
    if (boardPart != null &&
        await _attachBoardPart(path, epochSeconds, boardPart)) {
      return;
    }
    final recordedAt = epochSeconds != null && epochSeconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000)
        : null;
    final byBoardId = boardId == null
        ? null
        : _notes.where((n) {
            final near =
                recordedAt == null ||
                n.createdAt.difference(recordedAt).abs() <
                    const Duration(minutes: 10);
            return n.boardId == boardId && near;
          }).firstOrNull;
    if (byBoardId != null && byBoardId.audioPath != null) {
      // The same recording arrived twice (for example when an acknowledgement
      // was lost and Circuit offered it again). Keep one copy.
      try {
        final existing = File(byBoardId.audioPath!);
        final duplicate = File(path);
        if (path != byBoardId.audioPath &&
            await existing.exists() &&
            await existing.length() == await duplicate.length()) {
          await duplicate.delete();
        }
      } catch (_) {
        // Leaving a spare copy is harmless; it will be retried next time.
      }
      return;
    }
    // A note that already carries a different Circuit number is some other
    // recording; never hand this audio to it.
    bool sameRecording(CircuitNote n) =>
        boardId == null || n.boardId == null || n.boardId == boardId;
    final preferred = byBoardId != null && byBoardId.audioPath == null
        ? byBoardId
        : preferNoteId == null
        ? null
        : _notes
              .where(
                (n) =>
                    n.id == preferNoteId &&
                    n.audioPath == null &&
                    sameRecording(n),
              )
              .firstOrNull;
    if (preferred != null) {
      noteId = preferred.id;
    } else if (epochSeconds != null && epochSeconds > 0) {
      final recorded = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
      Duration? bestGap;
      for (final note in _pendingNotes().where(sameRecording)) {
        final gap = note.createdAt.difference(recorded).abs();
        if (gap < const Duration(minutes: 10) &&
            (bestGap == null || gap < bestGap)) {
          noteId = note.id;
          bestGap = gap;
        }
      }
    } else {
      noteId = _pendingNotes().where(sameRecording).firstOrNull?.id;
    }
    if (noteId == null) {
      noteId = await _addPendingNote(
        'Synced. Transcription starting…',
        createdAt: recordedAt,
        boardId: boardId,
      );
    }
    unawaited(() async {
      try {
        final bytes = await File(path).length();
        Telemetry.event('note_synced', {
          'size_mb': Telemetry.megabytes(bytes),
          'encrypted': path.endsWith('.cnote'),
        });
      } catch (_) {
        // A counter must never become an error report: the file may already be gone.
      }
    }());
    await _transcribeAfterSync(noteId, path);
  }

  /// Picks up notes the phone downloaded in the background while the app UI was
  /// not running.
  /// Earlier versions could give a recording to the wrong waiting note. The audio
  /// (and the transcript made from it) is what the note really is, so the note
  /// takes the number in its audio file's name; the recording it was mistaken for
  /// is then adopted as its own note.
  Future<void> _repairBoardIds() async {
    var changed = false;
    final repaired = _notes.map((note) {
      final path = note.audioPath;
      final fileId = path == null
          ? null
          : int.tryParse(
              RegExp(r'circuit-note-\d+-(\d+)\.(?:wav|cnote)$')
                      .firstMatch(path)
                      ?.group(1) ??
                  '',
            );
      if (fileId != null && note.boardId != fileId) {
        changed = true;
        return note.copyWith(boardId: fileId);
      }
      return note;
    }).toList();
    if (!changed) return;
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(repaired.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = repaired);
  }

  Future<void> _reconcileSyncedNotes() async {
    await _repairBoardIds();
    try {
      final files = await _relayChannel.invokeListMethod<String>('syncedNotes');
      for (final entry in files ?? const <String>[]) {
        final fields = entry.split('|');
        await _attachSyncedFile(
          fields.first,
          fields.length > 1 ? int.tryParse(fields[1]) : null,
        );
      }
    } catch (error) {
      // Reconciliation is best-effort; the next sync status retries it.
      debugPrint('Short-Circuit: reconcile failed: $error');
    }
  }

  Future<void> _transcribeAfterSync(String noteId, String? audioPath) async {
    if (_notes.where((n) => n.id == noteId).firstOrNull?.isSong ?? false) {
      await _setNoteStatus(
        noteId,
        'Synced. Identifying song…',
        audioPath: audioPath,
      );
      await _identifySongNote(noteId);
      return;
    }
    await _setNoteStatus(
      noteId,
      'Synced. Transcription starting…',
      audioPath: audioPath,
    );
    if (_autoTranscribe) {
      await _transcribeNote(noteId);
    } else {
      await _setNoteStatus(noteId, 'Synced. Ready to transcribe.');
    }
  }

  Future<void> _syncLatestRecording(String noteId) async {
    if (_audioBusy) return;
    if (mounted) {
      setState(() {
        _syncingNoteId = noteId;
        _syncProgress = 0;
        _audioBusy = true;
      });
    } else {
      _syncingNoteId = noteId;
      _syncProgress = 0;
      _audioBusy = true;
    }
    await _setNoteStatus(noteId, 'Sync queued…');
    _lastSyncActivity = DateTime.now();
    _syncActive = true;
    try {
      // Ask for just this note (all its parts) when Circuit gave it a number; an older board
      // ignores the number and sends everything waiting.
      final boardId = _boardIdOf(
        _notes.where((n) => n.id == noteId).firstOrNull,
      );
      await _writeCircuit(
        boardId == null ? '@audio-sync' : '@audio-sync\n$boardId',
      );
    } catch (error) {
      _audioBusy = false;
      _syncingNoteId = null;
      await _setNoteStatus(noteId, 'Sync failed: $error');
    }
  }

  Future<void> _playSyncedNote(String? path) async {
    if (path == null || path.isEmpty) {
      _setStatus('This note has not finished syncing yet.');
      return;
    }
    if (_phoneRecordingActive || _recordingAudio) {
      _toast('Stop recording first');
      return;
    }
    _playbackToken++; // a new request replaces any part-by-part playback in progress
    _sequencePlaying = false;
    final playedNote = _notes
        .where((note) => note.audioPath == path)
        .firstOrNull;
    final parts = playedNote?.audioFiles;
    final title = (playedNote?.title?.trim().isNotEmpty ?? false)
        ? playedNote!.title!
        : 'Voice note';
    if (parts != null && parts.length > 1) {
      await _playNoteParts(parts, title);
      return;
    }
    bool? started;
    try {
      final bytes = await File(path).readAsBytes();
      if (NoteCrypto.isEncrypted(bytes)) {
        // Opened in memory and played from there, so no plain audio file is written.
        started = await _relayChannel.invokeMethod<bool>('playWavBytes', {
          'bytes': await readNoteAudio(path),
        });
      } else {
        started = await _relayChannel.invokeMethod<bool>(
          'playSyncedRecording',
          {'path': path},
        );
      }
    } on NoteSecurityException catch (error) {
      _setStatus('$error');
      return;
    }
    if (started == true) _startNowPlaying(title);
    _setStatus(
      started == true
          ? 'Playing this voice note on your phone.'
          : 'Could not play this voice note.',
    );
  }

  /// Plays a note from [noteMs] after its start (a Moment), across its one-minute parts.
  Future<void> _playNoteFrom(String noteId, int noteMs) async {
    final note = _notes.where((item) => item.id == noteId).firstOrNull;
    final parts = note?.audioFiles ?? const <String>[];
    if (note == null || parts.isEmpty) {
      _setStatus('This note has not finished syncing yet.');
      return;
    }
    _playbackToken++;
    _sequencePlaying = false;
    final spot = await Moments.locate(parts, noteMs);
    final title = (note.title?.trim().isNotEmpty ?? false)
        ? note.title!
        : 'Voice note';
    await _playNoteParts(
      parts,
      title,
      firstPart: spot.part,
      startMs: spot.offsetMs,
    );
  }

  /// Circuit's number for a note: stored when it was recorded, or read from the
  /// downloaded file's name (circuit-note-<epoch>-<number>.wav).
  int? _boardIdOf(CircuitNote? note) {
    if (note == null) return null;
    if (note.boardId != null) return note.boardId;
    final path = note.audioPath;
    if (path == null) return null;
    return int.tryParse(
      RegExp(r'circuit-note-\d+-(\d+)\.(?:wav|cnote)$')
              .firstMatch(path)
              ?.group(1) ??
          '',
    );
  }

  Future<void> _saveBoardDeletes() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _boardDeletesKey,
      _pendingBoardDeletes.map((id) => '$id').toList(),
    );
  }

  /// Asks Circuit to delete one queued note. Circuit confirms with
  /// "Note deleted #N", which clears it from the queue; until then it is retried,
  /// so a delete made while Circuit is away still happens later.
  void _processBoardDeletes() {
    if (_pendingBoardDeletes.isEmpty || !_circuitAvailable) return;
    final last = _lastBoardDeleteSent;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastBoardDeleteSent = DateTime.now();
    _writeCircuit('@note-delete\n${_pendingBoardDeletes.first}')
        .catchError((Object _) {
          _lastBoardDeleteSent = null;
        });
  }

  Future<List<ChatMessage>> _loadNoteChat(String noteId) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = await _readSecret(preferences, 'note_chat_$noteId');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveNoteChat(String noteId, List<ChatMessage> messages) async {
    final preferences = await SharedPreferences.getInstance();
    if (messages.isEmpty) {
      await preferences.remove('note_chat_$noteId');
    } else {
      await _writeSecret(
        preferences,
        'note_chat_$noteId',
        jsonEncode(messages.map((m) => m.toJson()).toList()),
      );
    }
  }

  /// A group chat: the AI sees the group's notes as of now, so notes added or transcribed since
  /// the chat was opened are included.
  Future<String> _askAboutGroup(String groupId, List<ChatMessage> history) {
    final group = _groupById(groupId);
    if (group == null) throw Exception('This group no longer exists.');
    return _ai.chatAboutGroup(
      group.name,
      buildGroupContext(_notesOfGroup(group)),
      history,
    );
  }

  Future<String> _askAboutNote(String noteId, List<ChatMessage> history) {
    final note = _notes.where((n) => n.id == noteId).firstOrNull;
    if (note == null) throw Exception('This note no longer exists.');
    return _ai.chatAboutNote(note, history);
  }

  /// Saves a hand-edited title and transcript. The title is then protected from
  /// AI review; a changed transcript is flagged so the review can be re-run.
  Future<void> _editNote(String id, String title, String transcript) async {
    await _updateNote(id, (note) {
      final changed = transcript != (note.transcript ?? '');
      final latest = note.transcriptRuns.lastOrNull?.text;
      final reviewed = note.enrichmentStatus == 'ready';
      return note.copyWith(
        title: title,
        titleEdited: true,
        transcript: transcript,
        // Whether to review again is the person's call: an edit only says the review is out of date.
        transcriptEdited: latest != null ? transcript != latest : changed,
        reviewStale: changed && reviewed ? true : note.reviewStale,
      );
    });
  }

  /// Makes an earlier transcription the working transcript again.
  Future<void> _useTranscriptRun(String id, int index) async {
    await _updateNote(id, (note) {
      if (index < 0 || index >= note.transcriptRuns.length) return note;
      final run = note.transcriptRuns[index];
      final changed = run.text != (note.transcript ?? '');
      return note.copyWith(
        transcript: run.text,
        transcriptEdited: index != note.transcriptRuns.length - 1,
        reviewStale: changed && note.enrichmentStatus == 'ready'
            ? true
            : note.reviewStale,
      );
    });
  }

  Future<void> _deleteNote(String id, {bool phoneOnly = false}) async {
    final note = _notes.where((item) => item.id == id).firstOrNull;
    final boardId = _boardIdOf(note);
    // "Phone only" leaves Circuit's copy on its card: it is already marked synced there, so it
    // is not sent again unless the person asks for old notes to be re-sent.
    if (boardId != null && !phoneOnly) {
      _pendingBoardDeletes.add(boardId);
      // A recording made of parts is deleted on Circuit part by part.
      _pendingBoardDeletes.addAll(await _boardPartIds(note));
      unawaited(_saveBoardDeletes());
      _lastBoardDeleteSent = null;
      _processBoardDeletes();
    }
    final firstPart = note?.boardId;
    final arriving = firstPart == null
        ? const <String>[]
        : (await _arrivedBoardFiles(firstPart)).keys.toList();
    for (final path in {...?note?.audioFiles, ...arriving}) {
      try {
        await File(path).delete();
        await _boardPartFile(path)?.delete();
        await momentsFileFor(path)?.delete();
      } catch (_) {
        // The file may already have been removed.
      }
    }
    final notes = _notes.where((item) => item.id != id).toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('note_chat_$id');
    unawaited(_removeNoteFromGroups(id));
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
  }

  Future<void> _sendHomeStatus() async {
    if (_textCharacteristic == null && !_relayActive) return;
    final now = DateTime.now();
    const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final date =
        '${weekdays[now.weekday - 1]} ${now.day.toString().padLeft(2, '0')} ${months[now.month - 1]}';
    final (:pending, :synced) = boardNoteCounts(_notes);
    // Saving a note triggers this, and a sync saves one many times a second.
    // Each message makes Circuit redraw, so only send when the counts changed or
    // the periodic refresh is due.
    final counts = '$pending · $synced';
    // The background service sends the home screen too and needs the pending count,
    // which it can no longer read from the encrypted notes list.
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('circuit_pending_count', pending);
    unawaited(_requestNoteKey());
    final last = _lastHomeSentAt;
    if (counts == _lastHomeCounts &&
        last != null &&
        now.difference(last) < const Duration(seconds: 25)) {
      return;
    }
    _lastHomeCounts = counts;
    _lastHomeSentAt = now;
    try {
      // The epoch and UTC offset let Circuit set its own clock once and then
      // keep time without further updates.
      await _writeCircuit(
        '@home\n$time\n$date\n$pending · $synced\n'
        '${now.millisecondsSinceEpoch ~/ 1000}\n${now.timeZoneOffset.inMinutes}',
      );
    } catch (_) {
      // The relay may be between reconnect attempts; the next 30-second
      // update will refresh the display once it is available again.
    }
  }

  Future<ReminderDraft?> _extractReminder(
    String transcript,
    DateTime recordedAt,
  ) async {
    try {
      return await _ai.extractReminder(transcript, recordedAt: recordedAt);
    } catch (error) {
      _setStatus('Reminder extraction failed: $error');
      return null;
    }
  }

  Future<void> _clearAudioOnce() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool('audio_reset_v2') == true) return;
    final cleared = await _relayChannel.invokeMethod<bool>('clearAudio');
    if (cleared != true) return;
    await preferences.remove(_notesKey);
    await preferences.setBool('audio_reset_v2', true);
    if (mounted) {
      setState(() {
        _notes = [];
        _syncingNoteId = null;
        _syncProgress = null;
        _audioBusy = false;
      });
    }
  }

  void _applyWifiStatus(String message) {
    final status = parseWifiStatus(message);
    if (status == null || !mounted) return;
    setState(() {
      _wifiState = status.state;
      _wifiSsid = status.ssid;
      _wifiDetail = status.detail;
      if (status.mac.isNotEmpty) _wifiMac = status.mac;
      if (status.state == 'connecting') {
        _wifiConnectingSince ??= DateTime.now();
      } else {
        _wifiConnectingSince = null;
      }
    });
  }

  /// Puts [value] on the clipboard and says so.
  Future<void> _copyValue(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _setStatus('$label copied.');
  }

  Future<void> _requestWifiStatus() async {
    if (_textCharacteristic == null && !_relayActive) return;
    try {
      await _writeCircuit('@wifi-status');
    } catch (_) {
      // Status polling is best-effort; Circuit also pushes changes itself.
    }
  }

  Future<void> _forgetWifi() async {
    try {
      await _writeCircuit('@wifi-forget');
      if (mounted) {
        setState(() {
          _wifiState = 'none';
          _wifiSsid = '';
          _wifiDetail = '';
        });
      }
    } catch (error) {
      _setStatus('Could not forget the network: $error');
    }
  }

  void _setWifiNetworks(List<String> networks) {
    if (!mounted) return;
    setState(() {
      _wifiNetworks = networks;
      _scanningWifi = false;
      _status = networks.isEmpty
          ? 'No visible Wi-Fi networks found. Use Hidden network for a manual SSID.'
          : 'Choose a Wi-Fi network and enter its password.';
    });
  }

  Future<void> _writeChain = Future<void>.value();

  /// Android's Bluetooth stack runs one write at a time and rejects the rest, so
  /// writes to Circuit are queued rather than fired concurrently.
  Future<void> _writeCircuit(String value) {
    final result = _writeChain.then((_) => _writeCircuitNow(value));
    _writeChain = result.catchError((_) {});
    return result;
  }

  Future<void> _writeCircuitNow(String value) async {
    final characteristic = _textCharacteristic;
    if (characteristic != null) {
      await characteristic.write(utf8.encode(value), withoutResponse: false);
      return;
    }
    if (_relayActive) {
      // The link can be busy with the service's own write; give it a moment.
      for (var attempt = 0; attempt < 4; attempt++) {
        final sent = await _relayChannel.invokeMethod<bool>('write', {
          'value': value,
        });
        if (sent == true) return;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw StateError('Circuit is not connected.');
  }

  Future<void> _startPhoneRelay() async {
    final device = _device;
    if (device == null) return;
    try {
      await _relayChannel.invokeMethod<void>('requestBatteryExemption');
      await device.disconnect();
      await _relayChannel.invokeMethod<void>('start', {
        'address': device.remoteId.str,
      });
      if (!mounted) return;
      setState(() {
        _device = null;
        _textCharacteristic = null;
        _relayCharacteristic = null;
        _circuits.clear();
        _relayActive = true;
        _status = 'Turning on stay connected…';
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshRelayStatus();
      unawaited(_sendHomeStatus());
    } catch (error) {
      _setStatus('Could not keep Circuit connected: $error');
    }
  }

  Future<void> _stopPhoneRelay() async {
    await _relayChannel.invokeMethod<void>('stop');
    if (mounted) {
      setState(() {
        _relayActive = false;
        _relayLink = RelayLink.off;
        _status = 'Stay connected is off.';
      });
    }
  }

  Future<void> _recordAudio() async {
    if (_audioBusy || _circuitPlayback != CircuitPlaybackPhase.idle) return;
    setState(() {
      _audioBusy = true;
      _recordingAudio = true;
      _recordingStartedAt = DateTime.now();
    });
    try {
      await _writeCircuit('@audio-record\n600');
      _setStatus('Starting recording on Circuit…');
    } catch (error) {
      _setStatus('Could not start recording: $error');
      if (mounted) setState(() => _recordingAudio = false);
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  /// Records a short clip on Circuit; once it syncs it is sent for recognition.
  Future<void> _identifySong() async {
    if (_audioBusy ||
        _recordingAudio ||
        _circuitPlayback != CircuitPlaybackPhase.idle) {
      return;
    }
    setState(() {
      _audioBusy = true;
      _recordingAudio = true;
      _recordingStartedAt = DateTime.now();
      _songClipArmed = true;
    });
    try {
      await _writeCircuit('@audio-record\n$_songClipSeconds');
      _setStatus('Listening for $_songClipSeconds seconds…');
    } catch (error) {
      _songClipArmed = false;
      _setStatus('Could not start listening: $error');
      if (mounted) setState(() => _recordingAudio = false);
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  /// Sends the note's clip for recognition. The recording is kept whatever the
  /// outcome, so a failure can simply be retried.
  Future<void> _identifySongNote(String id) async {
    if (!_identifyingSongs.add(id)) return;
    try {
      final path = _notes.where((n) => n.id == id).firstOrNull?.audioPath;
      if (path == null) return;
      await _updateNote(
        id,
        (n) => n.copyWith(
          status: 'Identifying song…',
          song: (n.song ?? const SongResult()).withState('identifying'),
        ),
      );
      try {
        final result = await _music.identify(
          wavSample(await readNoteAudio(path), seconds: _songClipSeconds),
        );
        Telemetry.event('song_identified', {'matched': result.matched});
        await _updateNote(
          id,
          (n) => n.copyWith(
            status: result.matched ? 'Song identified' : 'No match found',
            song: result,
          ),
        );
      } catch (error, stack) {
        Telemetry.event('song_identified', {'matched': false, 'ok': false});
        Telemetry.nonFatal('song_identify', error, stack);
        final message = error.toString().replaceFirst('Exception: ', '');
        await _updateNote(
          id,
          (n) => n.copyWith(
            status: 'Song identification failed',
            song: (n.song ?? const SongResult()).withState(
              'failed',
              error: message,
            ),
          ),
        );
      }
    } finally {
      _identifyingSongs.remove(id);
    }
  }

  /// Broadcasts a message out of Circuit's speaker: typed text that Gemini speaks, or your own voice held
  /// to talk. Nothing is saved: Circuit plays the clip and deletes it.
  Future<void> _broadcastToCircuit() async {
    final choice = await showDialog<_BroadcastChoice>(
      context: context,
      builder: (context) => const _BroadcastDialog(),
    );
    if (choice == null || !mounted) return;
    await _runBroadcast(speech: choice.speech, text: choice.text);
  }

  /// Makes the clip (Gemini speaks [text], or [speech] is raw 16 kHz microphone audio), sends it to Circuit, and
  /// returns the one line that says how it went (also shown in the status line).
  Future<String> _runBroadcast({Uint8List? speech, String? text}) async {
    setState(() => _broadcasting = true);
    var outcome = 'Circuit is playing your message';
    try {
      final Uint8List wav;
      if (speech != null) {
        wav = broadcastWav(speech, sourceRate: 16000);
      } else {
        _setStatus('Making the voice message…');
        wav = await _gemini.speakWav(text ?? '');
      }
      _setStatus('Sending it to Circuit…');
      await _relayChannel.invokeMethod<bool>('requestLocalNetwork');
      final problem = await _relayChannel.invokeMethod<String>('speakOnBoard', {
        'bytes': wav,
      });
      if (problem != null) outcome = 'Broadcast failed: $problem';
    } catch (error) {
      outcome =
          'Broadcast failed: ${error.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '')}';
    } finally {
      if (mounted) setState(() => _broadcasting = false);
    }
    _setStatus(outcome);
    return outcome;
  }

  /// The firmware this app was built with (assets/firmware/circuit.bin, see tool/bundle_firmware.py), or null
  /// when the app was built without one.
  Future<FirmwareImage?> _bundledFirmware() async {
    try {
      final data = await rootBundle.load('assets/firmware/circuit.bin');
      return FirmwareImage.parse(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
      return null;
    }
  }

  /// "Update Circuit": pick a firmware file (.bin) from the phone's storage and install it, after one
  /// confirmation. Circuit keeps its old firmware until the new one is written and checked, and goes back to
  /// it by itself if the new one fails to start.
  Future<void> _updateCircuitFirmware() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    final bytes = picked?.files.single.bytes;
    if (bytes == null || !mounted) return;
    try {
      await _installCircuitFirmware(FirmwareImage.parse(bytes));
    } on FormatException catch (error) {
      _setStatus(error.message);
    }
  }

  /// "Reset Circuit firmware": go back to the firmware Circuit had before its last update, or install the
  /// stable firmware that came inside this app (the factory version).
  Future<void> _resetCircuitFirmware() async {
    final previous = _boardPrevious;
    final stable = _bundledFirmwareImage ?? await _bundledFirmware();
    if (!mounted) return;
    final running = _boardFirmware;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              enabled: previous != null,
              leading: const Icon(LucideIcons.undo2),
              title: const Text('Go back to the previous firmware'),
              subtitle: Text(
                previous == null
                    ? 'Circuit has no earlier firmware stored'
                    : previous.version,
              ),
              onTap: previous == null
                  ? null
                  : () => Navigator.pop(context, 'previous'),
            ),
            ListTile(
              enabled: stable != null,
              leading: const Icon(LucideIcons.shieldCheck),
              title: const Text('Install the stable firmware'),
              subtitle: Text(
                stable == null
                    ? 'This app has no firmware inside'
                    : running == null
                    ? '${stable.version} · came with this app'
                    : '${stable.version} · came with this app, ${FirmwareImage.relation(stable.version, running.version)} Circuit\'s ${running.version}',
              ),
              onTap: stable == null
                  ? null
                  : () => Navigator.pop(context, 'stable'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'previous':
        await _revertCircuitFirmware();
      case 'stable':
        if (stable != null) await _installCircuitFirmware(stable);
    }
  }

  /// Confirms, then sends [image] to Circuit, which installs it and restarts.
  Future<void> _installCircuitFirmware(FirmwareImage image) async {
    if (!mounted) return;
    final running = _boardFirmware;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install firmware ${image.version}?'),
        content: Text(
          '${running == null ? '' : 'On Circuit now: ${running.version}\n'}'
          'This file: ${image.version}\n'
          '${running == null ? '' : '\nThis is ${FirmwareImage.relation(image.version, running.version)} what is on Circuit.${image.version == running.version && !image.sameBuildAs(running) ? ' (A different build of it.)' : ''}\n'}\n'
          'Circuit restarts when it is done, about a minute. It cannot record or switch off while it updates, '
          'so keep it powered and on the same Wi-Fi as this phone. If the new firmware does not start, Circuit '
          'goes back to the old one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _updatingFirmware = true);
    try {
      _setStatus('Sending the update to Circuit…');
      await _relayChannel.invokeMethod<bool>('requestLocalNetwork');
      final problem = await _relayChannel.invokeMethod<String>('updateBoard', {
        'bytes': image.bytes,
      });
      _setStatus(
        problem == null
            ? 'Circuit is installing the update and will restart'
            : 'Update failed: $problem',
      );
    } catch (error) {
      _setStatus(
        'Update failed: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    } finally {
      if (mounted) setState(() => _updatingFirmware = false);
    }
  }

  /// Asks Circuit to switch to the firmware it had before the last update. Nothing is sent: the old
  /// firmware is still in its other slot.
  Future<void> _revertCircuitFirmware() async {
    final previous = _boardPrevious;
    if (previous == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go back to the previous firmware?'),
        content: Text(
          'Circuit switches to ${FirmwareImage.describe(previous.version, previous.built)} and restarts, '
          'about 10 seconds. Your notes and settings stay as they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Go back'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _writeCircuit('@firmware-revert');
      _setStatus('Asking Circuit to go back to its previous firmware…');
    } catch (error) {
      _setStatus('Could not ask Circuit: $error');
    }
  }

  /// Asks Circuit to offer every note on its card again, including ones already synced. Notes this
  /// phone still has are not downloaded a second time; ones it no longer has (deleted on the phone
  /// only, or lost) come back.
  Future<void> _resendCircuitNotes() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send old notes again?'),
        content: const Text(
          'Circuit offers every note still on its card. Notes you deleted from this phone only will '
          'come back; notes already here are skipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send again'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _writeCircuit('@notes-resend');
      _setStatus('Asking Circuit to offer its old notes again…');
    } catch (error) {
      _setStatus('Could not ask Circuit: $error');
    }
  }

  /// Removes notes from Circuit's SD card that this phone has already saved.
  /// Notes still waiting to sync are never deleted.
  Future<void> _cleanCircuitNotes() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Free up Circuit storage?'),
        content: const Text(
          'This deletes voice notes from Circuit\'s SD card that are already saved on this phone. '
          'Notes that have not synced yet are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete synced notes'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _writeCircuit('@notes-clean');
      _setStatus('Asking Circuit to remove notes already saved on this phone…');
    } catch (error) {
      _setStatus('Could not clean Circuit: $error');
    }
  }

  Future<void> _stopRecording() async {
    if (!_recordingAudio) return;
    setState(() => _audioBusy = true);
    try {
      await _writeCircuit('@audio-stop');
      _setStatus('Stopping recording…');
    } catch (error) {
      _setStatus('Could not stop recording: $error');
    } finally {
      if (mounted) {
        setState(() {
          _audioBusy = false;
          _recordingAudio = false;
        });
      }
    }
  }

  // ---- navigation, tasks and preferences ----------------------------------

  /// Lets the UI extension in lib/ui/pages.dart rebuild this page.
  void _update(VoidCallback change) => setState(change);

  void _goTo(_AppPage page) {
    setState(() {
      // Choosing notes belongs to the Notes tab; leaving it ends the choosing.
      _selecting = false;
      _selectedNoteIds.clear();
      _pageHistory.add(_page);
      _page = page;
    });
    if (page == _AppPage.circuit && _circuitAvailable) _requestWifiStatus();
    if (page == _AppPage.wifi && _circuitAvailable) {
      _requestWifiStatus();
      if (_wifiNetworks.isEmpty && !_scanningWifi) _scanWifi();
    }
  }

  void _goBack() {
    setState(() {
      _page = _pageHistory.isEmpty ? _AppPage.notes : _pageHistory.removeLast();
    });
  }

  void _selectTab(int index) {
    setState(() {
      _selecting = false;
      _selectedNoteIds.clear();
      _pageHistory.clear();
      _page = const [
        _AppPage.notes,
        _AppPage.tasks,
        _AppPage.circuit,
        _AppPage.settings,
      ][index];
    });
    if (_page == _AppPage.circuit && _circuitAvailable) _requestWifiStatus();
  }

  /// Shows what a restore brought back.
  Future<void> _afterBackupRestore() async {
    await _loadNotes();
    await _loadGroups();
    await _loadPreferences();
    // Keys that came back with the backup switch the AI services on without a restart.
    await _loadGeminiState();
    await _loadAiState();
    await _loadMusicState();
  }

  Future<void> _loadPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    _pendingBoardDeletes.addAll(
      (preferences.getStringList(_boardDeletesKey) ?? const <String>[])
          .map(int.tryParse)
          .whereType<int>(),
    );
    List<CircuitTask> tasks = [];
    final stored = await _readSecret(preferences, _tasksKey);
    if (stored != null) {
      try {
        tasks = (jsonDecode(stored) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .map(CircuitTask.fromJson)
            .toList();
      } catch (_) {
        // A damaged task list is dropped rather than blocking the app.
      }
    }
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _autoTranscribe = preferences.getBool(_autoTranscribeKey) ?? true;
      _autoEnrich = preferences.getBool(_autoEnrichKey) ?? true;
      _useMoments = preferences.getBool(_useMomentsKey) ?? true;
      appThemeMode.value = themeModeFromName(
        preferences.getString(_themeModeKey),
      );
      // A new install has no saved notes yet; anyone who already uses the app never sees the welcome.
      _showOnboarding =
          Onboarding.enabled &&
          !(preferences.getBool(Onboarding.doneKey) ?? false) &&
          !preferences.containsKey(_notesKey);
      _shareDiagnostics = preferences.getBool(Telemetry.preferenceKey) ?? true;
    });
    // Reminders that rang or were snoozed while the app was closed, then make sure
    // Android has every reminder (a restore or an update may have changed the list).
    await _takeReminderEvents();
    unawaited(_syncReminders());
  }

  Future<void> _loadGeminiState() async {
    final key = await _gemini.apiKey();
    if (mounted)
      setState(() => _geminiConnected = key != null && key.isNotEmpty);
  }

  Future<void> _loadMusicState() async {
    final configured = await _music.isConfigured();
    if (mounted) setState(() => _musicConnected = configured);
  }

  Future<void> _loadAiState() async {
    final key = await _ai.apiKey();
    if (mounted) setState(() => _aiConnected = key != null && key.isNotEmpty);
  }

  Future<void> _saveTasks() async {
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _tasksKey,
      jsonEncode(_tasks.map((task) => task.toJson()).toList()),
    );
    unawaited(_sendHomeStatus());
    unawaited(_syncReminders());
  }

  /// Sends every open task that has a time to Android, which rings the reminders.
  Future<void> _syncReminders() async {
    try {
      await _relayChannel.invokeMethod<bool>('syncReminders', {
        'items': [
          for (final task in _tasks)
            if (!task.done && task.dueAt != null)
              {
                'id': task.id,
                'title': task.title,
                'detail': task.detail ?? '',
                'at': task.dueAt!.millisecondsSinceEpoch,
              },
        ],
      });
    } on MissingPluginException {
      // not running on the phone (tests)
    } catch (_) {
      // reminders are retried on the next change
    }
  }

  /// Applies what the person did from a reminder notification while the app was closed.
  Future<void> _takeReminderEvents() async {
    List<Object?> events;
    try {
      events =
          await _relayChannel.invokeMethod<List<Object?>>(
            'takeReminderEvents',
          ) ??
          const [];
    } catch (_) {
      return;
    }
    if (events.isEmpty || !mounted) return;
    setState(() {
      for (final raw in events.whereType<Map<Object?, Object?>>()) {
        final id = raw['id'];
        final at = raw['at'];
        _tasks = [
          for (final task in _tasks)
            if (task.id != id)
              task
            else if (raw['kind'] == 'done')
              task.copyWith(done: true)
            else if (at is num)
              task.copyWith(
                dueAt: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
              )
            else
              task,
        ];
      }
    });
    await _saveTasks();
  }

  /// Asks for the notification permission the first time a reminder is set.
  /// Returns false when the person said no, so the app can say so.
  Future<bool> _allowReminderNotifications() async {
    try {
      return (await Permission.notification.request()).isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Sets, changes or clears the time a task rings. Returns false when notifications are off.
  Future<bool> _setTaskDue(String id, DateTime? at) async {
    if (at != null && !await _allowReminderNotifications()) return false;
    setState(() {
      _tasks = [
        for (final task in _tasks)
          task.id == id
              ? (at == null
                    ? task.copyWith(clearDue: true)
                    : task.copyWith(dueAt: at))
              : task,
      ];
    });
    await _saveTasks();
    return true;
  }

  Future<bool> _addTask(String title, {String? detail, DateTime? dueAt}) async {
    // A time in the past cannot ring; the task is kept without one.
    final future = dueAt != null && dueAt.isAfter(DateTime.now());
    final allowed = !future || await _allowReminderNotifications();
    final task = CircuitTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      detail: detail,
      dueAt: future ? dueAt : null,
    );
    if (mounted) {
      setState(() => _tasks = [task, ..._tasks]);
    } else {
      _tasks = [task, ..._tasks];
    }
    await _saveTasks();
    return allowed;
  }

  Future<void> _setSuggestionState(
    String noteId,
    String suggestionId,
    String state,
  ) => _updateNote(
    noteId,
    (note) => note.copyWith(
      actionSuggestions: note.actionSuggestions
          .map(
            (item) =>
                item.id == suggestionId ? item.copyWith(state: state) : item,
          )
          .toList(),
    ),
  );

  Future<void> _toggleTask(String id) async {
    setState(() {
      _tasks = [
        for (final task in _tasks)
          task.id == id ? task.copyWith(done: !task.done) : task,
      ];
    });
    await _saveTasks();
  }

  Future<void> _deleteTask(String id) async {
    setState(() => _tasks = _tasks.where((task) => task.id != id).toList());
    await _saveTasks();
  }

  Future<void> _setShareDiagnostics(bool value) async {
    setState(() => _shareDiagnostics = value);
    await Telemetry.setEnabled(value);
  }

  Future<void> _sendTestReport() async {
    final sent = await Telemetry.sendTestReport();
    _setStatus(
      sent
          ? 'Test report sent. It can take a few minutes to show in Firebase.'
          : 'Nothing was sent: diagnostics are off or not set up in this build.',
    );
  }

  Future<void> _setAutoEnrich(bool value) async {
    setState(() => _autoEnrich = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_autoEnrichKey, value);
  }

  /// Ends the welcome screens for good, and optionally lands on a tab (2 = Circuit, 3 = Settings).
  Future<void> _finishOnboarding({int? tab}) async {
    setState(() => _showOnboarding = false);
    if (tab != null) _selectTab(tab);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(Onboarding.doneKey, true);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    appThemeMode.value = mode;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeModeKey, mode.name);
  }

  Future<void> _setUseMoments(bool value) async {
    setState(() => _useMoments = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_useMomentsKey, value);
  }

  Future<void> _setAutoTranscribe(bool value) async {
    setState(() => _autoTranscribe = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_autoTranscribeKey, value);
  }

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) => _buildShell();
}
