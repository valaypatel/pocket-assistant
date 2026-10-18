part of '../main.dart';

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _two(int value) => value.toString().padLeft(2, '0');

/// The battery icon that best matches [percent].
IconData batteryIconFor(int percent) => percent >= 85
    ? LucideIcons.batteryFull
    : percent >= 50
    ? LucideIcons.batteryMedium
    : percent >= 20
    ? LucideIcons.batteryLow
    : LucideIcons.batteryWarning;

String _dayLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  return '${local.day} ${_months[local.month - 1].substring(0, 3)}';
}

/// "Today 4:00 pm", "Tomorrow 9:30 am" or "15 Oct 4:00 pm": when a reminder rings.
String reminderLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final ahead = day.difference(today).inDays;
  final date = switch (ahead) {
    0 => 'Today',
    1 => 'Tomorrow',
    _ => '${local.day} ${_months[local.month - 1].substring(0, 3)}',
  };
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  return '$date $hour:${_two(local.minute)} ${local.hour < 12 ? 'am' : 'pm'}';
}

/// Asks for a day and a time in the future; null when the person backs out.
Future<DateTime?> pickReminderTime(
  BuildContext context, {
  DateTime? initial,
}) async {
  final now = DateTime.now();
  final start = initial != null && initial.isAfter(now)
      ? initial
      : now.add(const Duration(hours: 1));
  final day = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 365 * 3)),
    helpText: 'Remind me on',
  );
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(start),
    helpText: 'Remind me at',
  );
  if (time == null) return null;
  final picked = DateTime(day.year, day.month, day.day, time.hour, time.minute);
  if (!picked.isAfter(now) && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('That time has passed. Pick a time later than now.'),
        ),
      );
    return null;
  }
  return picked;
}

/// What to delete when a note that came from Circuit is deleted in the app.
enum NoteDeleteChoice { everywhere, phoneOnly }

/// Asks before a note is deleted. A note that came from Circuit also lives on Circuit's card, so
/// the person chooses between deleting it everywhere and deleting only the phone's copy.
/// Returns null if they cancel.
Future<NoteDeleteChoice?> _chooseNoteDelete(
  BuildContext context, {
  bool fromCircuit = false,
}) => showDialog<NoteDeleteChoice>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Delete this note?'),
    content: Text(
      fromCircuit
          ? 'It is also on Circuit\'s card. Delete it there too, or keep it on Circuit and remove only the phone copy?'
          : 'This cannot be undone.',
    ),
    actionsOverflowDirection: VerticalDirection.down,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Cancel'),
      ),
      if (fromCircuit)
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, NoteDeleteChoice.phoneOnly),
          child: const Text('Phone only'),
        ),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: context.sc.danger),
        onPressed: () =>
            Navigator.pop(dialogContext, NoteDeleteChoice.everywhere),
        child: Text(fromCircuit ? 'Everywhere' : 'Delete'),
      ),
    ],
  ),
);

extension _ScPages on _CircuitHomePageState {
  Future<bool> _confirmDeleteListNote(CircuitNote note) async {
    final choice = await _chooseNoteDelete(
      context,
      fromCircuit: _boardIdOf(note) != null,
    );
    _pendingDeleteChoice = choice;
    return choice != null;
  }

