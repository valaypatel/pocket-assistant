import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'ui/detail_pages.dart';
part 'ui/pages.dart';
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

  Future<GeminiTranscription> transcribeWav(Uint8List wavBytes) async {
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
                    'text': 'Transcribe this voice note exactly. Preserve Gujarati script, English, and mixed Gujarati-English. Classify it as exactly one of: note, reminder, task, calendar_event, idea, shopping, journal. Return valid JSON only with category, title (a short useful heading, maximum 8 words), and transcript (the complete transcription).',
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
            'generationConfig': {'responseMimeType': 'application/json'},
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
    if (result == null || result.isEmpty) {
      throw Exception('No speech detected.');
    }
    if (result.contains('"transcript"') &&
        parseGeminiTranscriptionPayload(result) == null) {
      throw Exception('No speech detected.');
    }
    final parsed = parseGeminiTranscriptionPayload(result);
    if (parsed != null) {
      return GeminiTranscription(
        category: _normaliseCategory(parsed['category'] as String?),
        title: (parsed['title'] as String?)?.trim().isNotEmpty == true
            ? (parsed['title'] as String).trim()
            : _fallbackHeading(parsed['transcript'] as String),
        transcript: (parsed['transcript'] as String).trim(),
      );
    }
    return GeminiTranscription(
      category: 'note',
      title: _fallbackHeading(result),
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

  Future<ReminderDraft> extractReminder(String transcript) async {
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
                        'Read this voice note and detect whether it contains a reminder or task. Today is ${DateTime.now().toIso8601String()}. Return JSON only with hasReminder (boolean), title (short title), scheduledAt (ISO 8601 local date/time or null if no date/time is present), and details (short details). Preserve Gujarati meaning. Transcript: $transcript',
                  },
                ],
              },
            ],
            'generationConfig': {'responseMimeType': 'application/json'},
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Gemini ${response.statusCode}: ${response.body}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    final content = candidates?.isNotEmpty == true
        ? (candidates!.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?
        : null;
    final parts = content?['parts'] as List<dynamic>?;
    final text = parts
        ?.whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join()
        .trim();
    if (text == null || text.isEmpty) {
      throw Exception('Gemini returned no reminder suggestion.');
    }
    final parsed = jsonDecode(text) as Map<String, dynamic>;
    return ReminderDraft(
      hasReminder: parsed['hasReminder'] == true,
      title: (parsed['title'] as String?)?.trim() ?? 'Reminder',
      scheduledAt: DateTime.tryParse(parsed['scheduledAt'] as String? ?? ''),
      details: (parsed['details'] as String?)?.trim() ?? transcript,
    );
  }

  String _normaliseCategory(String? value) {
    const categories = {
      'note',
      'reminder',
      'task',
      'calendar_event',
      'idea',
      'shopping',
      'journal',
    };
    final category = value?.trim().toLowerCase();
    return categories.contains(category) ? category! : 'note';
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

class GeminiTranscription {
  const GeminiTranscription({
    required this.category,
    required this.title,
    required this.transcript,
  });

  final String category;
  final String title;
  final String transcript;
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
  });

  final String id;
  final DateTime createdAt;
  final String status;
  final String? audioPath;
  final String? transcript;
  final String? title;
  final String? category;

  factory CircuitNote.fromJson(Map<String, dynamic> json) => CircuitNote(
    id: json['id'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: json['status'] as String,
    audioPath: json['audioPath'] as String?,
    transcript: json['transcript'] as String?,
    title: json['title'] as String?,
    category: json['category'] as String?,
  );

  Map<String, String> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'status': status,
    if (audioPath != null) 'audioPath': audioPath!,
    if (transcript != null) 'transcript': transcript!,
    if (title != null) 'title': title!,
    if (category != null) 'category': category!,
  };
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const ShortCircuitApp());
}

enum _AppPage { home, notes, tasks, settings, circuit, wifi, hiddenWifi }

