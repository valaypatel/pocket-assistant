import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

part 'music.dart';
part 'secure_notes.dart';
part 'ui/chat_page.dart';
part 'ui/detail_pages.dart';
part 'ui/pages.dart';
part 'ui/recording_view.dart';
part 'ui/song_page.dart';
part 'ui/theme.dart';

const _circuitName = 'Circuit';
final _textServiceId = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
final _textCharacteristicId = Guid('0000fff1-0000-1000-8000-00805f9b34fb');
final _relayCharacteristicId = Guid('0000fff2-0000-1000-8000-00805f9b34fb');
const _relayChannel = MethodChannel('circuit/relay');
const _audioStatusEvents = EventChannel('circuit/audio_status');
const _savedCircuitIdKey = 'saved_circuit_id';
const _secureBondMigrationKey = 'secure_bond_migration_complete';
const _notesKey = 'circuit_notes';
const _geminiApiKey = 'gemini_api_key';
const _geminiModelKey = 'gemini_model';
const _defaultGeminiModel = 'gemini-3.5-flash-lite';
const _aiApiKey = 'hermes_api_key';
const _aiBaseUrlKey = 'hermes_base_url';
const _aiModelKey = 'hermes_model';
const _defaultAiModel = 'hermes-agent';
const _defaultAiBaseUrl = 'https://hermes.yourdomain.com/v1';
const _secureStorage = FlutterSecureStorage();

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

  Future<GeminiTranscription> transcribeWav(
    Uint8List wavBytes, {
    bool detectMusic = true,
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
                        'Transcribe this voice note exactly. Preserve Gujarati script, English, and mixed Gujarati-English. Return the complete transcription only. Do not summarise, classify, translate, or add a title.'
                        '${detectMusic ? ' Exception: if the recording is mainly music or a song playing, with no one speaking to record a note, reply with exactly [[MUSIC]] and nothing else.' : ''}'
                        ' If it is only silence or background noise, reply with exactly [[NOISE]].',
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
    final candidates = decoded['candidates'] as List<dynamic>?;
    final content = candidates?.isNotEmpty == true
        ? (candidates!.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?
        : null;
    final text = content?['parts'] as List<dynamic>?;
    final result = text
        ?.whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join()
        .trim();
    return parseTranscriptionText(result, allowMusic: detectMusic);
  }

  /// Turns Gemini's plain-text answer into a transcription. A recording of
  /// music comes back as the [[MUSIC]] marker and silence as [[NOISE]].
  static GeminiTranscription parseTranscriptionText(
    String? answer, {
    bool allowMusic = true,
  }) {
    final result = answer?.trim() ?? '';
    if (result.isEmpty ||
        result.startsWith('[[NOISE]]') ||
        (!allowMusic && result.startsWith('[[MUSIC]]'))) {
      throw Exception('No speech detected.');
    }
    if (result.startsWith('[[MUSIC]]')) {
      return const GeminiTranscription(
        category: 'music',
        title: 'Song',
        transcript: '',
        audioType: 'music',
      );
    }
    return GeminiTranscription(
      category: 'note',
      title: const GeminiClient()._fallbackHeading(result),
      transcript: result,
    );
  }

  String _fallbackHeading(String transcript) {
    final words = transcript
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
              'You answer questions about one private voice note. Use only the note below. If the answer is not in the note, say so plainly instead of guessing. Be brief. Reply in the language the user writes in. Plain text, no markdown headings.\n\n--- NOTE ---\n$context',
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
  Future<ReminderDraft> extractReminder(String transcript) async {
    final response = await _completion([
      {
        'role': 'system',
        'content': 'You detect reminders in private voice-note transcripts. Return JSON only: {"hasReminder":true|false,"title":"short title in English","scheduledAt":"ISO-8601 local date-time or null","details":"brief detail in English"}. Set scheduledAt only when the note clearly states a date or time; never invent one. Preserve the meaning of Hindi and Gujarati.',
      },
      {
        'role': 'user',
        'content':
            'Today is ${DateTime.now().toIso8601String()}. Transcript:\n$transcript',
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

  Future<AiEnrichment> enrich(String transcript) async {
    final response = await _completion([
      {
        'role': 'system',
        'content': 'You analyse private voice-note transcripts. Return JSON only: {"title":"short heading in English","category":"primary category","categories":["primary category","optional secondary categories"],"tags":["short English searchable tags"],"summary":"one short English sentence","englishTranslation":"faithful English translation; if already English, repeat it","language":"language or mixed","actions":[{"type":"task|reminder|calendar_event","title":"action title in English","details":"brief detail in English","scheduledAt":"ISO-8601 local time or null"}]}. Categories may include note, idea, task, reminder, calendar_event, shopping, journal, project, meeting, reference. Translate Hindi/Gujarati faithfully but never alter the original transcript. Suggest actions only when clearly supported; never invent dates. Use reminder or calendar_event only when the note states a date or time; otherwise the action type must be task.',
      },
      {
        'role': 'user',
        'content':
            'Today is ${DateTime.now().toIso8601String()}. Transcript:\n$transcript',
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
      actions: actions,
    );
  }
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
  });

  final String category;
  final String title;
  final String transcript;

  /// 'speech', or 'music' when the recording is a song rather than a note.
  final String audioType;

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

  bool get isSong => kind == 'song';

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
    kind: json['kind']?.toString() == 'song' ? 'song' : 'voice',
    song: json['song'] is Map<String, dynamic>
        ? SongResult.fromJson(json['song'] as Map<String, dynamic>)
        : null,
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
    if (isSong) 'kind': kind,
    if (song != null) 'song': song!.toJson(),
  };
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterCryptography.enable(); // native AES-GCM, much faster than Dart on long notes
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const ShortCircuitApp());
}

enum _AppPage { home, notes, tasks, settings, circuit, wifi, hiddenWifi }

const _tasksKey = 'circuit_tasks';
const _boardDeletesKey = 'pending_board_deletes';
const _autoTranscribeKey = 'auto_transcribe';
const _displayNameKey = 'display_name';

class CircuitTask {
  const CircuitTask({
    required this.id,
    required this.title,
    this.detail,
    this.done = false,
  });

  final String id;
  final String title;
  final String? detail;
  final bool done;

  CircuitTask copyWith({bool? done}) => CircuitTask(
    id: id,
    title: title,
    detail: detail,
    done: done ?? this.done,
  );

  factory CircuitTask.fromJson(Map<String, dynamic> json) => CircuitTask(
    id: json['id'] as String,
    title: json['title'] as String,
    detail: json['detail'] as String?,
    done: json['done'] == true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (detail != null) 'detail': detail,
    'done': done,
  };
}

class ShortCircuitApp extends StatelessWidget {
  const ShortCircuitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Short-Circuit',
      theme: buildScTheme(),
      home: const CircuitHomePage(),
    );
  }
}

class CircuitHomePage extends StatefulWidget {
  const CircuitHomePage({super.key});

  @override
  State<CircuitHomePage> createState() => _CircuitHomePageState();
}

class _CircuitHomePageState extends State<CircuitHomePage> {
  final _wifiSsidController = TextEditingController();
  final _wifiPasswordController = TextEditingController();
  final _noteSearchController = TextEditingController();
  bool _noteSearchOpen = false;
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
  _AppPage _page = _AppPage.home;
  final List<_AppPage> _pageHistory = [];
  List<CircuitTask> _tasks = [];
  bool _autoTranscribe = true;
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
  String _displayName = '';
  DateTime? _recordingStartedAt;
  Timer? _clockTicker;
  bool _pruneRequested = false;
  // Automatic retry of AI review: how often each note was tried, and when.
  final Map<String, int> _enrichAttempts = {};
  final Map<String, DateTime> _enrichLastAttempt = {};
  // Notes deleted in the app whose copy on Circuit still has to be removed.
  final Set<int> _pendingBoardDeletes = {};
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
  bool _resetNoticeShown = false;
  // What Circuit reports about its own Wi-Fi: none, connecting, connected, failed.
  String _wifiState = 'none';
  String _wifiSsid = '';
  String _wifiDetail = '';
  bool _showWifiPassword = false;
  DateTime? _wifiConnectingSince;
  Timer? _wifiPollTimer;
  bool _audioBusy = false;
  bool _recordingAudio = false;
  bool _relayActive = false;
  List<String> _wifiNetworks = [];
  List<CircuitNote> _notes = [];
  String? _savedCircuitId;
  String? _lastAudioStatus;
  String? _syncingNoteId;
  String? _transcribingNoteId;
  int? _syncProgress;
  String _status = 'Tap Scan to find your Circuit.';

  @override
  void initState() {
    super.initState();
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      _onScanResults,
      onError: (Object error) => _setStatus('Scan failed: $error'),
    );
    _restoreLastCircuit();
    _loadNotes().then((_) => _reconcileSyncedNotes());
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
      _requestWifiStatus();
      _checkForLostNotes();
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
      const Duration(seconds: 30),
      (_) => _sendHomeStatus(),
    );
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _relaySubscription?.cancel();
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
      final active = status != 'Stopped';
      if (active || _relayActive) {
        setState(() {
          _relayActive = active;
          if (_syncingNoteId == null) {
            _status = active ? status : 'Phone relay stopped.';
          }
        });
      }
    } on PlatformException {
      // The app can still be used normally if the native relay is unavailable.
    }
  }

  Future<void> _loadNotes() async {
    final preferences = await SharedPreferences.getInstance();
    final String? storedNotes;
    try {
      storedNotes = await _readSecret(preferences, _notesKey);
    } catch (error) {
      // Never delete what could not be read: the data is still there.
      _setStatus(
        'Saved notes could not be opened ($error). They have not been deleted.',
      );
      return;
    }
    if (storedNotes == null || !mounted) return;
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
    } catch (error) {
      // Leave the stored notes untouched so nothing is lost; they can be recovered.
      debugPrint('Short-Circuit: saved notes could not be read: $error');
      _setStatus('Saved notes could not be read. They have not been deleted.');
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
    final notes = _notes
        .map(
          (note) => note.id == id
              ? note.copyWith(
                  status: _aiConnected
                      ? 'Transcribed. Analysing…'
                      : 'Transcribed. Add an AI service for smart review.',
                  transcript: transcription.transcript,
                  title: transcription.title,
                  category: transcription.category,
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
    final path = note?.audioPath;
    if (path == null || ((note?.isSong ?? false) && !asSpeech)) return null;
    if (asSpeech && (note?.isSong ?? false)) {
      await _updateNote(id, (n) => n.copyWith(kind: 'voice', clearSong: true));
    }
    setState(() => _transcribingNoteId = id);
    await _setNoteStatus(id, 'Transcribing with Gemini…');
    try {
      final transcription = await _gemini.transcribeWav(
        await readNoteAudio(path),
        detectMusic: !asSpeech,
      );
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
      if (_aiConnected) unawaited(_enrichNote(id));
      return transcription;
    } catch (error) {
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
    if (!_aiConnected) return;
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
    try {
      final enrichment = await _ai.enrich(transcript);
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
          title: enrichment.title,
          category: enrichment.category,
          categories: enrichment.categories,
          tags: enrichment.tags,
          summary: enrichment.summary,
          englishTranslation: enrichment.englishTranslation,
          language: enrichment.language,
          enrichmentStatus: 'ready',
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

  Future<void> _restoreLastCircuit() async {
    final preferences = await SharedPreferences.getInstance();
    final deviceId = preferences.getString(_savedCircuitIdKey);
    if (deviceId == null || !mounted) return;
    final savedDevice = BluetoothDevice.fromId(deviceId);
    if (await savedDevice.bondState.first != BluetoothBondState.bonded) {
      await preferences.remove(_savedCircuitIdKey);
      if (mounted) {
        setState(() {
          _savedCircuitId = null;
          _status = 'Circuit was unpaired. Scan to pair it again.';
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
  }) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting to Circuit…';
    });
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      final preferences = await SharedPreferences.getInstance();
      var bondState = await device.bondState.first;
      if (bondState == BluetoothBondState.bonded &&
          preferences.getBool(_secureBondMigrationKey) != true) {
        await device.removeBond();
        bondState = BluetoothBondState.none;
      }
      if (bondState != BluetoothBondState.bonded) {
        _setStatus(
          'Enter Circuit’s six-digit code in the Android pairing prompt…',
        );
        await device.createBond();
        await preferences.setBool(_secureBondMigrationKey, true);
      }
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
    if (!mounted || status == _lastAudioStatus) return;
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
        'Recording saved on Circuit. It syncs automatically when Circuit and this phone are on the same Wi-Fi.',
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
    final syncingNoteId = _syncingNoteId;
    if (syncingNoteId == null) return;
    if (status.startsWith('Sync started') ||
        status.startsWith('Sync in progress')) {
      final match = RegExp(r'(\d+)%').firstMatch(status);
      if (match != null) {
        setState(() => _syncProgress = int.parse(match.group(1)!));
      }
      // Progress shows in the banner; rewriting the saved note on every tick is
      // slow and used to flood Circuit with status updates.
      if (status.startsWith('Sync started')) {
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
    int? field(String name) => int.tryParse(
      RegExp('$name=(-?\\d+)').firstMatch(message)?.group(1) ?? '',
    );
    final waiting = field('waiting');
    final reset = field('reset');
    final uptime = field('uptime');
    setState(() {
      if (waiting != null) {
        if (waiting > 0 && (_boardWaiting ?? 0) == 0)
          _waitingSince = DateTime.now();
        if (waiting == 0) {
          _waitingSince = null;
          if (!_syncActive) _syncError = null; // everything made it across
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
    (note) => note.audioPath == null && note.createdAt.isBefore(cutoff),
  );

  Future<void> _pruneLostNotes() async {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
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

  /// Once per session, if old notes are still waiting for audio, ask Circuit
  /// whether it has anything left to send. Its answer decides their fate.
  void _checkForLostNotes() {
    if (_pruneRequested || !_circuitAvailable) return;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    if (_notesWithoutAudio(cutoff).isEmpty) return;
    _pruneRequested = true;
    _writeCircuit('@audio-sync').catchError((Object _) {
      _pruneRequested = false;
    });
  }

  /// A synced file belongs to the oldest note still waiting for audio; if the
  /// recording happened while the app was closed there is none, so make one.
  /// True if a note for this Circuit recording already exists. Numbers restart
  /// if Circuit is reset, so only a note from the last ten minutes counts.
  bool _knownBoardNote(int boardId, DateTime around) => _notes.any(
    (note) =>
        note.boardId == boardId &&
        note.createdAt.difference(around).abs() < const Duration(minutes: 10),
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
      await _writeCircuit('@audio-sync');
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
    _setStatus(
      started == true
          ? 'Playing this voice note on your phone.'
          : 'Could not play this voice note.',
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

  Future<String> _askAboutNote(String noteId, List<ChatMessage> history) {
    final note = _notes.where((n) => n.id == noteId).firstOrNull;
    if (note == null) throw Exception('This note no longer exists.');
    return _ai.chatAboutNote(note, history);
  }

  Future<void> _deleteNote(String id) async {
    final note = _notes.where((item) => item.id == id).firstOrNull;
    final boardId = _boardIdOf(note);
    if (boardId != null) {
      _pendingBoardDeletes.add(boardId);
      unawaited(_saveBoardDeletes());
      _lastBoardDeleteSent = null;
      _processBoardDeletes();
    }
    if (note?.audioPath != null) {
      try {
        await File(note!.audioPath!).delete();
      } catch (_) {
        // The file may already have been removed.
      }
    }
    final notes = _notes.where((item) => item.id != id).toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('note_chat_$id');
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
    final synced = _notes.where((note) => note.audioPath != null).length;
    final pending = _notes.length - synced;
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

  Future<ReminderDraft?> _extractReminder(String transcript) async {
    try {
      return await _ai.extractReminder(transcript);
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
    final lines = message.split('\n');
    if (lines.length < 2 || !mounted) return;
    final state = lines[1];
    final ssid = lines.length > 2 ? lines[2] : '';
    final detail = lines.length > 3 ? lines.sublist(3).join('\n') : '';
    setState(() {
      _wifiState = state;
      _wifiSsid = ssid;
      _wifiDetail = detail;
      if (state == 'connecting') {
        _wifiConnectingSince ??= DateTime.now();
      } else {
        _wifiConnectingSince = null;
      }
    });
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
        _status = 'Starting phone relay…';
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshRelayStatus();
      unawaited(_sendHomeStatus());
    } catch (error) {
      _setStatus('Could not start phone relay: $error');
    }
  }

  Future<void> _stopPhoneRelay() async {
    await _relayChannel.invokeMethod<void>('stop');
    if (mounted) {
      setState(() {
        _relayActive = false;
        _status = 'Phone relay stopped.';
      });
    }
  }

  Future<void> _recordAudio() async {
    if (_audioBusy) return;
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
    if (_audioBusy || _recordingAudio) return;
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
        await _updateNote(
          id,
          (n) => n.copyWith(
            status: result.matched ? 'Song identified' : 'No match found',
            song: result,
          ),
        );
      } catch (error) {
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

  Future<void> _playAudio() async {
    if (_audioBusy) return;
    setState(() => _audioBusy = true);
    try {
      await _writeCircuit('@audio-play');
      _setStatus('Circuit is playing its latest recording.');
      await Future<void>.delayed(const Duration(seconds: 6));
    } catch (error) {
      _setStatus('Could not play recording: $error');
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  // ---- navigation, tasks and preferences ----------------------------------

  /// Lets the UI extension in lib/ui/pages.dart rebuild this page.
  void _update(VoidCallback change) => setState(change);

  void _goTo(_AppPage page) {
    setState(() {
      _pageHistory.add(_page);
      _page = page;
    });
    if (page == _AppPage.wifi && _circuitAvailable) {
      _requestWifiStatus();
      if (_wifiNetworks.isEmpty && !_scanningWifi) _scanWifi();
    }
  }

  void _goBack() {
    setState(() {
      _page = _pageHistory.isEmpty ? _AppPage.home : _pageHistory.removeLast();
    });
  }

  void _selectTab(int index) {
    setState(() {
      _pageHistory.clear();
      _page = const [
        _AppPage.home,
        _AppPage.notes,
        _AppPage.tasks,
        _AppPage.settings,
      ][index];
    });
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
      _displayName = preferences.getString(_displayNameKey) ?? _displayName;
    });
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
  }

  Future<void> _addTask(String title, {String? detail}) async {
    final task = CircuitTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      detail: detail,
    );
    if (mounted) {
      setState(() => _tasks = [task, ..._tasks]);
    } else {
      _tasks = [task, ..._tasks];
    }
    await _saveTasks();
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

  Future<void> _setAutoTranscribe(bool value) async {
    setState(() => _autoTranscribe = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_autoTranscribeKey, value);
  }

  Future<void> _saveDisplayName(String name) async {
    setState(() => _displayName = name);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_displayNameKey, name);
  }

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) => _buildShell();
}