  /// Circuit is connected right now. The background service merely running does not count:
  /// it also runs while it is still trying, and then nothing can be sent or received.
  bool get _circuitAvailable =>
      _textCharacteristic != null || _relayLink == RelayLink.connected;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 2200),
        ),
      );
  }

  // ---- shared pieces -------------------------------------------------------

  String _wifiHeadline() => switch (_wifiState) {
    'connected' => _wifiSsid.isEmpty ? 'Connected' : _wifiSsid,
    'connecting' => 'Connecting…',
    'failed' => 'Failed',
    // Circuit switched Wi-Fi off to save power (battery below 35%); it comes back for a sync, broadcast or update.
    'resting' => _wifiSsid.isEmpty ? 'Resting' : '$_wifiSsid · resting',
    _ => 'Not set up',
  };

  /// Circuit's IP address while it is on Wi-Fi, else null.
  String? get _wifiIp =>
      _wifiState == 'connected' &&
          RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(_wifiDetail.trim())
      ? _wifiDetail.trim()
      : null;

  String _ago(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return '${seconds ~/ 60} min ago';
    if (seconds < 86400) return '${seconds ~/ 3600} h ago';
    return '${seconds ~/ 86400} d ago';
  }

  /// Shown whenever a sync failed or is stuck, with the reason and a way to retry.
  Widget _syncHealthCard() {
    final error = _syncError;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: context.sc.dangerSoft,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.sc.danger.withValues(alpha: .35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.refreshCwOff,
                  color: context.sc.danger,
                  size: 22,
                ),
                SizedBox(width: 10),
                Text(
                  'Sync stopped',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.sc.danger,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: context.sc.ink,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ScIconButton(
                  icon: LucideIcons.refreshCw,
                  tooltip: 'Retry sync',
                  tone: ScTone.danger,
                  onPressed: _retrySync,
                ),
                const SizedBox(width: 10),
                ScIconButton(
                  icon: LucideIcons.x,
                  tooltip: 'Dismiss sync error',
                  onPressed: () => _update(() => _syncError = null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncBanner() {
    if (_syncingNoteId == null && !_syncActive) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.sc.hero,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.sc.accent,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Syncing a voice note',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${_syncProgress ?? 0}%',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _syncProgress == null ? null : _syncProgress! / 100,
                minHeight: 6,
                color: context.sc.accent,
                backgroundColor: context.sc.bg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- notes ---------------------------------------------------------------

  Widget _captureButton({
    required IconData icon,
    required double iconSize,
    required String label,
    required String tooltip,
    required Color color,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: onTap == null
        ? '$tooltip (Circuit is not connected or busy)'
        : tooltip,
    child: Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? .45 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: iconSize, color: Colors.white),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _openMusicSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const MusicSettingsPage()));
    await _loadMusicState();
  }

  bool _noteNeedsAttention(CircuitNote note) =>
      note.song?.state == 'failed' ||
      note.status.startsWith('No speech detected') ||
      note.status.startsWith('Transcription error') ||
      note.status.startsWith('Sync failed') ||
      note.status.startsWith('Sync interrupted') ||
      note.enrichmentStatus == 'failed' ||
      note.actionSuggestions.any((item) => item.state == 'pending');

  Future<void> _retryEnrichment(String id) async {
    _enrichAttempts.remove(
      id,
    ); // a manual run starts the automatic back-off afresh
    if (!_aiConnected) {
      _setStatus('Add an AI service in Settings before retrying review.');
      return;
    }
    await _enrichNote(id);
  }

  IconData _noteIcon(CircuitNote note) {
    if (_noteNeedsAttention(note)) return LucideIcons.circleAlert;
    if (note.isSong) return LucideIcons.music;
    return switch (note.category) {
      'reminder' || 'task' || 'calendar_event' => LucideIcons.check,
      'idea' => LucideIcons.sparkles,
      'shopping' => LucideIcons.shoppingBag,
      'journal' => LucideIcons.bookOpen,
      _ => note.transcript == null ? LucideIcons.mic : LucideIcons.notebookText,
    };
  }

  /// "0:49" for a note whose audio is on the phone, once its length has been worked out.
  String? _noteLength(CircuitNote note) {
    final files = note.audioFiles;
    if (files.isEmpty) return null;
    final key = '${note.id}:${files.length}';
    final known = _noteLengthMs[key];
    if (known == null) {
      if (_noteLengthLoading.add(key)) {
        unawaited(() async {
          var total = 0;
          for (final path in files) {
            try {
              total += await Moments.partDurationMs(path);
            } catch (_) {
              // a file that cannot be read adds nothing
            }
          }
          _noteLengthLoading.remove(key);
          if (mounted) _update(() => _noteLengthMs[key] = total);
        }());
      }
      return null;
    }
    return known < 1000 ? null : nowPlayingClock(known);
  }

  /// The facts a note card shows under its title: when it was made, how long it is, where it came from.
  List<String> _noteMeta(CircuitNote note) {
    final local = note.createdAt.toLocal();
    final length = _noteLength(note);
    return [
      '${_dayLabel(note.createdAt)} · ${_two(local.hour)}:${_two(local.minute)}',
      ?length,
      note.source,
    ];
  }

  /// This note's own download progress (0 to 100), or null when it is not downloading. Circuit's number for the
  /// note names it exactly; with no per-note figures (an older phone service) the note being synced shows the
  /// overall one.
  int? _noteSyncPercent(CircuitNote note) {
    if (note.audioPath != null) return null;
    if (_noteProgress.isNotEmpty) {
      final id = note.boardId;
      return id == null ? null : _noteProgress[id];
    }
    return note.id == _syncingNoteId ? (_syncProgress ?? 0) : null;
  }

  /// Where the note stands, in a few words; null when there is nothing to add.
  String? _noteStatusText(CircuitNote note) {
    final syncing = _noteSyncPercent(note);
    if (syncing != null) return 'Syncing $syncing%';
    if (note.id == _syncingNoteId && _noteProgress.isEmpty) return 'Syncing';
    final song = note.song;
    if (note.isSong && song != null) {
      if (song.matched) return song.artist;
      if (note.audioPath == null) return 'Waiting to sync';
      return switch (song.state) {
        'no_match' => 'No match found',
        'failed' => 'Identification failed',
        _ => 'Identifying…',
      };
    }
    if (note.id == _transcribingNoteId) return 'Transcribing…';
    if (note.status.startsWith('No speech detected')) return 'No speech found';
    if (note.status.startsWith('Transcription error')) {
      return 'Transcription failed';
    }
    if (note.status.startsWith('Sync failed') ||
        note.status.startsWith('Sync interrupted')) {
      return 'Sync failed';
    }
    if (note.status.startsWith('Waiting for Wi-Fi')) return 'Waiting for Wi-Fi';
    final stage = noteStageLabel(note);
    // The icons at the end of the line already say these.
    const shownByIcons = {
      'Transcribed',
      'AI reviewed',
      'AI reviewing',
      'Ready to transcribe',
    };
    return shownByIcons.contains(stage) ? null : stage;
  }

  VoidCallback? _openNote(CircuitNote note) {
    if (note.isSong) {
      return () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SongPage(
            noteId: note.id,
            noteById: (id) => _notes.where((n) => n.id == id).firstOrNull,
            onIdentify: _identifySongNote,
            onPlay: _playSyncedNote,
            onDelete: _deleteNote,
            onDeletePhoneOnly: _boardIdOf(note) == null
                ? null
                : (id) => _deleteNote(id, phoneOnly: true),
            onOpenSettings: _openMusicSettings,
            onUseAsNote: (id) => _transcribeNote(id, asSpeech: true),
          ),
        ),
      );
    }
    return () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TranscriptPage(
          createdAt: note.createdAt,
          noteId: note.id,
          category: note.category ?? 'note',
          title: note.title ?? 'Voice note',
          status: note.status,
          transcript: note.transcript ?? '',
          onForceTranscribe: _transcribeNote,
          onSyncNote: _syncLatestRecording,
          audioPath: note.audioPath,
          onPlayNote: _playSyncedNote,
          onPlayMoment: _playNoteFrom,
          onDeleteNote: _deleteNote,
          onDeletePhoneOnly: _boardIdOf(note) == null
              ? null
              : (id) => _deleteNote(id, phoneOnly: true),
          onCreateReminder: _extractReminder,
          onAddTask: (title, detail) => _addTask(title, detail: detail),
          onAddReminder: (title, detail, at) =>
              _addTask(title, detail: detail, dueAt: at),
          summary: note.summary,
          englishTranslation: note.englishTranslation,
          language: note.language,
          categories: note.categories,
          tags: note.tags,
          suggestions: note.actionSuggestions,
          onSuggestionState: _setSuggestionState,
          noteById: (id) => _notes.where((n) => n.id == id).firstOrNull,
          onEnrich: _retryEnrichment,
          onEditNote: _editNote,
          onUseRun: _useTranscriptRun,
          isCall: note.isCall,
          onOpenChat: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NoteChatPage(
                noteId: note.id,
                title: note.title ?? 'Voice note',
                loadHistory: _loadNoteChat,
                saveHistory: _saveNoteChat,
                ask: _askAboutNote,
                onAddTask: (title, detail) => _addTask(title, detail: detail),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The one line of status above the notes: the most important thing right now.
  Widget _notesStatusStrip(int arriving) {
    final error = _syncError;
    if (error != null) {
      return ScStatusStrip(
        tone: ScStripTone.danger,
        leading: LucideIcons.refreshCwOff,
        title: 'Sync stopped',
        detail: error,
        actions: [
          TextButton(onPressed: _retrySync, child: const Text('Retry')),
          IconButton(
            tooltip: 'Dismiss sync error',
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: () => _update(() => _syncError = null),
          ),
        ],
      );
    }
    if (_syncingNoteId != null || _syncActive) {
      // Each note shows its own progress bar in its row; the strip only says a sync is running and how far
      // along the list it is. Without per-note figures it keeps the single bar.
      final perNote = _noteProgress.isNotEmpty;
      return ScStatusStrip(
        tone: ScStripTone.progress,
        title: perNote ? 'Syncing from Circuit' : 'Syncing a voice note',
        detail: perNote
            ? (_syncNoteCount > 1
                  ? 'Note $_syncNoteIndex of $_syncNoteCount'
                  : null)
            : '${_syncProgress ?? 0}%',
        showProgress: !perNote,
        progress: _syncProgress == null ? null : _syncProgress! / 100,
      );
    }
    if (_recordingAudio) {
      // Each finished minute of a long recording is a note on Circuit, but nothing syncs until it ends.
      return const ScStatusStrip(
        tone: ScStripTone.neutral,
        leading: LucideIcons.mic,
        title: 'Circuit is recording',
        detail: 'Its notes sync when the recording ends.',
      );
    }
    if (arriving > 0) {
      return ScStatusStrip(
        tone: ScStripTone.neutral,
        leading: LucideIcons.download,
        title: arriving == 1
            ? 'A longer recording is arriving from Circuit'
            : '$arriving longer recordings are arriving from Circuit',
        detail: 'They appear here when all of each is on your phone.',
      );
    }
    if (!_circuitAvailable) {
      return ScStatusStrip(
        tone: ScStripTone.neutral,
        leading: LucideIcons.unplug,
        title: 'Circuit is not connected',
        detail: 'Notes already on your phone are still here.',
        actions: [
          TextButton(
            onPressed: () => _goTo(_AppPage.circuit),
            child: const Text('Open Circuit'),
          ),
        ],
      );
    }
    final waiting = _waitingCount;
    if (waiting > 0) {
      return ScStatusStrip(
        tone: ScStripTone.neutral,
        leading: LucideIcons.refreshCw,
        title: waiting == 1
            ? '1 note is waiting on Circuit'
            : '$waiting notes are waiting on Circuit',
        actions: [
          TextButton(onPressed: _retrySync, child: const Text('Sync now')),
        ],
      );
    }
    return const ScStatusStrip(
      tone: ScStripTone.good,
      leading: LucideIcons.circleCheck,
      title: 'Circuit is connected and everything is synced',
    );
  }

  /// The two steps a spoken note goes through, as icons: transcribed, then AI reviewed. Each shows where
  /// the step stands and runs it when tapped. Songs and notes not yet on the phone have none.
  List<Widget> _noteStepIcons(CircuitNote note) {
    if (note.isSong || note.audioPath == null) return const [];
    final hasTranscript = (note.transcript ?? '').trim().isNotEmpty;
    final transcribing = _transcribingNoteId == note.id;
    final reviewing = note.enrichmentStatus == 'enriching';
    return [
      ScStateIcon(
        icon: LucideIcons.languages,
        label: transcribing
            ? 'Transcribing'
            : hasTranscript
            ? 'Transcribed. Tap to transcribe again'
            : 'Transcribe',
        state: transcribing
            ? ScStepState.busy
            : hasTranscript
            ? ScStepState.done
            : ScStepState.todo,
        onPressed: _transcribingNoteId != null
            ? null
            : () async {
                final result = await _transcribeNote(note.id);
                if (!mounted || result == null) return;
                final updated = _notes
                    .where((n) => n.id == note.id)
                    .firstOrNull;
                final open = updated == null ? null : _openNote(updated);
                open?.call();
              },
      ),
      // The review reads the transcript, so there is nothing to offer before one exists.
      if (hasTranscript)
        ScStateIcon(
          icon: LucideIcons.sparkles,
          label: reviewing
              ? 'AI reviewing'
              : note.enrichmentStatus == 'ready'
              ? 'AI reviewed. Tap to review again'
              : note.enrichmentStatus == 'failed'
              ? 'Retry AI review'
              : 'Run AI review',
          state: reviewing
              ? ScStepState.busy
              : note.enrichmentStatus == 'ready'
              ? ScStepState.done
              : note.enrichmentStatus == 'failed'
              ? ScStepState.failed
              : ScStepState.todo,
          onPressed: () => _retryEnrichment(note.id),
        ),
    ];
  }

  Widget _noteTile(CircuitNote note, {bool actions = false}) {
    final attention = _noteNeedsAttention(note);
    final syncPercent = _noteSyncPercent(note);
    final needsSync =
        note.audioPath == null && !note.isText && syncPercent == null;
    final footerButtons = <Widget>[
      if (actions &&
          note.isSong &&
          note.audioPath != null &&
          note.song != null &&
          !note.song!.matched &&
          !note.song!.busy)
        ScActionChip(
          icon: LucideIcons.refreshCw,
          label: 'Identify again',
          onPressed: () => _identifySongNote(note.id),
        ),
      if (actions && needsSync)
        ScActionChip(
          icon: LucideIcons.refreshCw,
          label: 'Sync now',
          onPressed: () => _syncLatestRecording(note.id),
        ),
    ];
    return ScTile(
      icon: _noteIcon(note),
      title: note.isSong
          ? (note.song?.title ?? 'Song identification')
          : note.title ??
                (note.audioPath == null ? 'Voice recording' : 'Voice note'),
      meta: _noteMeta(note),
      status: _noteStatusText(note),
      statusTrailing: _noteStepIcons(note),
      statusIcon: attention ? LucideIcons.circleAlert : null,
      statusColor: attention
          ? context.sc.danger
          : (syncPercent != null || note.id == _transcribingNoteId)
          ? context.sc.accentInk
          : null,
      badge: NoteSourceBadge(source: note.source),
      onTap: _openNote(note),
      trailing: ScPlayButton(
        onPressed: note.audioPath == null
            ? null
            : () => _playSyncedNote(note.audioPath),
      ),
      footer: syncPercent != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: syncPercent / 100,
                minHeight: 5,
                color: context.sc.accent,
                backgroundColor: context.sc.line,
              ),
            )
          : footerButtons.isEmpty
          ? null
          : Wrap(spacing: 8, runSpacing: 8, children: footerButtons),
    );
  }

  /// One capture entry point, with an explicit microphone/device choice.
  Future<void> _showCaptureOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.sc.bg,
      builder: (sheetContext) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ScEyebrow('Capture'),
            const SizedBox(height: 8),
            const ScTitle('Where’s the thought?'),
            const SizedBox(height: 8),
            Text(
              'Choose where to record.',
              style: TextStyle(color: context.sc.muted, fontSize: 15),
            ),
            const SizedBox(height: 20),
            ScTile(
              icon: LucideIcons.smartphone,
              title: 'This phone',
              subtitle: 'Record directly into your notes. No Circuit needed.',
              onTap: () {
                Navigator.pop(sheetContext);
                _startPhoneRecording();
              },
              trailing: const Icon(LucideIcons.chevronRight, size: 18),
            ),
            ScTile(
              icon: LucideIcons.radio,
              title: 'Circuit',
              subtitle: _boardWorksAlone
                  ? 'Press Circuit’s record key. It works on its own.'
                  : _circuitAvailable
                  ? 'Record on your connected device.'
                  : 'Connect Circuit to use its microphone.',
              onTap: _boardWorksAlone
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      if (_circuitAvailable) {
                        _recordAudio();
                      } else {
                        _goTo(_AppPage.circuit);
                      }
                    },
              trailing: const Icon(LucideIcons.chevronRight, size: 18),
            ),
            ScTile(
              icon: LucideIcons.music,
              title: 'Identify a song',
              subtitle: _boardWorksAlone
                  ? 'Not available while Circuit works on its own.'
                  : _circuitAvailable
                  ? 'Capture a short clip on Circuit.'
                  : 'Connect Circuit to capture a song.',
              onTap: _boardWorksAlone
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      if (_circuitAvailable) {
                        _identifySong();
                      } else {
                        _goTo(_AppPage.circuit);
                      }
                    },
              trailing: const Icon(LucideIcons.chevronRight, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  // ---- notes tab -----------------------------------------------------------

  List<Widget> _notesPage() {
    final query = _noteSearchController.text.trim().toLowerCase();
    // A long recording still collecting its parts is not shown, or counted, until it is whole.
    final shownNotes = _notes.where((note) => !note.isArriving).toList();
    final arriving = _notes.length - shownNotes.length;
    final inSource = shownNotes
        .where((note) => noteMatchesSource(note, _noteSource))
        .toList();
    final visibleNotes = query.isEmpty
        ? inSource
        : inSource.where((note) {
            final searchable = [
              note.title,
              note.transcript,
              note.summary,
              note.englishTranslation,
              note.category,
              ...note.categories,
              ...note.tags,
              ...note.actionSuggestions.map((item) => item.title),
              ...note.actionSuggestions.map((item) => item.details),
            ].whereType<String>().join(' ').toLowerCase();
            return searchable.contains(query);
          }).toList();
    // Review items are displayed in the queue above; exclude them from the
    // library list so a recording never appears as two cards.
    final libraryNotes =
        visibleNotes.where((note) => !_noteNeedsAttention(note)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final now = DateTime.now();
    return [
      if (_selecting)
        _selectionHeader()
      else
        Row(
          children: [
            const Expanded(child: ScTitle('Notes')),
            ScIconButton(
              size: 44,
              icon: LucideIcons.search,
              tooltip: 'Search notes',
              onPressed: () => _update(() => _searchOpen = true),
            ),
            const SizedBox(width: ScSpace.xs),
            ScIconButton(
              size: 44,
              icon: LucideIcons.listChecks,
              tooltip: 'Select notes to group',
              onPressed: _startSelecting,
            ),
          ],
        ),
      const SizedBox(height: 12),
      if (_searchOpen || query.isNotEmpty) ...[
        TextField(
          controller: _noteSearchController,
          autofocus: query.isEmpty,
          onChanged: (_) => _update(() {}),
          decoration: InputDecoration(
            hintText: 'Search notes, transcripts, tags',
            prefixIcon: const Icon(LucideIcons.search, size: 18),
            suffixIcon: IconButton(
              tooltip: 'Close search',
              icon: const Icon(LucideIcons.x, size: 18),
              onPressed: () => _update(() {
                _noteSearchController.clear();
                _searchOpen = false;
              }),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      _notesStatusStrip(arriving),
      if (shownNotes.isNotEmpty) ...[
        const SizedBox(height: 12),
        NoteSourceFilter(
          selected: _noteSource,
          counts: {
            noteSourceAll: shownNotes.length,
            'Phone': shownNotes.where((n) => n.source == 'Phone').length,
            'Circuit': shownNotes.where((n) => n.source == 'Circuit').length,
          },
          onChanged: (choice) => _update(() => _noteSource = choice),
        ),
      ],
      const SizedBox(height: 12),
      _groupsRow(),
      if (visibleNotes.any(_noteNeedsAttention)) ...[
        const SizedBox(height: 18),
        const ScGroupLabel('Needs attention'),
        for (final note in visibleNotes.where(_noteNeedsAttention).take(5)) ...[
          _selectableNote(
            note,
            Dismissible(
              key: ValueKey('review-${note.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: context.sc.dangerSoft,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(LucideIcons.trash2, color: context.sc.danger),
              ),
              confirmDismiss: (_) => _confirmDeleteListNote(note),
              onDismissed: (_) => _deleteNote(
                note.id,
                phoneOnly: _pendingDeleteChoice == NoteDeleteChoice.phoneOnly,
              ),
              child: _noteTile(note, actions: true),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 10),
      ],
      if (visibleNotes.isEmpty)
        ScTile(
          icon: LucideIcons.mic,
          title: query.isNotEmpty
              ? 'Nothing matches “${_noteSearchController.text.trim()}”'
              : _notes.isEmpty
              ? 'No notes yet'
              : 'No $_noteSource notes',
          subtitle: query.isNotEmpty
              ? 'Try another word or a tag.'
              : _notes.isEmpty
              ? 'Tap Record, or press the button on Circuit.'
              : 'Choose All to see every note.',
        )
      else
        for (final (index, note) in libraryNotes.indexed) ...[
          if (index == 0 ||
              noteAge(note.createdAt.toLocal(), now) !=
                  noteAge(
                    libraryNotes[index - 1].createdAt.toLocal(),
                    now,
                  )) ...[
            if (index > 0) const SizedBox(height: 8),
            ScGroupLabel(noteAge(note.createdAt.toLocal(), now).label),
          ],
          _selectableNote(
            note,
            Dismissible(
              key: ValueKey(note.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: context.sc.dangerSoft,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(LucideIcons.trash2, color: context.sc.danger),
              ),
              confirmDismiss: (_) => _confirmDeleteListNote(note),
              onDismissed: (_) => _deleteNote(
                note.id,
                phoneOnly: _pendingDeleteChoice == NoteDeleteChoice.phoneOnly,
              ),
              child: _noteTile(note),
            ),
          ),
          const SizedBox(height: 10),
        ],
    ];
  }

  // ---- tasks tab -----------------------------------------------------------

  Future<void> _promptAddTask() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New task'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'What needs doing?'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: scDialogActions(
          dialogContext,
          confirmIcon: LucideIcons.plus,
          confirmTooltip: 'Add task',
          onConfirm: () => Navigator.pop(dialogContext, controller.text),
        ),
      ),
    );
    controller.dispose();
    if (title != null && title.trim().isNotEmpty) await _addTask(title.trim());
  }

  /// Sets, changes or clears a task's reminder from its bell.
  Future<void> _editReminder(CircuitTask task) async {
    final due = task.dueAt;
    final hasFuture = due != null && due.isAfter(DateTime.now());
    final choice = hasFuture
        ? await showModalBottomSheet<String>(
            context: context,
            builder: (sheet) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(LucideIcons.clock),
                    title: const Text('Change time'),
                    subtitle: Text(reminderLabel(due)),
                    onTap: () => Navigator.pop(sheet, 'change'),
                  ),
                  ListTile(
                    leading: const Icon(LucideIcons.bellOff),
                    title: const Text('Remove reminder'),
                    onTap: () => Navigator.pop(sheet, 'clear'),
                  ),
                ],
              ),
            ),
          )
        : 'change';
    if (!mounted || choice == null) return;
    if (choice == 'clear') {
      await _setTaskDue(task.id, null);
      return;
    }
    final picked = await pickReminderTime(context, initial: due);
    if (picked == null || !mounted) return;
    final allowed = await _setTaskDue(task.id, picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            allowed ? 'Reminder set for ${reminderLabel(picked)}.' : 'Notifications are off for Circuit. Turn them on in Android settings to hear reminders.',
          ),
        ),
      );
  }

  Widget _taskRow(CircuitTask task) => Dismissible(
    key: ValueKey(task.id),
    direction: DismissDirection.endToStart,
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 8),
      child: Icon(LucideIcons.trash2, color: context.sc.danger),
    ),
    onDismissed: (_) => _deleteTask(task.id),
    child: InkWell(
      onTap: () => _toggleTask(task.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.sc.line)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: task.done,
              activeColor: context.sc.accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
              onChanged: (_) => _toggleTask(task.id),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      decoration: task.done ? TextDecoration.lineThrough : null,
                      color: task.done ? context.sc.muted : context.sc.ink,
                    ),
                  ),
                  if (task.detail != null && task.detail!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      task.detail!,
                      style: TextStyle(fontSize: 11, color: context.sc.muted),
                    ),
                  ],
                  if (task.dueAt != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      '${task.done || task.dueAt!.isAfter(DateTime.now()) ? 'Reminder' : 'Was due'} · ${reminderLabel(task.dueAt!)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color:
                            !task.done && !task.dueAt!.isAfter(DateTime.now())
                            ? context.sc.danger
                            : context.sc.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!task.done)
              IconButton(
                tooltip: task.dueAt == null
                    ? 'Set a reminder'
                    : 'Change reminder',
                onPressed: () => _editReminder(task),
                icon: Icon(
                  task.dueAt == null ? LucideIcons.bell : LucideIcons.bellRing,
                  size: 18,
                  color: task.dueAt == null
                      ? context.sc.muted
                      : context.sc.accent,
                ),
              ),
            IconButton(
              tooltip: 'Delete task',
              onPressed: () => _deleteTask(task.id),
              icon: Icon(LucideIcons.trash2, size: 18, color: context.sc.muted),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _tasksPage() {
    // Tasks with a time come first, soonest first; the rest keep newest-first order.
    final open = _tasks.where((t) => !t.done).toList()
      ..sort((a, b) {
        if (a.dueAt == null && b.dueAt == null) return 0;
        if (a.dueAt == null) return 1;
        if (b.dueAt == null) return -1;
        return a.dueAt!.compareTo(b.dueAt!);
      });
    final done = _tasks.where((t) => t.done).toList();
    return [
      Row(children: [const Expanded(child: ScTitle('Tasks'))]),
      const SizedBox(height: 8),
      Text(
        'Turn a thought into a next step.',
        style: TextStyle(color: context.sc.muted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 24),
      const ScGroupLabel('To do'),
      if (open.isEmpty)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            'Nothing to do right now. Add a task with the button below, or approve a suggested action on a note. The bell on a task rings a reminder.',
            style: ScType.caption.copyWith(color: context.sc.muted),
          ),
        ),
      for (final task in open) _taskRow(task),
      if (done.isNotEmpty) ...[
        const SizedBox(height: 22),
        const ScGroupLabel('Done'),
        for (final task in done) _taskRow(task),
      ],
    ];
  }

  // ---- settings tab --------------------------------------------------------

  List<Widget> _settingsPage() => [
    const SizedBox(height: ScSpace.sm),
    Semantics(header: true, child: Text('Settings', style: ScType.display)),
    const SizedBox(height: ScSpace.xl),
    ScTile(
      icon: LucideIcons.cpu,
      title: 'Circuit',
      subtitle: _circuitAvailable ? 'Connected' : 'Not connected',
      trailing: const Icon(LucideIcons.chevronRight, size: 18),
      onTap: () => _selectTab(2),
    ),
    const SizedBox(height: ScSpace.xl),
    const ScGroupLabel('Appearance'),
    SegmentedButton<ThemeMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: ThemeMode.system,
          icon: Icon(LucideIcons.smartphone, size: 16),
          label: Text('Phone'),
        ),
        ButtonSegment(
          value: ThemeMode.light,
          icon: Icon(LucideIcons.sun, size: 16),
          label: Text('Light'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: Icon(LucideIcons.moon, size: 16),
          label: Text('Dark'),
        ),
      ],
      selected: {appThemeMode.value},
      onSelectionChanged: (choice) => _setThemeMode(choice.first),
    ),
    const SizedBox(height: ScSpace.xl),
    const ScGroupLabel('AI and notes'),
    ScTile(
      icon: LucideIcons.languages,
      title: 'Google Gemini',
      subtitle: _geminiConnected
          ? 'Transcription · API key saved'
          : 'Add an API key to transcribe notes',
      trailing: const Icon(LucideIcons.chevronRight, size: 18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const GeminiSettingsPage()),
        );
        if (mounted) await _loadGeminiState();
      },
    ),
    ScTile(
      icon: LucideIcons.sparkles,
      title: 'AI service',
      subtitle: _aiConnected
          ? 'Summaries, actions and chat · Ready'
          : 'Connect your service for summaries and chat',
      trailing: const Icon(LucideIcons.chevronRight, size: 18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const AiServiceSettingsPage(),
          ),
        );
        if (mounted) await _loadAiState();
      },
    ),
    ScTile(
      icon: LucideIcons.music,
      title: 'Music recognition',
      subtitle: _musicConnected
          ? 'Your recognition service · Ready'
          : 'Connect your recognition service',
      trailing: const Icon(LucideIcons.chevronRight, size: 18),
      onTap: _openMusicSettings,
    ),
    ScRow(
      title: 'Transcribe new notes',
      caption: 'Start automatically after a note syncs',
      trailing: Switch(value: _autoTranscribe, onChanged: _setAutoTranscribe),
    ),
    ScRow(
      title: 'Review new notes',
      caption: _aiConnected
          ? 'Add a title, summary, tags and suggested actions after a note is transcribed'
          : 'Needs an AI service above. Add one to review notes automatically',
      trailing: Switch(value: _autoEnrich, onChanged: _setAutoEnrich),
    ),
    ScRow(
      title: 'Use Moments',
      caption: 'Mark the bookmarks you tapped on Circuit in the transcript, and give them extra weight in the review',
      trailing: Switch(value: _useMoments, onChanged: _setUseMoments),
    ),
    const SizedBox(height: ScSpace.xl),
    const ScGroupLabel('Backup'),
    ScRow(
      title: 'Back up and restore',
      caption: 'One encrypted file, opened with a passphrase you choose',
      trailing: Icon(
        LucideIcons.chevronRight,
        size: 18,
        color: context.sc.accent,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BackupPage(onRestored: _afterBackupRestore),
        ),
      ),
    ),
    if (Telemetry.available) ...[
      const SizedBox(height: ScSpace.xl),
      const ScGroupLabel('Privacy'),
      ScRow(
        title: 'Share crash reports and usage',
        caption: 'Counts and errors only. Never your notes or what they say',
        trailing: Switch(
          value: _shareDiagnostics,
          onChanged: _setShareDiagnostics,
        ),
      ),
    ],
    const SizedBox(height: ScSpace.xl),
    ScRow(
      title: 'Developer',
      caption: 'Test mode and diagnostics, for testing the app',
      trailing: Icon(
        _developerOpen ? LucideIcons.chevronUp : LucideIcons.chevronDown,
        size: 18,
        color: context.sc.muted,
      ),
      onTap: () => _update(() => _developerOpen = !_developerOpen),
    ),
    if (_developerOpen) ...[
      ScRow(
        title: 'Test mode',
        caption: 'Lets a computer start syncs, playback and recordings over USB or Wi-Fi debugging',
        trailing: Switch(value: _testMode, onChanged: _setTestMode),
      ),
      if (Telemetry.available)
        ScRow(
          title: 'Send a test report',
          caption: 'Check that reports reach Firebase',
          onTap: _sendTestReport,
        ),
    ],
    const SizedBox(height: ScSpace.xxl),
    Row(
      children: [
        const ScBrandMark(size: 40),
        const SizedBox(width: ScSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Short-Circuit', style: ScType.label),
              Text(
                'Voice notes from Circuit, on your phone.',
                style: ScType.caption.copyWith(color: context.sc.muted),
              ),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: ScSpace.md),
  ];

  // ---- Circuit device page -------------------------------------------------

  Future<void> _forgetCircuit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget this Circuit?'),
        content: const Text(
          'The phone will stop connecting to it. You can pair it again by scanning.',
        ),
        actions: scDialogActions(
          dialogContext,
          confirmIcon: LucideIcons.unlink,
          confirmTooltip: 'Forget this Circuit',
          danger: true,
          onCancel: () => Navigator.pop(dialogContext, false),
          onConfirm: () => Navigator.pop(dialogContext, true),
        ),
      ),
    );
    if (confirmed != true) return;
    if (_relayActive) await _stopPhoneRelay();
    await _device?.disconnect();
    // Forget means forget: also drop Android's pairing record, which Samsung's own
    // Bluetooth settings do not list for this kind of device.
    final forgetId = _savedCircuitId ?? _device?.remoteId.str;
    if (forgetId != null) {
      await _removeAndroidPairing(BluetoothDevice.fromId(forgetId));
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_savedCircuitIdKey);
    if (!mounted) return;
    _update(() {
      _savedCircuitId = null;
      _needsPairingRepair = false;
      _device = null;
      _textCharacteristic = null;
      _relayCharacteristic = null;
      _relayActive = false;
      _relayLink = RelayLink.off;
      _wifiState = 'none';
      _status = 'Circuit forgotten. Scan to pair again.';
    });
    _toast('Circuit forgotten');
  }

  /// The Circuit tab. One status card says whether it is connected and what is waiting; below it only
  /// what can be done right now (connect, or record and manage), and the technical details are folded away.
  /// "Battery 85%" with an icon that follows the charge; red when it is nearly flat.
  Widget _batteryLine(int percent) {
    final low = percent <= 15;
    final color = low ? context.sc.danger : context.sc.muted;
    return Semantics(
      label: 'Circuit battery $percent percent${low ? ', low' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(batteryIconFor(percent), size: 16, color: color),
          const SizedBox(width: ScSpace.xs),
          Flexible(
            child: Text(
              'Battery $percent%${low ? ' · charge soon' : ''}',
              style: ScType.caption.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  /// What Circuit runs now, for the Update row.
  /// An update needs 30% battery; unknown (not reported yet) is let through, the board checks as well.
  bool get _updateBatteryOk =>
      _boardBattery == null || _boardBattery! >= BoardReport.minUpdatePercent;

  /// "Last seen 2 h ago · battery 90% · firmware 3.0.0": the figures from the last time Circuit was reachable.
  String _lastBoardLine(({int? battery, String? version, DateTime at}) board) {
    return [
      'Last seen ${_ago(board.at)}',
      if (board.battery != null) '${board.battery}%',
    ].join(' · ');
  }

  String _firmwareCaption() {
    if (!_updateBatteryOk) {
      return 'Needs ${BoardReport.minUpdatePercent}% battery · Circuit has $_boardBattery%';
    }
    final running = _boardFirmware;
    return running == null
        ? 'Choose a firmware file to install'
        : 'Firmware ${running.version} · choose a file to install';
  }

  /// "Power: Deep (battery below 35%)", red when Circuit only records.
  Widget _powerLine(({String mode, String choice}) power) {
    final recordOnly = power.mode == 'rec';
    final color = recordOnly ? context.sc.danger : context.sc.muted;
    final text = switch (power.mode) {
      'rec' => 'Battery very low · Circuit only records, charge it to sync',
      'deep' =>
        power.choice == 'deep'
            ? 'Power: Deep (your choice)'
            : 'Power: Deep (battery below 35%)',
      _ => 'Power: Saver',
    };
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            recordOnly ? LucideIcons.batteryWarning : LucideIcons.leaf,
            size: 16,
            color: color,
          ),
          const SizedBox(width: ScSpace.xs),
          Flexible(
            child: Text(text, style: ScType.caption.copyWith(color: color)),
          ),
        ],
      ),
    );
  }

  /// "Card 3.1 GB of 29.7 GB used", red when it is nearly full.
  Widget _storageLine(({int usedKb, int totalKb}) card) {
    final full = card.usedKb / card.totalKb > 0.9;
    final color = full ? context.sc.danger : context.sc.muted;
    final text = 'Card ${BoardReport.describeStorage(card)}';
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.hardDrive, size: 16, color: color),
          const SizedBox(width: ScSpace.xs),
          Flexible(
            child: Text(
              '$text${full ? ' · free up space' : ''}',
              style: ScType.caption.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _circuitPage() {
    final available = _circuitAvailable;
    final waiting = _waitingCount;
    final idle =
        available &&
        !_audioBusy &&
        !_recordingAudio &&
        _circuitPlayback == CircuitPlaybackPhase.idle;
    final asleep = !available && _boardWorksAlone && _savedCircuitId != null;
    final headline = asleep
        ? 'Working on its own'
        : available
        ? (_boardWorksAlone
              ? 'Sync mode'
              : _relayActive
              ? 'Connected through your phone'
              : 'Connected over Bluetooth')
        : _needsPairingRepair
        ? 'Pairing needs repair'
        : _savedCircuitId != null
        ? 'Not connected'
        : 'No Circuit paired yet';
    final detail = _recordingAudio
        ? 'Recording. Its notes sync when it ends.'
        : !available
        ? (_savedCircuitId == null
              ? 'Scan to find your Circuit and bring your thoughts here.'
              : _boardWorksAlone
              ? 'Hold its record key for 5 s to sync.'
              : 'Turn Circuit on and keep it close.')
        : [
            waiting == 0 ? 'Everything is synced' : '$waiting waiting to sync',
            if (_lastSyncOk != null) 'last sync ${_ago(_lastSyncOk!)}',
          ].join(' · ');
    return [
      // Reached from the Circuit tab there is nowhere to go back to; from a page that sent you here, back goes there.
      if (_pageHistory.isNotEmpty)
        ScBackRow(
          label: _pageHistory.last == _AppPage.settings ? 'Settings' : 'Back',
          onBack: _goBack,
          eyebrow: 'Circuit',
        ),
      const ScTitle('Circuit'),
      const SizedBox(height: ScSpace.lg),
      ScPanel(
        color: context.sc.circuitCard,
        child: Semantics(
          container: true,
          liveRegion: true,
          child: Row(
            children: [
              const ScDeviceMark(size: 56),
              const SizedBox(width: ScSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          available
                              ? LucideIcons.circleCheck
                              : asleep
                              ? LucideIcons.moon
                              : LucideIcons.bluetoothOff,
                          size: 18,
                          color: available
                              ? context.sc.green
                              : context.sc.muted,
                        ),
                        const SizedBox(width: ScSpace.sm),
                        Expanded(
                          child: Text(
                            headline,
                            style: ScType.body.copyWith(
                              fontWeight: FontWeight.w600,
                              color: context.sc.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ScSpace.xs),
                    Text(
                      detail,
                      style: ScType.caption.copyWith(color: context.sc.muted),
                    ),
                    if (!available && _lastBoard != null) ...[
                      const SizedBox(height: ScSpace.xs),
                      Text(
                        _lastBoardLine(_lastBoard!),
                        style: ScType.caption.copyWith(color: context.sc.muted),
                      ),
                    ],
                    if (available && _boardBattery != null) ...[
                      const SizedBox(height: ScSpace.xs),
                      _batteryLine(_boardBattery!),
                    ],
                    if (available && _boardStorage != null) ...[
                      const SizedBox(height: ScSpace.xs),
                      _storageLine(_boardStorage!),
                    ],
                    if (available &&
                        _boardPower != null &&
                        !_boardWorksAlone) ...[
                      const SizedBox(height: ScSpace.xs),
                      _powerLine(_boardPower!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: ScSpace.lg),
      _syncHealthCard(),
      _syncBanner(),
      if (!available) ...[
        if (_needsPairingRepair)
          ScButton(
            primary: true,
            icon: LucideIcons.link,
            label: 'Repair pairing',
            onPressed: _connecting ? null : _repairPairing,
          )
        else if (_savedCircuitId != null) ...[
          ScButton(
            primary: true,
            icon: asleep ? LucideIcons.search : LucideIcons.rotateCw,
            label: asleep ? 'Look for Circuit' : 'Reconnect',
            onPressed: _connecting
                ? null
                : () => _connect(
                    BluetoothDevice.fromId(_savedCircuitId!),
                    savedReconnect: true,
                  ),
          ),
          if (!asleep) ...[
            const SizedBox(height: ScSpace.sm),
            ScButton(
              icon: LucideIcons.bluetoothSearching,
              label: _scanning ? 'Scanning…' : 'Scan for Circuit',
              busy: _scanning,
              onPressed: _connecting ? null : _scan,
            ),
          ],
        ] else
          ScButton(
            primary: true,
            icon: LucideIcons.bluetoothSearching,
            label: _scanning ? 'Scanning…' : 'Scan for Circuit',
            busy: _scanning,
            onPressed: _connecting ? null : _scan,
          ),
        const SizedBox(height: ScSpace.md),
        for (final result in _circuits.values) ...[
          ScTile(
            icon: LucideIcons.cpu,
            title: _circuitName,
            subtitle: '${result.device.remoteId.str} · ${result.rssi} dBm',
            trailing: ScIconButton(
              size: 40,
              icon: LucideIcons.link,
              tooltip: 'Connect to $_circuitName',
              tone: ScTone.primary,
              onPressed: _connecting
                  ? null
                  : () => _connect(result.device, userRequestedPairing: true),
            ),
          ),
          const SizedBox(height: ScSpace.md),
        ],
      ] else ...[
        if (!_boardWorksAlone)
          Row(
            children: [
              Expanded(
                child: _captureButton(
                  icon: LucideIcons.circle,
                  iconSize: 11,
                  label: 'Record',
                  tooltip: 'Record a voice note on Circuit',
                  color: context.sc.accent,
                  onTap: idle ? _recordAudio : null,
                ),
              ),
              const SizedBox(width: ScSpace.md),
              Expanded(
                child: _captureButton(
                  icon: LucideIcons.music,
                  iconSize: 15,
                  label: 'Identify song',
                  tooltip:
                      'Listen for $_songClipSeconds seconds and identify the song',
                  color: context.sc.dark,
                  onTap: idle ? _identifySong : null,
                ),
              ),
            ],
          ),
        if (waiting > 0 && !_syncActive && !_recordingAudio) ...[
          const SizedBox(height: ScSpace.md),
          ScButton(
            icon: LucideIcons.refreshCw,
            label: 'Sync $waiting ${waiting == 1 ? 'note' : 'notes'} now',
            onPressed: _retrySync,
          ),
        ],
        if (_circuitPlaybackFeedback != null) ...[
          const SizedBox(height: ScSpace.md),
          Semantics(
            liveRegion: true,
            child: Text(
              _circuitPlaybackFeedback!,
              style: ScType.caption.copyWith(color: context.sc.ink),
            ),
          ),
        ],
        const SizedBox(height: ScSpace.xl),
        const ScGroupLabel('On Circuit'),
        if (!_boardWorksAlone)
          Tooltip(
            message: switch (_circuitPlayback) {
              CircuitPlaybackPhase.playing =>
                _circuitPlaybackSupportsStop
                    ? 'Stop playback on Circuit'
                    : 'Playing on Circuit',
              _ => 'Play latest recording on Circuit',
            },
            child: ScRow(
              title: _circuitPlayback == CircuitPlaybackPhase.playing
                  ? (_circuitPlaybackSupportsStop
                        ? 'Stop playback'
                        : 'Playing on Circuit')
                  : 'Play latest recording',
              caption: 'Plays through Circuit’s speaker',
              onTap: _audioBusy || _recordingAudio
                  ? null
                  : _circuitPlayback == CircuitPlaybackPhase.playing
                  ? (_circuitPlaybackSupportsStop ? _stopCircuitPlayback : null)
                  : _circuitPlayback == CircuitPlaybackPhase.idle
                  ? _playAudio
                  : null,
              trailing:
                  _circuitPlayback == CircuitPlaybackPhase.requesting ||
                      _circuitPlayback == CircuitPlaybackPhase.stopping
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _circuitPlayback == CircuitPlaybackPhase.playing
                          ? LucideIcons.square
                          : LucideIcons.play,
                      size: 18,
                      color: context.sc.muted,
                    ),
            ),
          ),
        if (!_boardWorksAlone)
          ScRow(
            title: 'Broadcast a message',
            caption: 'Type it and Circuit says it out loud',
            onTap: idle && !_broadcasting && _boardPower?.mode != 'rec'
                ? _broadcastToCircuit
                : null,
            trailing: _broadcasting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    LucideIcons.megaphone,
                    size: 18,
                    color: context.sc.muted,
                  ),
          ),
        ScRow(
          title: 'Update Circuit',
          caption: _firmwareCaption(),
          onTap:
              idle &&
                  !_updatingFirmware &&
                  _boardPower?.mode != 'rec' &&
                  _updateBatteryOk
              ? _updateCircuitFirmware
              : null,
          trailing: _updatingFirmware
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(LucideIcons.download, size: 18, color: context.sc.muted),
        ),
        ScRow(
          title: 'Reset Circuit firmware',
          caption: 'Go back to the previous firmware, or the stable one',
          onTap: idle && !_updatingFirmware && _boardPower?.mode != 'rec'
              ? _resetCircuitFirmware
              : null,
          trailing: Icon(
            LucideIcons.rotateCcw,
            size: 18,
            color: context.sc.muted,
          ),
        ),
        if (!_boardWorksAlone)
          ScRow(
            title: 'Power mode',
            caption: switch (_boardPower?.choice) {
              'saver' => 'Saver (your choice)',
              'deep' => 'Deep (your choice)',
              _ => 'Auto: Circuit decides from its battery',
            },
            onTap: available ? _choosePowerMode : null,
            trailing: Icon(LucideIcons.leaf, size: 18, color: context.sc.muted),
          ),
        ScRow(
          title: 'Free up space',
          caption: 'Remove notes already saved on your phone',
          onTap: idle ? _cleanCircuitNotes : null,
        ),
        ScRow(
          title: 'Send old notes again',
          caption: 'If a note is missing on your phone',
          onTap: idle ? _resendCircuitNotes : null,
        ),
      ],
      const SizedBox(height: ScSpace.xl),
      const ScGroupLabel('Connection'),
      ScRow(
        title: 'Wi‑Fi',
        caption: 'Used to sync notes quickly',
        value: _wifiHeadline(),
        valueColor: _wifiState == 'connected'
            ? context.sc.green
            : _wifiState == 'failed'
            ? context.sc.danger
            : null,
        onTap: available ? () => _goTo(_AppPage.wifi) : null,
      ),
      if (!_boardWorksAlone)
        ScRow(
          title: 'Stay connected',
          caption: _relayActive
              ? 'Circuit stays linked in the background. Tap to turn off.'
              : 'Keeps Circuit linked in the background',
          value: _relayActive ? 'On' : 'Off',
          valueColor: _relayActive ? context.sc.green : context.sc.muted,
          onTap: _relayActive ? _stopPhoneRelay : null,
        ),
      if (_textCharacteristic != null)
        ScRow(title: 'Disconnect', onTap: () => _device?.disconnect()),
      if (_savedCircuitId != null) ...[
        const SizedBox(height: ScSpace.md),
        ScRow(
          title: 'Details',
          caption: 'Addresses, encryption and restarts',
          onTap: () =>
              _update(() => _circuitDetailsOpen = !_circuitDetailsOpen),
          trailing: Icon(
            _circuitDetailsOpen
                ? LucideIcons.chevronUp
                : LucideIcons.chevronDown,
            size: 18,
            color: context.sc.muted,
          ),
        ),
        if (_circuitDetailsOpen) ...[
          if (_boardReset != null && !{1, 3, 11}.contains(_boardReset))
            ScRow(
              title: 'Last restart',
              caption: _boardUptime < 3600
                  ? 'Circuit restarted ${_boardUptime ~/ 60} min ago'
                  : 'Reason Circuit last restarted',
              value: _resetReasonText(_boardReset!),
              valueColor: const {4, 5, 6, 7, 9, 15}.contains(_boardReset)
                  ? context.sc.danger
                  : null,
            ),
          ScRow(
            title: 'Bluetooth address',
            caption: 'Tap to copy',
            value: _savedCircuitId!,
            onTap: () => _copyValue('Bluetooth address', _savedCircuitId!),
          ),
          ScRow(
            title: 'IP address',
            caption: _wifiIp == null
                ? 'Circuit is not on Wi-Fi'
                : 'On ${_wifiSsid.isEmpty ? 'your Wi-Fi' : _wifiSsid} · tap to copy',
            value: _wifiIp ?? 'Not connected',
            onTap: _wifiIp == null
                ? null
                : () => _copyValue('IP address', _wifiIp!),
          ),
          ScRow(
            title: 'Wi-Fi MAC address',
            caption: _wifiMac.isEmpty
                ? 'Circuit shares it when it is connected'
                : 'Tap to copy',
            value: _wifiMac.isEmpty ? 'Unknown' : _wifiMac,
            onTap: _wifiMac.isEmpty
                ? null
                : () => _copyValue('Wi-Fi MAC address', _wifiMac),
          ),
          ScRow(
            title: 'Note encryption',
            caption: _noteKeyId == null
                ? 'Waiting for the key from Circuit'
                : 'New notes are encrypted on Circuit and stay encrypted here',
            value: _noteKeyId == null ? 'Waiting' : 'On',
            valueColor: _noteKeyId == null
                ? context.sc.orange
                : context.sc.green,
          ),
          ScRow(title: 'Latest status', caption: _status),
          const SizedBox(height: ScSpace.lg),
          ScButton(
            danger: true,
            icon: LucideIcons.unlink,
            label: 'Forget this Circuit',
            onPressed: _forgetCircuit,
          ),
        ],
      ],
    ];
  }

  // ---- Wi-Fi ---------------------------------------------------------------

  Widget _wifiStatusCard() {
    final slow =
        _wifiState == 'connecting' &&
        _wifiConnectingSince != null &&
        DateTime.now().difference(_wifiConnectingSince!).inSeconds > 20;
    final (
      IconData icon,
      Color color,
      String title,
      String subtitle,
    ) = switch (_wifiState) {
      'connected' => (
        LucideIcons.wifi,
        context.sc.green,
        'Connected to $_wifiSsid',
        _wifiDetail.isEmpty
            ? 'Circuit is online.'
            : 'Online at $_wifiDetail. Hold Circuit\'s button for 2 seconds to sync notes when your phone is on this network.',
      ),
      'connecting' => (
        LucideIcons.wifi,
        context.sc.accent,
        'Connecting to $_wifiSsid…',
        slow
            ? 'Taking longer than usual. Circuit keeps retrying; check the password and that the router is in range.'
            : 'Circuit is joining the network.',
      ),
      'failed' => (
        LucideIcons.wifiOff,
        context.sc.danger,
        _wifiSsid.isEmpty
            ? 'Wi‑Fi setup failed'
            : "Couldn't connect to $_wifiSsid",
        _wifiDetail.isEmpty
            ? 'Check the details and try again.'
            : '$_wifiDetail. Check the details and try again.',
      ),
      _ => (
        LucideIcons.wifiOff,
        context.sc.muted,
        'Circuit is not on Wi‑Fi',
        'Set up Wi‑Fi so notes sync quickly. Without it only a button-hold sync over Bluetooth works, and it is slow.',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: context.sc.warmCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _wifiState == 'connecting'
              ? SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: color,
                  ),
                )
              : Icon(icon, color: color, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: context.sc.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _passwordField(TextEditingController controller) => TextField(
    controller: controller,
    obscureText: !_showWifiPassword,
    enableSuggestions: false,
    autocorrect: false,
    decoration: InputDecoration(
      hintText: 'Password',
      suffixIcon: IconButton(
        tooltip: _showWifiPassword ? 'Hide password' : 'Show password',
        icon: Icon(
          _showWifiPassword ? LucideIcons.eyeOff : LucideIcons.eye,
          size: 20,
        ),
        onPressed: () => _update(() => _showWifiPassword = !_showWifiPassword),
      ),
    ),
  );

  List<Widget> _wifiPage() {
    final selected = _wifiSsidController.text.trim();
    final connecting = _provisioningWifi || _wifiState == 'connecting';
    return [
      ScBackRow(label: 'Circuit', onBack: _goBack, eyebrow: 'Wi‑Fi setup'),
      const ScTitle('Connect Circuit'),
      const SizedBox(height: 8),
      Text(
        'Choose a nearby network and enter its password. Circuit will prefer Wi‑Fi when it is available.',
        style: TextStyle(color: context.sc.muted, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 20),
      _wifiStatusCard(),
      if (_wifiState == 'connected') ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: ScIconButton(
            icon: LucideIcons.wifiOff,
            tooltip: 'Forget this network',
            caption: 'Forget',
            tone: ScTone.danger,
            onPressed: _forgetWifi,
          ),
        ),
      ],
      const SizedBox(height: 22),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const ScGroupLabel('Nearby networks'),
          ScIconButton(
            size: 40,
            icon: LucideIcons.refreshCw,
            tooltip: _scanningWifi ? 'Scanning for networks' : 'Scan again',
            busy: _scanningWifi,
            onPressed: _scanWifi,
          ),
        ],
      ),
      if (_wifiNetworks.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            _scanningWifi
                ? 'Looking for networks…'
                : 'No networks yet. Tap Scan again, or add a hidden network.',
            style: TextStyle(color: context.sc.muted, fontSize: 12),
          ),
        ),
      for (final ssid in _wifiNetworks) ...[
        Material(
          color: context.sc.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
            side: BorderSide(
              color: ssid == selected ? context.sc.accent : context.sc.line,
              width: ssid == selected ? 1.6 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () => _update(() => _wifiSsidController.text = ssid),
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ssid,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.sc.ink,
                      ),
                    ),
                  ),
                  if (_wifiState == 'connected' && ssid == _wifiSsid)
                    Text(
                      'Connected',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.sc.green,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else
                    Icon(LucideIcons.wifi, size: 18, color: context.sc.muted),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: ScIconButton(
          icon: LucideIcons.wifiPen,
          tooltip: 'Add hidden network',
          caption: 'Hidden',
          onPressed: () => _goTo(_AppPage.hiddenWifi),
        ),
      ),
      const SizedBox(height: 22),
      const ScGroupLabel('Password'),
      _passwordField(_wifiPasswordController),
      const SizedBox(height: 14),
      ScIconButton(
        expand: true,
        size: 54,
        icon: LucideIcons.wifi,
        tone: ScTone.primary,
        busy: connecting,
        tooltip: selected.isEmpty
            ? 'Choose a network first'
            : 'Connect Circuit to $selected',
        onPressed: connecting || selected.isEmpty ? null : _provisionWifi,
      ),
    ];
  }

  List<Widget> _hiddenWifiPage() => [
    ScBackRow(label: 'Wi‑Fi', onBack: _goBack, eyebrow: 'Hidden network'),
    const ScTitle('Add hidden Wi‑Fi'),
    const SizedBox(height: 8),
    Text(
      'Enter the network name exactly as configured on your router.',
      style: TextStyle(color: context.sc.muted, fontSize: 12, height: 1.4),
    ),
    const SizedBox(height: 22),
    const ScGroupLabel('Network name (SSID)'),
    TextField(
      controller: _wifiSsidController,
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(hintText: 'My hidden network'),
      onChanged: (_) => _update(() {}),
    ),
    const SizedBox(height: 16),
    const ScGroupLabel('Password'),
    _passwordField(_wifiPasswordController),
    const SizedBox(height: 18),
    ScIconButton(
      expand: true,
      size: 54,
      icon: LucideIcons.check,
      tone: ScTone.primary,
      busy: _provisioningWifi,
      tooltip: 'Save hidden Wi-Fi and connect',
      onPressed: _provisioningWifi || _wifiSsidController.text.trim().isEmpty
          ? null
          : () async {
              await _provisionWifi();
              if (mounted) _goBack();
            },
    ),
  ];

  // ---- recording -----------------------------------------------------------

  RecordingSnapshot _recordingSnapshot() {
    final started = _recordingStartedAt;
    return RecordingSnapshot(
      active: _recordingAudio,
      elapsed: started == null
          ? Duration.zero
          : DateTime.now().difference(started),
      song: _songClipArmed,
      busy: _audioBusy,
    );
  }

  /// The compact pill shown at the top of every screen while Circuit records.
  Widget _recordingIsland({bool decorated = true}) {
    final snapshot = _recordingSnapshot();
    return RecordingIsland(
      decorated: decorated,
      elapsed: snapshot.elapsed,
      song: snapshot.song,
      busy: snapshot.busy,
      onStop: _stopRecording,
      onExpand: _openRecordingSheet,
    );
  }

  Future<void> _openRecordingSheet() async {
    // The sheet sits where the status pill is, so the pill steps aside while it is open.
    statusPillHidden.value = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: context.sc.bg,
        builder: (_) =>
            RecordingSheet(read: _recordingSnapshot, onStop: _stopRecording),
      );
    } finally {
      statusPillHidden.value = false;
    }
  }

  // ---- shell ---------------------------------------------------------------

  /// The capture dock: Record (or Add task) at rest, a full-width recording bar while recording.
  Widget _dock(int tab) => ListenableBuilder(
    listenable: Listenable.merge([_phoneRecording, _nowPlaying]),
    builder: (context, _) {
      final phone = _phoneRecording.value;
      if (phone != null) {
        final state = phone['state'];
        final controllable = state == 'recording' || state == 'paused';
        return CaptureDock(
          mode: DockMode.recording,
          title: _phoneMoments.isEmpty
              ? 'Recording on this phone'
              : 'Recording · ${_phoneMoments.length} ${_phoneMoments.length == 1 ? 'Moment' : 'Moments'}',
          paused: state == 'paused',
          onMoment: state == 'recording' ? _addPhoneMoment : null,
          elapsed: () => Duration(
            milliseconds: ((_phoneRecording.value?['elapsedMs'] as num?) ?? 0)
                .toInt(),
          ),
          level: () =>
              ((_phoneRecording.value?['level'] as num?) ?? 0).toDouble(),
          onTogglePause: controllable
              ? () => _phoneRecorder.invokeMethod<void>(
                  state == 'paused' ? 'resume' : 'pause',
                )
              : null,
          onStop: () => _phoneRecorder.invokeMethod<void>('stop'),
          onOpen: _openPhoneRecorder,
        );
      }
      if (_recordingAudio) {
        return CaptureDock(
          mode: DockMode.recording,
          title: _songClipArmed
              ? 'Listening for a song'
              : 'Recording on Circuit',
          elapsed: () => _recordingSnapshot().elapsed,
          onStop: _stopRecording,
          onOpen: _openRecordingSheet,
        );
      }
      final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
      if (tab > 1 || typing || _selecting || _page == _AppPage.group) {
        return const CaptureDock(mode: DockMode.hidden);
      }
      final playing =
          _nowPlaying.value != null ||
          _circuitPlayback != CircuitPlaybackPhase.idle;
      return tab == 1
          ? CaptureDock(
              mode: DockMode.pill,
              collapsed: _dockCollapsed || playing,
              pillLabel: 'Add task',
              pillIcon: LucideIcons.plus,
              onPill: _promptAddTask,
            )
          : CaptureDock(
              mode: DockMode.pill,
              collapsed: _dockCollapsed || playing,
              pillLabel: 'Record',
              pillTooltip:
                  'Record a voice note. Hold for more ways to capture.',
              onPill: _startPhoneRecording,
              onLongPress: _showCaptureOptions,
            );
    },
  );

  Widget? _inlineSnack() {
    final snack = _statusSnack();
    return snack == null
        ? null
        : Padding(
            key: snack.key,
            padding: const EdgeInsets.only(top: 8),
            child: snack,
          );
  }

  Widget _buildShell() {
    _publishSyncUi();
    _publishStatusUi();
    final tab = switch (_page) {
      _AppPage.notes || _AppPage.group => 0,
      _AppPage.tasks => 1,
      _AppPage.circuit || _AppPage.wifi || _AppPage.hiddenWifi => 2,
      _AppPage.settings => 3,
    };
    // Room under the list so the floating dock never hides the last row.
    final dockSpace =
        (tab <= 1 || _recordingAudio || _phoneRecording.value != null)
        ? 96.0
        : 28.0;
    // The player sits under the dock, over the bottom of the list.
    final listSpace = dockSpace + (_statusSnack() == null ? 0 : 76);
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(24, 18, 24, listSpace),
      children: switch (_page) {
        _AppPage.notes => _notesPage(),
        _AppPage.tasks => _tasksPage(),
        _AppPage.settings => _settingsPage(),
        _AppPage.circuit => _circuitPage(),
        _AppPage.wifi => _wifiPage(),
        _AppPage.hiddenWifi => _hiddenWifiPage(),
        _AppPage.group => _groupPage(),
      },
    );
    // Pull down on Notes or Circuit to ask Circuit whether anything new is waiting.
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: _page == _AppPage.notes || _page == _AppPage.circuit
            ? RefreshIndicator(
                color: context.sc.accent,
                backgroundColor: context.sc.surface,
                onRefresh: _pullRefresh,
                child: list,
              )
            : list,
      ),
    );
    // Recording, sync and playback show on every screen from one overlay (status_overlay.dart).
    final body = NotificationListener<UserScrollNotification>(
      onNotification: (note) {
        if (note.depth != 0) return false;
        final collapse = note.direction == ScrollDirection.reverse
            ? true
            : note.direction == ScrollDirection.forward ||
                  note.metrics.pixels <= 0
            ? false
            : _dockCollapsed;
        if (collapse != _dockCollapsed)
          _update(() => _dockCollapsed = collapse);
        return false;
      },
      child: content,
    );
    if (_showOnboarding) {
      return OnboardingPage(
        onFinish: _finishOnboarding,
        onOpenCircuit: () => _finishOnboarding(tab: 2),
        onOpenAi: () => _finishOnboarding(tab: 3),
      );
    }
    return PopScope(
      canPop: _page == _AppPage.notes,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: SafeArea(bottom: false, child: body)),
            // Dock and player share one column: when the player appears the column grows upward over
            // the pill's own animation, so the Record button glides up instead of jumping.
            Positioned(
              left: 20,
              right: 20,
              bottom: 12,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _dock(tab),
                      AnimatedSize(
                        duration: MediaQuery.of(context).disableAnimations
                            ? Duration.zero
                            : const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, .3),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child:
                              _inlineSnack() ??
                              const SizedBox.shrink(key: ValueKey('no-snack')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [ScNavBar(index: tab, onSelect: _selectTab)],
        ),
      ),
    );
  }
}

