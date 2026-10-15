part of 'main.dart';

/// Lets a test run the app from a computer: `adb shell am start -n <app>/.MainActivity --es test_cmd sync`.
/// Off unless "Test mode" is switched on in Settings, so a normal install cannot be driven from outside.
/// Every command writes one line starting "CircuitTest:" to the log (read with `adb logcat -s CircuitTest`).
const _testChannel = MethodChannel('circuit/test');

extension _TestControl on _CircuitHomePageState {
  void _initTestControl() {
    _testChannel.setMethodCallHandler((call) async {
      if (call.method == 'command') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        await _runTestCommand('${args['cmd']}', '${args['args'] ?? ''}');
      }
    });
    unawaited(() async {
      _testMode = await _testChannel.invokeMethod<bool>('mode') ?? false;
      if (!mounted) return;
      _update(() {});
      final pending = await _testChannel.invokeMapMethod<String, dynamic>(
        'pending',
      );
      if (pending != null) {
        // A command that starts the app must not run before the saved notes and tasks are open.
        await Future<void>.delayed(const Duration(seconds: 3));
        await _runTestCommand('${pending['cmd']}', '${pending['args'] ?? ''}');
      }
    }());
  }

  Future<void> _setTestMode(bool value) async {
    _update(() => _testMode = value);
    await _testChannel.invokeMethod<void>('setMode', value);
  }

  Future<void> _testLog(String line) =>
      _testChannel.invokeMethod<void>('log', line);

  Future<void> _runTestCommand(String cmd, String args) async {
    // Read the setting fresh: a command that starts the app can arrive before the page has loaded it.
    _testMode = await _testChannel.invokeMethod<bool>('mode') ?? false;
    if (!_testMode) {
      await _testLog('ignored $cmd: test mode is off');
      return;
    }
    final parts = args.split(RegExp(r'[ ,]+')).where((a) => a.isNotEmpty);
    final first = parts.firstOrNull;
    try {
      switch (cmd) {
        case 'state':
          await _testLog('state ${jsonEncode(_testState())}');
        case 'sync':
          await _retrySync();
          await _testLog('sync requested');
        case 'sync-note':
          if (first == null) {
            await _testLog('sync-note needs a note id');
            return;
          }
          await _syncLatestRecording(first);
          await _testLog('sync-note $first requested');
        case 'play':
          await _playAudio();
          await _testLog('play requested');
        case 'play-stop':
          await _stopCircuitPlayback();
          await _testLog('play-stop requested');
        case 'rec-start':
          await _startPhoneRecording();
          await _testLog('rec-start requested');
        case 'rec-pause':
          await _phoneRecorder.invokeMethod<void>('pause');
          await _testLog('rec-pause requested');
        case 'rec-resume':
          await _phoneRecorder.invokeMethod<void>('resume');
          await _testLog('rec-resume requested');
        case 'rec-stop':
          await _phoneRecorder.invokeMethod<void>('stop');
          await _testLog('rec-stop requested');
        case 'transcribe':
          // transcribe <board number>: transcribe that note now, then say what the transcript looks like
          final board = int.tryParse(first ?? '');
          final note = _notes.where((n) => _boardIdOf(n) == board).firstOrNull;
          if (note == null) {
            await _testLog('transcribe: no note with board number $board');
            return;
          }
          await _transcribeNote(note.id);
          final text =
              _notes.where((n) => n.id == note.id).firstOrNull?.transcript ??
              '';
          final devanagari = RegExp(r'[\u0900-\u097F]').allMatches(text).length;
          final latin = RegExp(r'[A-Za-z]').allMatches(text).length;
          await _testLog(
            'transcribe $board: ${text.length} characters, $devanagari Devanagari, $latin Latin; '
            '${jsonEncode(text.length > 140 ? text.substring(0, 140) : text)}',
          );
        case 'btlog':
          // btlog [lines]: the phone's private Bluetooth log (bond changes, drops, repair taps), newest last
          final count = int.tryParse(first ?? '') ?? 80;
          final text =
              await _relayChannel.invokeMethod<String>('btLogRead', {
                'lines': count,
              }) ??
              '';
          for (final line in text.split('\n').where((l) => l.isNotEmpty)) {
            await _testLog('btlog $line');
          }
          await _testLog('btlog end');
        case 'moments':
          // moments <board number>: the note's Moments, in ms from the start of the whole note
          final board = int.tryParse(first ?? '');
          final note = _notes.where((n) => _boardIdOf(n) == board).firstOrNull;
          final files = note?.audioFiles ?? const <String>[];
          await _testLog(
            'moments $board ${jsonEncode(await Moments.forNote(files))}',
          );
        case 'play-moment':
          // play-moment <board number> <ms>: play from a Moment, then say where playback is
          final board = int.tryParse(first ?? '');
          final at = int.tryParse(parts.skip(1).firstOrNull ?? '') ?? 0;
          final note = _notes.where((n) => _boardIdOf(n) == board).firstOrNull;
          if (note == null) {
            await _testLog('play-moment: no note with board number $board');
            return;
          }
          unawaited(_playNoteFrom(note.id, at));
          await Future<void>.delayed(const Duration(milliseconds: 2500));
          final now = _nowPlaying.value;
          await _testLog(
            'play-moment $board at $at: part ${now?.part}/${now?.parts} position ${now?.positionMs} ms',
          );
        case 'add-note':
          // add-note <title>|<text>|<minutes ahead>|<reminder|calendar_event|task>: a text note with no
          // audio and one pending suggestion, to try reminders and the calendar without recording
          final bits = args.split('|');
          final title = bits.first.trim().isEmpty
              ? 'Test note'
              : bits.first.trim();
          final minutes =
              int.tryParse(bits.length > 2 ? bits[2].trim() : '') ?? 2;
          final type = bits.length > 3 ? bits[3].trim() : 'reminder';
          final now = DateTime.now();
          final note = CircuitNote(
            id: 'test-${now.microsecondsSinceEpoch}',
            createdAt: now,
            status: 'Ready for review',
            title: title,
            kind: 'text',
            transcript: bits.length > 1 ? bits[1].trim() : title,
            category: type,
            categories: [type],
            summary: title,
            enrichmentStatus: 'ready',
            actionSuggestions: [
              NoteActionSuggestion(
                id: 'test-s-${now.microsecondsSinceEpoch}',
                type: type,
                title: title,
                details: '',
                scheduledAt: type == 'task'
                    ? null
                    : now.add(Duration(minutes: minutes)).toIso8601String(),
              ),
            ],
          );
          final preferences = await SharedPreferences.getInstance();
          final notes = [note, ..._notes];
          await _writeSecret(
            preferences,
            _notesKey,
            jsonEncode(notes.map((item) => item.toJson()).toList()),
          );
          _update(() => _notes = notes);
          await _testLog('add-note ${note.id}');
        case 'notes':
          // what the AI review made of each note: its state, how many transcripts, and its suggestions
          await _testLog(
            'notes ${jsonEncode([
              for (final n in _notes) {
                  'id': n.id,
                  'board': _boardIdOf(n),
                  'title': n.title,
                  'at': n.createdAt.toIso8601String(),
                  'status': n.status,
                  'review': n.enrichmentStatus,
                  'category': n.category,
                  'runs': n.transcriptRuns.length,
                  'suggestions': [for (final a in n.actionSuggestions) '${a.state}:${a.type}:${a.title}:${a.scheduledAt ?? ''}'],
                  'text': (n.transcript ?? '').replaceAll('\n', ' ').substring(0, (n.transcript ?? '').length.clamp(0, 400)),
                },
            ])}',
          );
        case 'add-reminder':
          // add-reminder <title>|<minutes ahead>: a task with a reminder, set without touching the screen
          final bits = args.split('|');
          final minutes =
              int.tryParse(bits.length > 1 ? bits[1].trim() : '') ?? 1;
          final ok = await _addTask(
            bits.first.trim().isEmpty ? 'Test reminder' : bits.first.trim(),
            detail: 'Set by the test command',
            dueAt: DateTime.now().add(Duration(minutes: minutes)),
          );
          await _testLog(
            'add-reminder in $minutes min, notifications allowed: $ok',
          );
        case 'delete-tasks':
          // delete-tasks <text>: every task whose title contains the text (test tasks only)
          final needle = args.trim().toLowerCase();
          if (needle.isEmpty) {
            await _testLog('delete-tasks needs some text from the title');
            return;
          }
          final doomed = [
            for (final t in _tasks)
              if (t.title.toLowerCase().contains(needle)) t.id,
          ];
          for (final id in doomed) {
            await _deleteTask(id);
          }
          await _testLog('delete-tasks removed ${doomed.length} task(s)');
        case 'tasks':
          await _testLog(
            'tasks ${jsonEncode([for (final t in _tasks) t.toJson()])}',
          );
        case 'delete':
          // delete <note id> ...: the app's own ids, as `state` lists them
          var removed = 0;
          for (final id in parts) {
            if (_notes.any((n) => n.id == id)) {
              await _deleteNote(id);
              removed++;
            }
          }
          await _testLog('delete removed $removed note(s)');
        case 'delete-from':
          // delete-from <board number>: every note that came from Circuit with that number or higher
          // (test copies get the highest numbers)
          final limit = int.tryParse(first ?? '');
          if (limit == null) {
            await _testLog('delete-from needs a board number');
            return;
          }
          final doomed = [
            for (final n in _notes)
              if ((_boardIdOf(n) ?? 0) >= limit) n.id,
          ];
          for (final id in doomed) {
            await _deleteNote(id);
          }
          await _testLog('delete-from $limit removed ${doomed.length} note(s)');
        default:
          await _testLog('unknown command $cmd');
      }
    } catch (error) {
      await _testLog('$cmd failed: $error');
    }
  }

  Map<String, dynamic> _testState() => {
    'notes': [
      for (final n in _notes)
        {
          'id': n.id,
          'boardId': _boardIdOf(n),
          'status': n.status,
          'audio': n.audioPath != null,
          'parts': n.audioParts.length,
          'transcript': (n.transcript ?? '').isNotEmpty,
          'isCall': n.isCall,
        },
    ],
    'syncActive': _syncActive,
    'boardWaiting': _boardWaiting,
    'circuitPlayback': _circuitPlayback.name,
    'circuitRecording': _recordingAudio,
    'phoneRecording': _phoneRecordingActive,
  };
}