const _tasksKey = 'circuit_tasks';
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

  CircuitTask copyWith({bool? done}) =>
      CircuitTask(id: id, title: title, detail: detail, done: done ?? this.done);

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
  String _displayName = 'Valay';
  DateTime? _recordingStartedAt;
  Timer? _clockTicker;
  bool _pruneRequested = false;
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
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // Keeps the recording timer moving.
      if (mounted && _recordingAudio) setState(() {});
    });
    _wifiPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        _requestWifiStatus();
        _checkForLostNotes();
      },
    );
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
    final storedNotes = preferences.getString(_notesKey);
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
            );
          }
        }
        // A process restart means no transfer can still be running. Make an
        // old persisted progress message explicitly retryable.
        if (note.status.startsWith('Sync started') ||
            note.status.startsWith('Sync in progress') ||
            note.status.startsWith('Recording saved on Circuit')) {
          changed = true;
          return CircuitNote(
            id: note.id,
            createdAt: note.createdAt,
            status: 'Sync interrupted. Tap Sync to retry.',
            audioPath: note.audioPath,
            transcript: note.transcript,
            title: note.title,
            category: note.category,
          );
        }
        return note;
      }).toList();
      setState(() {
        _notes = notes;
      });
      unawaited(_sendHomeStatus());
      if (changed) {
        await preferences.setString(
          _notesKey,
          jsonEncode(notes.map((item) => item.toJson()).toList()),
        );
      }
    } catch (_) {
      await preferences.remove(_notesKey);
    }
  }

  Future<String> _addPendingNote(String status, {DateTime? createdAt}) async {
    final note = CircuitNote(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: createdAt ?? DateTime.now(),
      status: status,
    );
    final notes = [note, ..._notes];
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
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
              ? CircuitNote(
                  id: note.id,
                  createdAt: note.createdAt,
                  status: status,
                  audioPath: audioPath ?? note.audioPath,
                  transcript: note.transcript,
                  title: note.title,
                  category: note.category,
                )
              : note,
        )
        .toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
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
              ? CircuitNote(
                  id: note.id,
                  createdAt: note.createdAt,
                  status: 'Transcription ready',
                  audioPath: note.audioPath,
                  transcript: transcription.transcript,
                  title: transcription.title,
                  category: transcription.category,
                )
              : note,
        )
        .toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() => _notes = notes);
    unawaited(_sendHomeStatus());
  }

  Future<GeminiTranscription?> _transcribeNote(String id) async {
    if (_transcribingNoteId != null) return null;
    final note = _notes.where((item) => item.id == id).firstOrNull;
    final path = note?.audioPath;
    if (path == null) return null;
    setState(() => _transcribingNoteId = id);
    await _setNoteStatus(id, 'Transcribing with Gemini…');
    try {
      final transcription = await _gemini.transcribeWav(
        await File(path).readAsBytes(),
      );
      await _setNoteTranscript(id, transcription);
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

  void _onRelayMessage(List<int> value) {
    final message = utf8.decode(value, allowMalformed: true);
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
    if (status.startsWith('@wifi-status\n')) {
      _applyWifiStatus(status);
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
      }
    });
    if (status.startsWith('Recording saved') ||
        status.startsWith('Recording stopped')) {
      _addPendingNote(
        'Recording saved on Circuit. It syncs automatically when Circuit and this phone are on the same Wi-Fi.',
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
      unawaited(_attachSyncedFile(path, epoch, preferNoteId: syncingId));
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
      _setNoteStatus(syncingNoteId, status.replaceAll('\n', ' • '));
    } else if (status.startsWith('Sync failed')) {
      _audioBusy = false;
      _syncingNoteId = null;
      _syncProgress = null;
      _setNoteStatus(syncingNoteId, status);
    }
  }

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
    await preferences.setString(
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
    final preferred = preferNoteId == null
        ? null
        : _notes.where((n) => n.id == preferNoteId && n.audioPath == null).firstOrNull;
    if (preferred != null) {
      noteId = preferred.id;
    } else if (epochSeconds != null && epochSeconds > 0) {
      final recorded = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
      Duration? bestGap;
      for (final note in _pendingNotes()) {
        final gap = note.createdAt.difference(recorded).abs();
        if (gap < const Duration(minutes: 10) && (bestGap == null || gap < bestGap)) {
          noteId = note.id;
          bestGap = gap;
        }
      }
    } else {
      noteId = _pendingSyncNoteId();
    }
    if (noteId == null) {
      noteId = await _addPendingNote(
        'Synced. Transcription starting…',
        createdAt: epochSeconds != null && epochSeconds > 0
            ? DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000)
            : null,
      );
    }
    await _transcribeAfterSync(noteId, path);
  }

  /// Picks up notes the phone downloaded in the background while the app UI was
  /// not running.
  Future<void> _reconcileSyncedNotes() async {
    try {
      final files = await _relayChannel.invokeListMethod<String>('syncedNotes');
      for (final entry in files ?? const <String>[]) {
        final fields = entry.split('|');
        await _attachSyncedFile(
          fields.first,
          fields.length > 1 ? int.tryParse(fields[1]) : null,
        );
      }
    } catch (_) {
      // Reconciliation is best-effort; the next sync status retries it.
    }
  }

  Future<void> _transcribeAfterSync(String noteId, String? audioPath) async {
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
    final started = await _relayChannel.invokeMethod<bool>(
      'playSyncedRecording',
      {'path': path},
    );
    _setStatus(
      started == true
          ? 'Playing this voice note on your phone.'
          : 'Could not play this voice note.',
    );
  }

  Future<void> _deleteNote(String id) async {
    final note = _notes.where((item) => item.id == id).firstOrNull;
    if (note?.audioPath != null) {
      try {
        await File(note!.audioPath!).delete();
      } catch (_) {
        // The file may already have been removed.
      }
    }
    final notes = _notes.where((item) => item.id != id).toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
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
      return await _gemini.extractReminder(transcript);
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
    List<CircuitTask> tasks = [];
    final stored = preferences.getString(_tasksKey);
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
    if (mounted) setState(() => _geminiConnected = key != null && key.isNotEmpty);
  }

  Future<void> _saveTasks() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
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