/// The three indicators at the top of Home. Each says what is true now:
///  - the dot: Circuit is connected (green), being reached (orange), or not (grey);
///  - Wi-Fi: Circuit's own Wi-Fi, only while Circuit is connected, since otherwise it is old news;
///  - the phone: Stay connected is on (green once it has a link, orange while it is trying).
class CircuitChip extends StatelessWidget {
  const CircuitChip({
    super.key,
    this.chipKey,
    required this.connected,
    required this.link,
    required this.wifiState,
    required this.stayConnected,
    required this.onTap,
  });

  final Key? chipKey;
  final bool connected;
  final RelayLink link;
  final String wifiState;
  final bool stayConnected;
  final VoidCallback onTap;

  static const grey = Color(0xffa6a9af);

  bool get _reaching =>
      !connected && (link == RelayLink.trying || link == RelayLink.needsRepair);

  Color get dotColor => connected
      ? const Color(0xff3b9a68)
      : _reaching
      ? Sc.orange
      : grey;

  Color get wifiColor => !connected
      ? grey
      : wifiState == 'connected'
      ? Sc.green
      : wifiState == 'connecting'
      ? Sc.orange
      : grey;

  Color get stayColor => !stayConnected
      ? grey
      : connected
      ? Sc.green
      : Sc.orange;

