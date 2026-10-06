part of '../main.dart';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
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

Future<bool> _confirmDeleteNote(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text(
          'This removes only the phone copy. Circuit keeps nothing once a note is synced.',
        ),
        actions: scDialogActions(
          dialogContext,
          confirmIcon: LucideIcons.trash2,
          confirmTooltip: 'Delete note',
          danger: true,
          onCancel: () => Navigator.pop(dialogContext, false),
          onConfirm: () => Navigator.pop(dialogContext, true),
        ),
      ),
    ) ??
    false;

extension _ScPages on _CircuitHomePageState {
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
    _ => 'Not set up',
  };

  /// Circuit's IP address while it is on Wi-Fi, else null.
  String? get _wifiIp =>
      _wifiState == 'connected' &&
          RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(_wifiDetail.trim())
      ? _wifiDetail.trim()
      : null;

  /// Records on this phone, no Circuit needed. While a recording runs it shows the
  /// time and reopens the controls.
  Widget _phoneRecordButton() => ValueListenableBuilder<Map<String, dynamic>?>(
    valueListenable: _phoneRecording,
    builder: (context, recording, _) {
      final active = recording != null;
      final elapsed = (recording?['elapsedMs'] as num?)?.toInt() ?? 0;
      final paused = recording?['state'] == 'paused';
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 54),
          backgroundColor: Sc.accent,
        ),
        onPressed: _startPhoneRecording,
        icon: Icon(active ? LucideIcons.audioLines : LucideIcons.mic, size: 20),
        label: Text(
          active
              ? '${paused ? 'Paused' : 'Recording'} ${phoneRecordingClock(elapsed)} · tap to open'
              : 'Record on this phone',
        ),
      );
    },
  );

  Widget _deviceChip() => CircuitChip(
    chipKey: _deviceChipKey,
    connected: _circuitAvailable,
    link: _relayLink,
    wifiState: _wifiState,
    stayConnected: _relayActive,
    onTap: () => _goTo(_AppPage.circuit),
  );

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
          color: Sc.dangerSoft,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xfff3c6bb)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(LucideIcons.refreshCwOff, color: Sc.danger, size: 22),
                SizedBox(width: 10),
                Text(
                  'Sync needs attention',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Sc.danger,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: Color(0xff6b3a2f),
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
          color: Sc.hero,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Sc.accent,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Syncing a voice note',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  '${_syncProgress ?? 0}%',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _syncProgress == null ? null : _syncProgress! / 100,
                minHeight: 6,
                color: Sc.accent,
                backgroundColor: Colors.white,
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
                      fontWeight: FontWeight.w800,
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

  String _noteSubtitle(CircuitNote note) {
    final local = note.createdAt.toLocal();
    final source = note.source;
    final when =
        '${_dayLabel(note.createdAt)} · ${_two(local.hour)}:${_two(local.minute)}'
        '${source == null ? '' : ' · $source'}';
    if (note.id == _syncingNoteId) return '$when · Syncing';
    final song = note.song;
    if (note.isSong && song != null) {
      if (song.matched) {
        return song.artist == null ? when : '$when · ${song.artist}';
      }
      if (note.audioPath == null) return '$when · Waiting to sync';
      return switch (song.state) {
        'no_match' => '$when · No match found',
        'failed' => '$when · Identification failed',
        _ => '$when · Identifying…',
      };
    }
    if (note.id == _transcribingNoteId) return '$when · Transcribing…';
    if (note.status.startsWith('No speech detected'))
      return '$when · No speech found';
    if (note.status.startsWith('Transcription error'))
      return '$when · Transcription failed';
    if (note.status.startsWith('Sync failed') ||
        note.status.startsWith('Sync interrupted')) {
      return '$when · Sync failed';
    }
    if (note.status.startsWith('Waiting for Wi-Fi'))
      return '$when · Waiting for Wi-Fi';
    if (note.enrichmentStatus == 'enriching') return '$when · AI reviewing';
    if (note.enrichmentStatus == 'failed') return '$when · AI review failed';
    if (note.actionSuggestions.any((item) => item.state == 'pending'))
      return '$when · Action to review';
    if (note.transcript != null) return '$when · Transcribed';
    if (note.audioPath != null) return '$when · Ready to transcribe';
    return '$when · Waiting to sync';
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
          audioPath: note.audioPath,
          onPlayNote: _playSyncedNote,
          playerBar: _nowPlayingBar,
          onDeleteNote: _deleteNote,
          onCreateReminder: _extractReminder,
          onAddTask: (title, detail) => _addTask(title, detail: detail),
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

  Widget _noteTile(CircuitNote note, {bool actions = false}) {
    final attention = _noteNeedsAttention(note);
    final canTranscribe =
        !note.isSong && note.audioPath != null && note.transcript == null;
    final needsSync = note.audioPath == null && note.id != _syncingNoteId;
    final footerButtons = <Widget>[
      if (actions &&
          (note.enrichmentStatus == 'failed' ||
              note.enrichmentStatus == 'pending') &&
          (note.transcript ?? '').trim().isNotEmpty)
        ScIconButton(
          size: 40,
          icon: LucideIcons.sparkles,
          tooltip: note.enrichmentStatus == 'failed'
              ? 'Retry AI review'
              : 'Run AI review',
          onPressed: () => _retryEnrichment(note.id),
        ),
      if (actions && canTranscribe)
        ScIconButton(
          size: 40,
          icon: LucideIcons.languages,
          tooltip: _transcribingNoteId == note.id
              ? 'Transcribing'
              : 'Transcribe',
          busy: _transcribingNoteId == note.id,
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
      if (actions &&
          note.isSong &&
          note.audioPath != null &&
          note.song != null &&
          !note.song!.matched &&
          !note.song!.busy)
        ScIconButton(
          size: 40,
          icon: LucideIcons.refreshCw,
          tooltip: 'Identify again',
          onPressed: () => _identifySongNote(note.id),
        ),
      if (actions && needsSync)
        ScIconButton(
          size: 40,
          icon: LucideIcons.refreshCw,
          tooltip: 'Sync now',
          onPressed: () => _syncLatestRecording(note.id),
        ),
    ];
    return ScTile(
      icon: _noteIcon(note),
      title: note.isSong
          ? (note.song?.title ?? 'Song identification')
          : note.title ??
                (note.audioPath == null ? 'Voice recording' : 'Voice note'),
      subtitle: _noteSubtitle(note),
      subtitleColor: attention ? Sc.danger : null,
      onTap: _openNote(note),
      trailing: ScPlayButton(
        onPressed: note.audioPath == null
            ? null
            : () => _playSyncedNote(note.audioPath),
      ),
      footer: note.id == _syncingNoteId
          ? ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: (_syncProgress ?? 0) / 100,
                minHeight: 5,
                color: Sc.accent,
                backgroundColor: Sc.line,
              ),
            )
          : footerButtons.isEmpty
          ? null
          : Wrap(spacing: 8, children: footerButtons),
    );
  }

  // ---- home ----------------------------------------------------------------

  List<Widget> _homePage() {
    final now = DateTime.now();
    final review = _notes
        .where((n) => n.audioPath != null && n.transcript == null)
        .length;
    final openTasks = _tasks.where((t) => !t.done).length;
    final total = review + openTasks;
    final synced = _notes.where((n) => n.audioPath != null).length;
    final attention = _notes.where(_noteNeedsAttention).toList();
    final worth = <CircuitNote>[
      ...attention,
      ..._notes.where(
        (n) =>
            !attention.contains(n) &&
            n.audioPath != null &&
            n.transcript == null,
      ),
      ..._notes.where(
        (n) =>
            !attention.contains(n) &&
            !(n.audioPath != null && n.transcript == null),
      ),
    ].take(3).toList();
    final parts = <String>[
      if (review > 0) '$review note${review == 1 ? '' : 's'} ready to review',
      if (openTasks > 0) '$openTasks open task${openTasks == 1 ? '' : 's'}',
    ];
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2, right: 12),
            child: ScBrandMark(size: 38),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ScEyebrow(
                  '${_weekdays[now.weekday - 1]} · ${now.day} ${_months[now.month - 1]}',
                ),
                const SizedBox(height: 4),
                ScTitle(
                  _displayName.isEmpty ? 'Hello.' : 'Hey, $_displayName.',
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _deviceChip(),
        ],
      ),
      const SizedBox(height: 22),
      _phoneRecordButton(),
      const SizedBox(height: 14),
      _syncHealthCard(),
      _syncBanner(),
      Container(
        padding: const EdgeInsets.all(19),
        decoration: BoxDecoration(
          color: Sc.hero,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ScEyebrow('Your day at a glance'),
            const SizedBox(height: 9),
            Text(
              total == 0
                  ? "You're all caught up."
                  : '$total thing${total == 1 ? '' : 's'} need${total == 1 ? 's' : ''} you.',
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.3,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              !_circuitAvailable
                  ? 'Circuit is not connected. Open the Circuit chip above to connect it.'
                  : parts.isEmpty
                  ? 'Record a voice note with Circuit and it will show up here.'
                  : '${parts.join(' and ')}.',
              style: const TextStyle(
                color: Color(0xff7e7167),
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      Row(
        children: [
          Expanded(
            child: ScStat(label: 'Notes', value: '${_notes.length}'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ScStat(label: 'To do', value: '$openTasks'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ScStat(label: 'Synced', value: '$synced'),
          ),
        ],
      ),
      const SizedBox(height: 25),
      ScSectionRow(
        'Worth a look',
        action: 'Open inbox',
        onAction: () => _selectTab(1),
      ),
      if (worth.isEmpty)
        const ScTile(
          icon: LucideIcons.mic,
          title: 'No voice notes yet',
          subtitle: 'Tap the upper side button on Circuit to start recording.',
        )
      else
        for (final note in worth) ...[
          _noteTile(note),
          const SizedBox(height: 10),
        ],
    ];
  }

  // ---- notes tab -----------------------------------------------------------

  List<Widget> _notesPage() {
    final query = _noteSearchController.text.trim().toLowerCase();
    final visibleNotes = query.isEmpty
        ? _notes
        : _notes.where((note) {
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
    final libraryNotes = visibleNotes
        .where((note) => !_noteNeedsAttention(note))
        .toList();
    return [
      if (_selecting)
        _selectionHeader()
      else
        Row(
          children: [
            const Expanded(child: ScTitle('Notes')),
            ScIconButton(
              size: 44,
              icon: LucideIcons.listChecks,
              tooltip: 'Select notes to group',
              onPressed: _startSelecting,
            ),
            const SizedBox(width: 8),
            ScIconButton(
              size: 44,
              icon: _noteSearchOpen ? LucideIcons.x : LucideIcons.search,
              tooltip: _noteSearchOpen ? 'Close search' : 'Search notes',
              onPressed: () => _update(() {
                if (_noteSearchOpen) _noteSearchController.clear();
                _noteSearchOpen = !_noteSearchOpen;
              }),
            ),
          ],
        ),
      if (_noteSearchOpen) ...[
        const SizedBox(height: 10),
        TextField(
          controller: _noteSearchController,
          autofocus: true,
          onChanged: (_) => _update(() {}),
          decoration: const InputDecoration(
            hintText: 'Search',
            prefixIcon: Icon(LucideIcons.search, size: 18),
            isDense: true,
          ),
        ),
      ],
      const SizedBox(height: 14),
      _syncHealthCard(),
      _syncBanner(),
      _groupsRow(),
      if (_notes.any(_noteNeedsAttention)) ...[
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
                  color: Sc.dangerSoft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(LucideIcons.trash2, color: Sc.danger),
              ),
              confirmDismiss: (_) => _confirmDeleteNote(context),
              onDismissed: (_) => _deleteNote(note.id),
              child: _noteTile(note, actions: true),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 10),
      ],
      if (visibleNotes.isEmpty)
        const ScTile(
          icon: LucideIcons.mic,
          title: 'No matching notes',
          subtitle: 'Try another word or search tag.',
        )
      else
        for (final note in libraryNotes) ...[
          _selectableNote(
            note,
            Dismissible(
              key: ValueKey(note.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: Sc.dangerSoft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(LucideIcons.trash2, color: Sc.danger),
              ),
              confirmDismiss: (_) => _confirmDeleteNote(context),
              onDismissed: (_) => _deleteNote(note.id),
              child: _noteTile(note, actions: true),
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

  Widget _taskRow(CircuitTask task) => Dismissible(
    key: ValueKey(task.id),
    direction: DismissDirection.endToStart,
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 8),
      child: const Icon(LucideIcons.trash2, color: Sc.danger),
    ),
    onDismissed: (_) => _deleteTask(task.id),
    child: InkWell(
      onTap: () => _toggleTask(task.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Sc.line)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: task.done,
              activeColor: Sc.accent,
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
                      fontWeight: FontWeight.w800,
                      decoration: task.done ? TextDecoration.lineThrough : null,
                      color: task.done ? Sc.faint : Sc.ink,
                    ),
                  ),
                  if (task.detail != null && task.detail!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      task.detail!,
                      style: const TextStyle(fontSize: 11, color: Sc.faint),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _tasksPage() {
    final open = _tasks.where((t) => !t.done).toList();
    final done = _tasks.where((t) => t.done).toList();
    return [
      const ScEyebrow('Actions'),
      const SizedBox(height: 4),
      const ScTitle('Tasks'),
      const SizedBox(height: 8),
      const Text(
        'Things to do from your notes. Check them off as you go; swipe left to remove one.',
        style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.45),
      ),
      const SizedBox(height: 20),
      const ScGroupLabel('To do'),
      if (open.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            'Nothing to do right now.',
            style: TextStyle(color: Sc.faint, fontSize: 13),
          ),
        ),
      for (final task in open) _taskRow(task),
      if (done.isNotEmpty) ...[
        const SizedBox(height: 22),
        const ScGroupLabel('Done'),
        for (final task in done) _taskRow(task),
      ],
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerRight,
        child: ScIconButton(
          icon: LucideIcons.plus,
          tooltip: 'Add task',
          tone: ScTone.primary,
          onPressed: _promptAddTask,
        ),
      ),
    ];
  }

  // ---- settings tab --------------------------------------------------------

  Future<void> _promptName() async {
    final controller = TextEditingController(text: _displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Shown in the Home greeting',
          ),
        ),
        actions: scDialogActions(
          dialogContext,
          confirmIcon: LucideIcons.check,
          confirmTooltip: 'Save name',
          onConfirm: () => Navigator.pop(dialogContext, controller.text),
        ),
      ),
    );
    controller.dispose();
    if (name != null) await _saveDisplayName(name.trim());
  }

  List<Widget> _settingsPage() => [
    const ScEyebrow('App settings'),
    const SizedBox(height: 4),
    const ScTitle('Settings'),
    const SizedBox(height: 8),
    const Text(
      'Manage your Circuit, choose how notes are transcribed, and personalise the app.',
      style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.45),
    ),
    const SizedBox(height: 22),
    const ScGroupLabel('Device'),
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Sc.circuitCard,
        borderRadius: BorderRadius.circular(18),
      ),
      child: InkWell(
        onTap: () => _goTo(_AppPage.circuit),
        child: Row(
          children: [
            const ScDeviceMark(size: 43),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Circuit',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.4,
                    ),
                  ),
                  Text(
                    _circuitAvailable
                        ? 'Connected via Short-Circuit'
                        : 'Not connected',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff6e7d72),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: Color(0xff6e7d72),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 24),
    const ScGroupLabel('AI provider'),
    InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const GeminiSettingsPage()),
        );
        await _loadGeminiState();
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Sc.warmCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                LucideIcons.bot,
                size: 19,
                color: Color(0xffdb5b37),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Google Gemini',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    _geminiConnected
                        ? 'API key saved'
                        : 'Add an API key to transcribe notes',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff8e857d),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: Color(0xff9f968d),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 12),
    InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const AiServiceSettingsPage(),
          ),
        );
        await _loadAiState();
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Sc.warmCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                LucideIcons.sparkles,
                size: 18,
                color: Color(0xffdb5b37),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AI service',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    _aiConnected
                        ? 'Smart notes and action suggestions ready'
                        : 'Connect an AI service for smart note review',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff8e857d),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: Color(0xff9f968d),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 12),
    InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: _openMusicSettings,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Sc.warmCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                LucideIcons.music,
                size: 18,
                color: Color(0xffdb5b37),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Music recognition',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    _musicConnected
                        ? 'Identify song is ready'
                        : 'Add your service to identify songs',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff8e857d),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: Color(0xff9f968d),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 24),
    const ScGroupLabel('What AI can do'),
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
    const SizedBox(height: 24),
    const ScGroupLabel('Backup'),
    ScRow(
      title: 'Back up and restore',
      caption: 'One encrypted file, opened with a passphrase you choose',
      trailing: const Icon(
        LucideIcons.chevronRight,
        size: 18,
        color: Sc.accent,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BackupPage(onRestored: _afterBackupRestore),
        ),
      ),
    ),
    if (Telemetry.available) ...[
      const SizedBox(height: 24),
      const ScGroupLabel('Diagnostics'),
      ScRow(
        title: 'Share crash reports and usage',
        caption: 'Counts and errors only. Never your notes or what they say',
        trailing: Switch(
          value: _shareDiagnostics,
          onChanged: _setShareDiagnostics,
        ),
      ),
      ScRow(
        title: 'Send a test report',
        caption: 'Check that reports reach Firebase',
        onTap: _sendTestReport,
      ),
    ],
    const SizedBox(height: 24),
    const ScGroupLabel('You'),
    ScRow(
      title: 'Your name',
      caption: 'Shown in the Home greeting',
      value: _displayName.isEmpty ? 'Not set' : _displayName,
      onTap: _promptName,
    ),
    const SizedBox(height: 32),
    const Row(
      children: [
        ScBrandMark(size: 40),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Short-Circuit',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              Text(
                'Voice notes from Circuit, on your phone.',
                style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
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

  List<Widget> _circuitPage() {
    final available = _circuitAvailable;
    final waiting = _notes.where((n) => n.audioPath == null).length;
    return [
      ScBackRow(label: 'Home', onBack: _goBack, eyebrow: 'Device settings'),
      Container(
        margin: const EdgeInsets.only(top: 4, bottom: 24),
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: Sc.circuitCard,
          borderRadius: BorderRadius.circular(21),
        ),
        child: Row(
          children: [
            const ScDeviceMark(size: 43),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Circuit',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.5,
                    ),
                  ),
                  Text(
                    available
                        ? (_relayActive
                              ? 'Connected via Short-Circuit'
                              : 'Connected over Bluetooth')
                        : 'Not connected',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff6e7d72),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      _syncHealthCard(),
      _syncBanner(),
      if (!available) ...[
        const ScGroupLabel('Connect'),
        Row(
          children: [
            ScIconButton(
              icon: LucideIcons.bluetoothSearching,
              tooltip: _scanning ? 'Scanning for Circuit' : 'Scan for Circuit',
              caption: 'Scan',
              tone: ScTone.primary,
              busy: _scanning,
              onPressed: _connecting ? null : _scan,
            ),
            if (_savedCircuitId != null) ...[
              const SizedBox(width: 16),
              _needsPairingRepair
                  ? ScIconButton(
                      icon: LucideIcons.link,
                      tooltip: 'Repair Circuit pairing',
                      caption: 'Repair pairing',
                      tone: ScTone.primary,
                      onPressed: _connecting ? null : _repairPairing,
                    )
                  : ScIconButton(
                      icon: LucideIcons.rotateCw,
                      tooltip: 'Reconnect saved Circuit',
                      caption: 'Reconnect',
                      onPressed: _connecting
                          ? null
                          : () => _connect(
                              BluetoothDevice.fromId(_savedCircuitId!),
                              savedReconnect: true,
                            ),
                    ),
            ],
          ],
        ),
        const SizedBox(height: 10),
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
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 14),
      ],
      const ScGroupLabel('Device status'),
      ScRow(
        title: 'Connection',
        caption: _needsPairingRepair
            ? 'Pairing is needed before it can reconnect'
            : (_relayActive ? 'Through your phone' : 'Bluetooth'),
        value: available
            ? 'Online'
            : (_needsPairingRepair ? 'Repair needed' : 'Offline'),
        valueColor: available
            ? Sc.green
            : (_needsPairingRepair ? Sc.orange : Sc.faint),
      ),
      ScRow(
        title: 'Notes waiting',
        caption: 'Syncs automatically on Wi‑Fi',
        value: (_boardWaiting ?? waiting) == 0
            ? 'All synced'
            : '${_boardWaiting ?? waiting} on Circuit',
        valueColor: (_boardWaiting ?? 0) > 0 ? Sc.orange : null,
      ),
      ScRow(
        title: 'Last sync',
        caption: _syncError ?? 'Most recent successful transfer',
        value: _syncActive
            ? 'Syncing…'
            : _syncError != null
            ? 'Failed'
            : _lastSyncOk == null
            ? 'None yet'
            : _ago(_lastSyncOk!),
        valueColor: _syncError != null
            ? Sc.danger
            : (_syncActive ? Sc.orange : null),
        onTap: _syncError != null ? _retrySync : null,
      ),
      if (_boardReset != null && !{1, 3, 11}.contains(_boardReset))
        ScRow(
          title: 'Last restart',
          caption: _boardUptime < 3600
              ? 'Circuit restarted ${_boardUptime ~/ 60} min ago'
              : 'Reason Circuit last restarted',
          value: _resetReasonText(_boardReset!),
          valueColor: const {4, 5, 6, 7, 9, 15}.contains(_boardReset)
              ? Sc.danger
              : null,
        ),
      const SizedBox(height: 24),
      const ScGroupLabel('Connectivity'),
      ScRow(
        title: 'Wi‑Fi',
        caption: 'Saved network and setup',
        value: _wifiHeadline(),
        valueColor: _wifiState == 'connected'
            ? Sc.green
            : _wifiState == 'failed'
            ? Sc.danger
            : null,
        onTap: available ? () => _goTo(_AppPage.wifi) : null,
      ),
      ScRow(
        title: 'Stay connected',
        caption: 'Keeps Circuit linked in the background',
        value: _relayActive ? 'On' : 'Off',
        valueColor: _relayActive ? Sc.green : Sc.faint,
      ),
      if (_savedCircuitId != null) ...[
        const SizedBox(height: 24),
        const ScGroupLabel('About Circuit'),
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
          valueColor: _noteKeyId == null ? Sc.orange : Sc.green,
        ),
      ],
      const SizedBox(height: 22),
      Row(
        children: [
          Expanded(
            child: _captureButton(
              icon: LucideIcons.circle,
              iconSize: 11,
              label: 'Record',
              tooltip: 'Record a voice note on Circuit',
              color: Sc.accent,
              onTap: !available || _audioBusy || _recordingAudio
                  ? null
                  : _recordAudio,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _captureButton(
              icon: LucideIcons.music,
              iconSize: 15,
              label: 'Identify song',
              tooltip:
                  'Listen for $_songClipSeconds seconds and identify the song',
              color: Sc.dark,
              onTap: !available || _audioBusy || _recordingAudio
                  ? null
                  : _identifySong,
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      ScActionBar(
        children: [
          ScIconButton(
            icon: LucideIcons.play,
            tooltip: 'Play latest recording on Circuit',
            caption: 'Play',
            onPressed: available && !_audioBusy && !_recordingAudio
                ? _playAudio
                : null,
          ),
          ScIconButton(
            icon: LucideIcons.eraser,
            tooltip: 'Free up Circuit storage',
            caption: 'Free space',
            onPressed: available && !_audioBusy && !_recordingAudio
                ? _cleanCircuitNotes
                : null,
          ),
          if (_relayActive)
            ScIconButton(
              icon: LucideIcons.radio,
              tooltip: 'Turn off stay connected',
              caption: 'Turn off',
              onPressed: _stopPhoneRelay,
            ),
          if (_textCharacteristic != null)
            ScIconButton(
              icon: LucideIcons.unplug,
              tooltip: 'Disconnect from Circuit',
              caption: 'Disconnect',
              onPressed: () => _device?.disconnect(),
            ),
          if (_savedCircuitId != null)
            ScIconButton(
              icon: LucideIcons.unlink,
              tooltip: 'Forget this Circuit',
              caption: 'Forget',
              tone: ScTone.danger,
              onPressed: _forgetCircuit,
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        _status,
        style: const TextStyle(fontSize: 11, color: Sc.faint, height: 1.4),
      ),
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
        Sc.green,
        'Connected to $_wifiSsid',
        _wifiDetail.isEmpty
            ? 'Circuit is online.'
            : 'Online at $_wifiDetail. Notes sync automatically when your phone is on this network.',
      ),
      'connecting' => (
        LucideIcons.wifi,
        Sc.accent,
        'Connecting to $_wifiSsid…',
        slow
            ? 'Taking longer than usual. Circuit keeps retrying; check the password and that the router is in range.'
            : 'Circuit is joining the network.',
      ),
      'failed' => (
        LucideIcons.wifiOff,
        Sc.danger,
        _wifiSsid.isEmpty
            ? 'Wi‑Fi setup failed'
            : "Couldn't connect to $_wifiSsid",
        _wifiDetail.isEmpty
            ? 'Check the details and try again.'
            : '$_wifiDetail. Check the details and try again.',
      ),
      _ => (
        LucideIcons.wifiOff,
        Sc.faint,
        'Circuit is not on Wi‑Fi',
        'Set up Wi‑Fi so notes sync quickly. Without it only a button-hold sync over Bluetooth works, and it is slow.',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Sc.warmCard,
        borderRadius: BorderRadius.circular(18),
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
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xff8e857d),
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
      const Text(
        'Choose a nearby network and enter its password. Circuit will prefer Wi‑Fi when it is available.',
        style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
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
            style: const TextStyle(color: Sc.faint, fontSize: 12),
          ),
        ),
      for (final ssid in _wifiNetworks) ...[
        Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
            side: BorderSide(
              color: ssid == selected ? Sc.accent : Sc.line,
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
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xff332d28),
                      ),
                    ),
                  ),
                  if (_wifiState == 'connected' && ssid == _wifiSsid)
                    const Text(
                      'Connected',
                      style: TextStyle(
                        fontSize: 11,
                        color: Sc.green,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  else
                    const Icon(
                      LucideIcons.wifi,
                      size: 18,
                      color: Color(0xff6e5e50),
                    ),
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
    const Text(
      'Enter the network name exactly as configured on your router.',
      style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
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

  Future<void> _openRecordingSheet() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Sc.bg,
    builder: (_) =>
        RecordingSheet(read: _recordingSnapshot, onStop: _stopRecording),
  );

  // ---- shell ---------------------------------------------------------------

  Widget _buildShell() {
    final content = ListView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
      children: switch (_page) {
        _AppPage.home => _homePage(),
        _AppPage.notes => _notesPage(),
        _AppPage.tasks => _tasksPage(),
        _AppPage.settings => _settingsPage(),
        _AppPage.circuit => _circuitPage(),
        _AppPage.wifi => _wifiPage(),
        _AppPage.hiddenWifi => _hiddenWifiPage(),
        _AppPage.group => _groupPage(),
      },
    );
    // While Circuit records, a compact pill grows out of the Circuit indicator on Home (or out of
    // the top edge on other pages) and folds back into it when recording ends, so notes, tasks
    // and settings stay usable.
    final body = RecordingMorph(
      active: _recordingAudio,
      chipKey: _deviceChipKey,
      island: () => _recordingIsland(decorated: false),
      child: content,
    );
    final tab = switch (_page) {
      _AppPage.home => 0,
      _AppPage.notes || _AppPage.group => 1,
      _AppPage.tasks => 2,
      _AppPage.settings => 3,
      _ => -1,
    };
    return PopScope(
      canPop: _page == _AppPage.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _nowPlayingBar(),
            ScNavBar(index: tab, onSelect: _selectTab),
          ],
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
            color: Sc.chip,
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
