part of '../main.dart';

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              backgroundColor: Sc.danger,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

extension _ScPages on _CircuitHomePageState {
  bool get _circuitAvailable => _textCharacteristic != null || _relayActive;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(milliseconds: 2200)));
  }

  // ---- shared pieces -------------------------------------------------------

  String _wifiHeadline() => switch (_wifiState) {
    'connected' => _wifiSsid.isEmpty ? 'Connected' : _wifiSsid,
    'connecting' => 'Connecting…',
    'failed' => 'Failed',
    _ => 'Not set up',
  };

  Widget _deviceChip() {
    final wifiColor = _wifiState == 'connected'
        ? Sc.green
        : _wifiState == 'connecting'
        ? Sc.orange
        : const Color(0xffa6a9af);
    final available = _circuitAvailable;
    return GestureDetector(
      onTap: () => _goTo(_AppPage.circuit),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(color: Sc.chip, borderRadius: BorderRadius.circular(14)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: available ? const Color(0xff3b9a68) : const Color(0xffa6a9af),
                boxShadow: available
                    ? const [BoxShadow(color: Color(0x203b9a68), spreadRadius: 4)]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _wifiState == 'failed' ? Icons.wifi_off : Icons.wifi,
              size: 15,
              color: wifiColor,
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.phone_android,
              size: 15,
              color: _relayActive ? Sc.orange : const Color(0xffa6a9af),
            ),
            const SizedBox(width: 8),
            const Text(
              'Circuit',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xff30333a)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncBanner() {
    if (_syncingNoteId == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Sc.hero, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Sc.accent),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Syncing a voice note', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                Text('${_syncProgress ?? 0}%', style: const TextStyle(fontWeight: FontWeight.w800)),
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

  bool _noteNeedsAttention(CircuitNote note) =>
      note.status.startsWith('No speech detected') ||
      note.status.startsWith('Transcription error') ||
      note.status.startsWith('Sync failed') ||
      note.status.startsWith('Sync interrupted');

  IconData _noteIcon(CircuitNote note) {
    if (_noteNeedsAttention(note)) return Icons.error_outline;
    return switch (note.category) {
      'reminder' || 'task' || 'calendar_event' => Icons.check,
      'idea' => Icons.auto_awesome,
      'shopping' => Icons.shopping_bag_outlined,
      'journal' => Icons.menu_book_outlined,
      _ => note.transcript == null ? Icons.mic_none : Icons.notes,
    };
  }

  String _noteSubtitle(CircuitNote note) {
    final local = note.createdAt.toLocal();
    final when = '${_dayLabel(note.createdAt)} · ${_two(local.hour)}:${_two(local.minute)}';
    if (note.id == _syncingNoteId) return '$when · Syncing';
    if (note.id == _transcribingNoteId) return '$when · Transcribing…';
    if (note.status.startsWith('No speech detected')) return '$when · No speech found';
    if (note.status.startsWith('Transcription error')) return '$when · Transcription failed';
    if (note.status.startsWith('Sync failed') || note.status.startsWith('Sync interrupted')) {
      return '$when · Sync failed';
    }
    if (note.status.startsWith('Waiting for Wi-Fi')) return '$when · Waiting for Wi-Fi';
    if (note.transcript != null) return '$when · Transcribed';
    if (note.audioPath != null) return '$when · Ready to transcribe';
    return '$when · Waiting to sync';
  }

  VoidCallback? _openNote(CircuitNote note) {
    if (note.transcript == null) return null;
    return () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TranscriptPage(
          createdAt: note.createdAt,
          noteId: note.id,
          category: note.category ?? 'note',
          title: note.title ?? 'Voice note',
          transcript: note.transcript!,
          onForceTranscribe: _transcribeNote,
          audioPath: note.audioPath,
          onPlayNote: _playSyncedNote,
          onDeleteNote: _deleteNote,
          onCreateReminder: _extractReminder,
          onAddTask: (title, detail) => _addTask(title, detail: detail),
        ),
      ),
    );
  }

  Widget _noteTile(CircuitNote note, {bool actions = false}) {
    final attention = _noteNeedsAttention(note);
    final canTranscribe = note.audioPath != null && note.transcript == null;
    final needsSync = note.audioPath == null && note.id != _syncingNoteId;
    final footerButtons = <Widget>[
      if (actions && canTranscribe)
        TextButton.icon(
          onPressed: _transcribingNoteId != null
              ? null
              : () async {
                  final result = await _transcribeNote(note.id);
                  if (!mounted || result == null) return;
                  final updated = _notes.where((n) => n.id == note.id).firstOrNull;
                  final open = updated == null ? null : _openNote(updated);
                  open?.call();
                },
          icon: _transcribingNoteId == note.id
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.translate, size: 16),
          label: Text(_transcribingNoteId == note.id ? 'Transcribing…' : 'Transcribe'),
        ),
      if (actions && needsSync)
        TextButton.icon(
          onPressed: () => _syncLatestRecording(note.id),
          icon: const Icon(Icons.sync, size: 16),
          label: const Text('Sync now'),
        ),
    ];
    return ScTile(
      icon: _noteIcon(note),
      title: note.title ?? (note.audioPath == null ? 'Voice recording' : 'Voice note'),
      subtitle: _noteSubtitle(note),
      subtitleColor: attention ? Sc.danger : null,
      onTap: _openNote(note),
      trailing: ScPlayButton(
        onPressed: note.audioPath == null ? null : () => _playSyncedNote(note.audioPath),
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
          : Wrap(spacing: 4, children: footerButtons),
    );
  }

  // ---- home ----------------------------------------------------------------

  List<Widget> _homePage() {
    final now = DateTime.now();
    final review = _notes.where((n) => n.audioPath != null && n.transcript == null).length;
    final openTasks = _tasks.where((t) => !t.done).length;
    final total = review + openTasks;
    final synced = _notes.where((n) => n.audioPath != null).length;
    final attention = _notes.where(_noteNeedsAttention).toList();
    final worth = <CircuitNote>[
      ...attention,
      ..._notes.where((n) => !attention.contains(n) && n.audioPath != null && n.transcript == null),
      ..._notes.where((n) => !attention.contains(n) && !(n.audioPath != null && n.transcript == null)),
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ScEyebrow('${_weekdays[now.weekday - 1]} · ${now.day} ${_months[now.month - 1]}'),
                const SizedBox(height: 4),
                ScTitle(_displayName.isEmpty ? 'Hello.' : 'Hey, $_displayName.'),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _deviceChip(),
        ],
      ),
      const SizedBox(height: 22),
      _syncBanner(),
      Container(
        padding: const EdgeInsets.all(19),
        decoration: BoxDecoration(color: Sc.hero, borderRadius: BorderRadius.circular(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ScEyebrow('Your day at a glance'),
            const SizedBox(height: 9),
            Text(
              total == 0 ? "You're all caught up." : '$total thing${total == 1 ? '' : 's'} need${total == 1 ? 's' : ''} you.',
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800, letterSpacing: -1.3, height: 1.1),
            ),
            const SizedBox(height: 6),
            Text(
              !_circuitAvailable
                  ? 'Circuit is not connected. Open the Circuit chip above to connect it.'
                  : parts.isEmpty
                  ? 'Record a voice note with Circuit and it will show up here.'
                  : '${parts.join(' and ')}.',
              style: const TextStyle(color: Color(0xff7e7167), fontSize: 12, height: 1.45),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      Row(
        children: [
          Expanded(child: ScStat(label: 'Notes', value: '${_notes.length}')),
          const SizedBox(width: 10),
          Expanded(child: ScStat(label: 'To do', value: '$openTasks')),
          const SizedBox(width: 10),
          Expanded(child: ScStat(label: 'Synced', value: '$synced')),
        ],
      ),
      const SizedBox(height: 25),
      ScSectionRow('Worth a look', action: 'Open inbox', onAction: () => _selectTab(1)),
      if (worth.isEmpty)
        const ScTile(
          icon: Icons.mic_none,
          title: 'No voice notes yet',
          subtitle: 'Tap the upper side button on Circuit to start recording.',
        )
      else
        for (final note in worth) ...[_noteTile(note), const SizedBox(height: 10)],
    ];
  }

  // ---- notes tab -----------------------------------------------------------

  List<Widget> _notesPage() => [
    const ScEyebrow('Library'),
    const SizedBox(height: 4),
    const ScTitle('All notes'),
    const SizedBox(height: 8),
    const Text(
      'Your recordings, transcriptions, and saved ideas in one place.',
      style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.45),
    ),
    const SizedBox(height: 20),
    _syncBanner(),
    if (_notes.isEmpty)
      const ScTile(
        icon: Icons.mic_none,
        title: 'No voice notes yet',
        subtitle: 'Press the upper side button on Circuit to record one.',
      )
    else
      for (final note in _notes) ...[
        Dismissible(
          key: ValueKey(note.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(color: Sc.dangerSoft, borderRadius: BorderRadius.circular(18)),
            child: const Icon(Icons.delete_outline, color: Sc.danger),
          ),
          confirmDismiss: (_) => _confirmDeleteNote(context),
          onDismissed: (_) => _deleteNote(note.id),
          child: _noteTile(note, actions: true),
        ),
        const SizedBox(height: 10),
      ],
  ];

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
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Add'),
          ),
        ],
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
      child: const Icon(Icons.delete_outline, color: Sc.danger),
    ),
    onDismissed: (_) => _deleteTask(task.id),
    child: InkWell(
      onTap: () => _toggleTask(task.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Sc.line))),
        child: Row(
          children: [
            Checkbox(
              value: task.done,
              activeColor: Sc.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
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
                    Text(task.detail!, style: const TextStyle(fontSize: 11, color: Sc.faint)),
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
          child: Text('Nothing to do right now.', style: TextStyle(color: Sc.faint, fontSize: 13)),
        ),
      for (final task in open) _taskRow(task),
      if (done.isNotEmpty) ...[
        const SizedBox(height: 22),
        const ScGroupLabel('Done'),
        for (final task in done) _taskRow(task),
      ],
      const SizedBox(height: 20),
      ScButton(label: '+ Add task', onPressed: _promptAddTask),
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
          decoration: const InputDecoration(hintText: 'Shown in the Home greeting'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
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
      decoration: BoxDecoration(color: Sc.circuitCard, borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        onTap: () => _goTo(_AppPage.circuit),
        child: Row(
          children: [
            Container(
              width: 43,
              height: 43,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Sc.circuitMark, borderRadius: BorderRadius.circular(14)),
              child: const Text('C', style: TextStyle(color: Sc.circuitMarkInk, fontSize: 20, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Circuit', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -.4)),
                  Text(
                    _circuitAvailable ? 'Connected via Short-Circuit' : 'Not connected',
                    style: const TextStyle(fontSize: 11, color: Color(0xff6e7d72)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xff6e7d72)),
          ],
        ),
      ),
    ),
    const SizedBox(height: 24),
    const ScGroupLabel('AI provider'),
    InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GeminiSettingsPage()));
        await _loadGeminiState();
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Sc.warmCard, borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.smart_toy_outlined, size: 19, color: Color(0xffdb5b37)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Google Gemini', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                  Text(
                    _geminiConnected ? 'API key saved' : 'Add an API key to transcribe notes',
                    style: const TextStyle(fontSize: 11, color: Color(0xff8e857d)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xff9f968d)),
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
    const SizedBox(height: 24),
    const ScGroupLabel('You'),
    ScRow(title: 'Your name', caption: 'Shown in the Home greeting', value: _displayName.isEmpty ? 'Not set' : _displayName, onTap: _promptName),
  ];

  // ---- Circuit device page -------------------------------------------------

  Future<void> _forgetCircuit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget this Circuit?'),
        content: const Text('The phone will stop connecting to it. You can pair it again by scanning.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44), backgroundColor: Sc.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_relayActive) await _stopPhoneRelay();
    await _device?.disconnect();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_savedCircuitIdKey);
    if (!mounted) return;
    _update(() {
      _savedCircuitId = null;
      _device = null;
      _textCharacteristic = null;
      _relayCharacteristic = null;
      _relayActive = false;
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
        decoration: BoxDecoration(color: Sc.circuitCard, borderRadius: BorderRadius.circular(21)),
        child: Row(
          children: [
            Container(
              width: 43,
              height: 43,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Sc.circuitMark, borderRadius: BorderRadius.circular(14)),
              child: const Text('C', style: TextStyle(color: Sc.circuitMarkInk, fontSize: 20, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Circuit', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -.5)),
                  Text(
                    available
                        ? (_relayActive ? 'Connected via Short-Circuit' : 'Connected over Bluetooth')
                        : 'Not connected',
                    style: const TextStyle(fontSize: 11, color: Color(0xff6e7d72)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      _syncBanner(),
      if (!available) ...[
        const ScGroupLabel('Connect'),
        ScButton(
          label: _scanning ? 'Scanning…' : 'Scan for Circuit',
          icon: Icons.bluetooth_searching,
          busy: _scanning,
          onPressed: _connecting ? null : _scan,
        ),
        if (_savedCircuitId != null) ...[
          const SizedBox(height: 10),
          ScButton(
            label: 'Reconnect saved Circuit',
            icon: Icons.refresh,
            onPressed: _connecting
                ? null
                : () => _connect(BluetoothDevice.fromId(_savedCircuitId!), savedReconnect: true),
          ),
        ],
        const SizedBox(height: 10),
        for (final result in _circuits.values) ...[
          ScTile(
            icon: Icons.developer_board,
            title: _circuitName,
            subtitle: '${result.device.remoteId.str} · ${result.rssi} dBm',
            trailing: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
              onPressed: _connecting ? null : () => _connect(result.device),
              child: const Text('Connect'),
            ),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 14),
      ],
      const ScGroupLabel('Device status'),
      ScRow(
        title: 'Connection',
        caption: _relayActive ? 'Phone relay' : 'Bluetooth',
        value: available ? 'Online' : 'Offline',
        valueColor: available ? Sc.green : Sc.faint,
      ),
      ScRow(
        title: 'Notes waiting',
        caption: 'Syncs automatically on Wi‑Fi',
        value: waiting == 0 ? 'All synced' : '$waiting waiting',
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
        title: 'Phone relay',
        caption: 'Background connection',
        value: _relayActive ? 'On' : 'Off',
        valueColor: _relayActive ? Sc.green : Sc.faint,
      ),
      if (_savedCircuitId != null) ...[
        const SizedBox(height: 24),
        const ScGroupLabel('About Circuit'),
        ScRow(title: 'Device ID', caption: 'Bluetooth address', value: _savedCircuitId!.length > 10 ? '${_savedCircuitId!.substring(0, 8)}…' : _savedCircuitId!),
      ],
      const SizedBox(height: 22),
      Container(
        padding: const EdgeInsets.fromLTRB(15, 12, 13, 12),
        decoration: BoxDecoration(color: Sc.dark, borderRadius: BorderRadius.circular(18)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Short-Circuit', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
            Material(
              color: Sc.accent,
              borderRadius: BorderRadius.circular(15),
              child: InkWell(
                borderRadius: BorderRadius.circular(15),
                onTap: !available || _audioBusy || _recordingAudio ? null : _recordAudio,
                child: Opacity(
                  opacity: !available ? .45 : 1,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 9, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Record', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      ScButton(label: 'Play latest recording on Circuit', icon: Icons.play_arrow, onPressed: available && !_audioBusy && !_recordingAudio ? _playAudio : null),
      const SizedBox(height: 10),
      ScButton(label: 'Free up Circuit storage', icon: Icons.cleaning_services_outlined, onPressed: available && !_audioBusy && !_recordingAudio ? _cleanCircuitNotes : null),
      if (_relayActive) ...[
        const SizedBox(height: 10),
        ScButton(label: 'Stop phone relay', onPressed: _stopPhoneRelay),
      ],
      if (_textCharacteristic != null) ...[
        const SizedBox(height: 10),
        ScButton(label: 'Disconnect', onPressed: () => _device?.disconnect()),
      ],
      if (_savedCircuitId != null) ...[
        const SizedBox(height: 10),
        ScButton(label: 'Forget this Circuit', danger: true, onPressed: _forgetCircuit),
      ],
      const SizedBox(height: 8),
      Text(_status, style: const TextStyle(fontSize: 11, color: Sc.faint, height: 1.4)),
    ];
  }

  // ---- Wi-Fi ---------------------------------------------------------------

  Widget _wifiStatusCard() {
    final slow = _wifiState == 'connecting' &&
        _wifiConnectingSince != null &&
        DateTime.now().difference(_wifiConnectingSince!).inSeconds > 20;
    final (IconData icon, Color color, String title, String subtitle) = switch (_wifiState) {
      'connected' => (
        Icons.wifi,
        Sc.green,
        'Connected to $_wifiSsid',
        _wifiDetail.isEmpty
            ? 'Circuit is online.'
            : 'Online at $_wifiDetail. Notes sync automatically when your phone is on this network.',
      ),
      'connecting' => (
        Icons.wifi_find,
        Sc.accent,
        'Connecting to $_wifiSsid…',
        slow
            ? 'Taking longer than usual. Circuit keeps retrying; check the password and that the router is in range.'
            : 'Circuit is joining the network.',
      ),
      'failed' => (
        Icons.wifi_off,
        Sc.danger,
        _wifiSsid.isEmpty ? 'Wi‑Fi setup failed' : "Couldn't connect to $_wifiSsid",
        _wifiDetail.isEmpty ? 'Check the details and try again.' : '$_wifiDetail. Check the details and try again.',
      ),
      _ => (
        Icons.wifi_off_outlined,
        Sc.faint,
        'Circuit is not on Wi‑Fi',
        'Set up Wi‑Fi so notes sync quickly. Without it only a button-hold sync over Bluetooth works, and it is slow.',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Sc.warmCard, borderRadius: BorderRadius.circular(18)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _wifiState == 'connecting'
              ? SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: color))
              : Icon(icon, color: color, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(fontSize: 11.5, color: Color(0xff8e857d), height: 1.4)),
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
        icon: Icon(_showWifiPassword ? Icons.visibility_off : Icons.visibility, size: 20),
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
        ScButton(label: 'Forget this network', danger: true, onPressed: _forgetWifi),
      ],
      const SizedBox(height: 22),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const ScGroupLabel('Nearby networks'),
          GestureDetector(
            onTap: _scanningWifi ? null : _scanWifi,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _scanningWifi ? 'Scanning…' : 'Scan again',
                style: const TextStyle(color: Color(0xff6b55d9), fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
      if (_wifiNetworks.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            _scanningWifi ? 'Looking for networks…' : 'No networks yet. Tap Scan again, or add a hidden network.',
            style: const TextStyle(color: Sc.faint, fontSize: 12),
          ),
        ),
      for (final ssid in _wifiNetworks) ...[
        Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
            side: BorderSide(color: ssid == selected ? Sc.accent : Sc.line, width: ssid == selected ? 1.6 : 1),
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
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xff332d28)),
                    ),
                  ),
                  if (_wifiState == 'connected' && ssid == _wifiSsid)
                    const Text('Connected', style: TextStyle(fontSize: 11, color: Sc.green, fontWeight: FontWeight.w800))
                  else
                    const Icon(Icons.wifi, size: 18, color: Color(0xff6e5e50)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 6),
      ScButton(label: '+ Add hidden network', onPressed: () => _goTo(_AppPage.hiddenWifi)),
      const SizedBox(height: 22),
      const ScGroupLabel('Password'),
      _passwordField(_wifiPasswordController),
      const SizedBox(height: 14),
      FilledButton(
        onPressed: connecting || selected.isEmpty ? null : _provisionWifi,
        child: Text(connecting ? 'Connecting…' : (selected.isEmpty ? 'Choose a network' : 'Connect to $selected')),
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
    FilledButton(
      onPressed: _provisioningWifi || _wifiSsidController.text.trim().isEmpty
          ? null
          : () async {
              await _provisionWifi();
              if (mounted) _goBack();
            },
      child: const Text('Save hidden Wi‑Fi'),
    ),
  ];

  // ---- recording -----------------------------------------------------------

  Widget _recordPage() {
    final started = _recordingStartedAt;
    final elapsed = started == null ? Duration.zero : DateTime.now().difference(started);
    final clock = '${_two(elapsed.inMinutes)}:${_two(elapsed.inSeconds % 60)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 70, 20, 28),
      child: Column(
        children: [
          Container(
            width: 132,
            height: 132,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Sc.accent),
              boxShadow: const [
                BoxShadow(color: Color(0x12f05b3d), spreadRadius: 16),
                BoxShadow(color: Color(0x08f05b3d), spreadRadius: 32),
              ],
            ),
            child: const Icon(Icons.circle, size: 38, color: Sc.accent),
          ),
          const SizedBox(height: 56),
          const ScTitle('Recording on Circuit'),
          const SizedBox(height: 9),
          Text(clock, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -1)),
          const SizedBox(height: 6),
          const Text(
            "Speak naturally. Press stop when you're done.",
            style: TextStyle(color: Sc.muted, fontSize: 12),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: 220,
            child: FilledButton(
              onPressed: _audioBusy ? null : _stopRecording,
              child: const Text('Stop recording'),
            ),
          ),
        ],
      ),
    );
  }

  // ---- shell ---------------------------------------------------------------

  Widget _buildShell() {
    final body = _recordingAudio
        ? _recordPage()
        : ListView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
            children: switch (_page) {
              _AppPage.home => _homePage(),
              _AppPage.notes => _notesPage(),
              _AppPage.tasks => _tasksPage(),
              _AppPage.settings => _settingsPage(),
              _AppPage.circuit => _circuitPage(),
              _AppPage.wifi => _wifiPage(),
              _AppPage.hiddenWifi => _hiddenWifiPage(),
            },
          );
    final tab = switch (_page) {
      _AppPage.home => 0,
      _AppPage.notes => 1,
      _AppPage.tasks => 2,
      _AppPage.settings => 3,
      _ => -1,
    };
    return PopScope(
      canPop: _page == _AppPage.home && !_recordingAudio,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: _recordingAudio ? null : ScNavBar(index: tab, onSelect: _selectTab),
      ),
    );
  }
}