  String get description {
    final circuit = connected
        ? 'Circuit, connected'
        : link == RelayLink.needsRepair
        ? 'Circuit, needs pairing again'
        : link == RelayLink.trying
        ? 'Circuit, connecting'
        : 'Circuit, not connected';
    final wifi = !connected
        ? ''
        : wifiState == 'connected'
        ? '. Wi-Fi connected'
        : wifiState == 'connecting'
        ? '. Wi-Fi connecting'
        : '. Wi-Fi not connected';
    return '$circuit$wifi. Stay connected ${stayConnected ? 'on' : 'off'}';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: description,
      hint: 'Opens device settings',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          key: chipKey,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: context.sc.chip,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: const ValueKey('circuit-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  boxShadow: connected
                      ? const [
                          BoxShadow(color: Color(0x203b9a68), spreadRadius: 4),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                connected && wifiState == 'failed'
                    ? LucideIcons.wifiOff
                    : LucideIcons.wifi,
                key: const ValueKey('circuit-wifi'),
                size: 15,
                color: wifiColor,
              ),
              const SizedBox(width: 6),
              Icon(
                LucideIcons.smartphone,
                key: const ValueKey('circuit-stay'),
                size: 15,
                color: stayColor,
              ),
              const SizedBox(width: 8),
              const ScDeviceMark(size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
