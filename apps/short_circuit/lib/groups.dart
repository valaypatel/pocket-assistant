part of 'main.dart';

// Note groups: a named list of notes you can chat with as one. A group stores only note ids, so
// notes stay separate, keep their own audio and chat, and can be in several groups. Groups and
// their chats are saved sealed, like the notes themselves.

const _groupsKey = 'circuit_groups';

/// The built-in group of every spoken note. Never stored; always there.
const allNotesGroupId = 'all';

/// How much note text one group chat sends at once (characters, about 4,000 words). Older notes
/// drop first. Kept modest because Gujarati and Hindi use many more tokens per character than
/// English, and the AI service's context size is not known to the app.
const groupContextBudget = 24000;

class NoteGroup {
  const NoteGroup({
    required this.id,
    required this.name,
    required this.noteIds,
    required this.createdAt,
  });

  final String id;
  final String name;
  final List<String> noteIds;
  final DateTime createdAt;

  NoteGroup copyWith({String? name, List<String>? noteIds}) => NoteGroup(
    id: id,
    name: name ?? this.name,
    noteIds: noteIds ?? this.noteIds,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'noteIds': noteIds,
    'createdAt': createdAt.toIso8601String(),
  };

  factory NoteGroup.fromJson(Map<String, dynamic> json) => NoteGroup(
    id: json['id'] as String,
    name: (json['name'] as String?)?.trim().isNotEmpty == true
        ? (json['name'] as String).trim()
        : 'Group',
    noteIds: (json['noteIds'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

/// What the AI is given for a group chat, and what the screen says about it.
class GroupContext {
  const GroupContext({
    required this.text,
    required this.included,
    required this.transcribed,
    required this.total,
  });

  /// The notes, oldest first, as plain text.
  final String text;

  /// Notes whose text is in [text].
  final int included;

  /// Notes that have a transcript at all.
  final int transcribed;

  /// Spoken notes in the group.
  final int total;

  int get notTranscribed => total - transcribed;
  int get leftOut => transcribed - included;

  /// "Using 18 of 22 notes", with why the others are missing.
  String get banner {
    final parts = <String>[
      'Using $included of $total note${total == 1 ? '' : 's'}',
      if (notTranscribed > 0) '$notTranscribed not transcribed yet',
      if (leftOut > 0) '$leftOut older left out to fit',
    ];
    return parts.join(' · ');
  }
}

String _two2(int v) => v.toString().padLeft(2, '0');

String _noteStamp(DateTime time) {
  final t = time.toLocal();
  return '${t.year}-${_two2(t.month)}-${_two2(t.day)} ${_two2(t.hour)}:${_two2(t.minute)}';
}

/// The text of one note as the AI sees it.
String _noteBlock(CircuitNote note) {
  final b = StringBuffer()
    ..writeln(
      '--- Note · ${_noteStamp(note.createdAt)} · ${note.title ?? 'Voice note'} ---',
    );
  if ((note.summary ?? '').isNotEmpty) b.writeln('Summary: ${note.summary}');
  b.writeln(note.transcript ?? '');
  if ((note.englishTranslation ?? '').isNotEmpty &&
      note.englishTranslation != note.transcript) {
    b
      ..writeln('English translation:')
      ..writeln(note.englishTranslation);
  }
  return b.toString();
}

/// Builds the context for a group chat. Songs are not notes you can talk about, so they are
/// skipped. Notes with no transcript yet are counted but not sent (there is nothing to read).
/// If everything does not fit [budget] characters, the newest notes are kept and the oldest
/// left out, and the result says how many.
GroupContext buildGroupContext(
  Iterable<CircuitNote> notes, {
  int budget = groupContextBudget,
}) {
  final spoken = notes.where((n) => !n.isSong).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final readable = spoken
      .where((n) => (n.transcript ?? '').trim().isNotEmpty)
      .toList();
  final kept = <String>[];
  var used = 0;
  for (final note in readable.reversed) {
    var block = _noteBlock(note);
    if (used + block.length > budget) {
      if (kept.isNotEmpty)
        break; // keep the newest whole notes, drop the older ones
      block = block.substring(0, budget); // one huge note: take what fits
    }
    kept.add(block);
    used += block.length;
  }
  return GroupContext(
    text: kept.reversed.join('\n'),
    included: kept.length,
    transcribed: readable.length,
    total: spoken.length,
  );
}

extension GroupChat on AiClient {
  Future<String> chatAboutGroup(
    String groupName,
    GroupContext context,
    List<ChatMessage> history,
  ) async {
    final recent = history.length > 12
        ? history.sublist(history.length - 12)
        : history;
    final reply = await _send(
      [
        {
          'role': 'system',
          'content':
              'You answer questions about a group of private voice notes called "$groupName". Use only the notes below, which are in date order, oldest first. When it helps, say which note (by its date) you mean. If the answer is not in the notes, say so plainly instead of guessing. Be brief. Reply in the language the user writes in. Plain text, no markdown headings.\n\n${context.text}',
        },
        for (final message in recent)
          {'role': message.role, 'content': message.text},
      ],
      json: false,
      temperature: 0.3,
    );
    return reply.trim();
  }
}

// ---- state and actions --------------------------------------------------------------------------

extension _ScGroupState on _CircuitHomePageState {
  /// The built-in "All notes" group, or a saved one.
  NoteGroup? _groupById(String id) {
    if (id == allNotesGroupId) {
      return NoteGroup(
        id: allNotesGroupId,
        name: 'All notes',
        noteIds: [
          for (final n in _notes)
            if (!n.isSong) n.id,
        ],
        createdAt: DateTime.now(),
      );
    }
    return _groups.where((g) => g.id == id).firstOrNull;
  }

  /// A group's notes that still exist, newest first.
  List<CircuitNote> _notesOfGroup(NoteGroup group) {
    final ids = group.noteIds.toSet();
    return _notes.where((n) => ids.contains(n.id)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> _loadGroups() async {
    final preferences = await SharedPreferences.getInstance();
    final String? stored;
    try {
      stored = await _readSecret(preferences, _groupsKey);
    } catch (error) {
      // Never delete what could not be read.
      _setStatus(
        'Saved groups could not be opened ($error). They have not been deleted.',
      );
      return;
    }
    if (stored == null || !mounted) return;
    try {
      final groups = (jsonDecode(stored) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(NoteGroup.fromJson)
          .toList();
      if (mounted) _update(() => _groups = groups);
    } catch (_) {
      // Leave the stored text alone; the next save replaces it with what is on screen.
    }
  }

  Future<void> _saveGroups(List<NoteGroup> groups) async {
    if (mounted) _update(() => _groups = groups);
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _groupsKey,
      jsonEncode(groups.map((g) => g.toJson()).toList()),
    );
  }

  Future<NoteGroup> _createGroup(String name, Iterable<String> noteIds) async {
    final group = NoteGroup(
      id: 'g${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      noteIds: noteIds.toSet().toList(),
      createdAt: DateTime.now(),
    );
    await _saveGroups([..._groups, group]);
    return group;
  }

  Future<void> _addNotesToGroup(
    String groupId,
    Iterable<String> noteIds,
  ) async {
    await _saveGroups([
      for (final g in _groups)
        g.id == groupId
            ? g.copyWith(noteIds: {...g.noteIds, ...noteIds}.toList())
            : g,
    ]);
  }

  Future<void> _removeNoteFromGroup(String groupId, String noteId) async {
    await _saveGroups([
      for (final g in _groups)
        g.id == groupId
            ? g.copyWith(
                noteIds: g.noteIds.where((id) => id != noteId).toList(),
              )
            : g,
    ]);
  }

  /// A deleted note leaves every group it was in.
  Future<void> _removeNoteFromGroups(String noteId) async {
    if (!_groups.any((g) => g.noteIds.contains(noteId))) return;
    await _saveGroups([
      for (final g in _groups)
        g.copyWith(noteIds: g.noteIds.where((id) => id != noteId).toList()),
    ]);
  }

  Future<void> _renameGroup(String groupId, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    await _saveGroups([
      for (final g in _groups) g.id == groupId ? g.copyWith(name: clean) : g,
    ]);
  }

  /// Deleting a group never deletes its notes.
  Future<void> _deleteGroup(String groupId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('note_chat_group-$groupId');
    await _saveGroups(_groups.where((g) => g.id != groupId).toList());
  }

  // ---- choosing notes

  void _startSelecting([String? firstNoteId]) => _update(() {
    _selecting = true;
    _selectedNoteIds
      ..clear()
      ..addAll([?firstNoteId]);
  });

  void _toggleSelected(String noteId) => _update(() {
    if (!_selectedNoteIds.remove(noteId)) _selectedNoteIds.add(noteId);
  });

  void _endSelecting() => _update(() {
    _selecting = false;
    _selectedNoteIds.clear();
  });
}

// ---- screens ------------------------------------------------------------------------------------

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

extension _ScGroupUi on _CircuitHomePageState {
  // ---- selecting notes on the Notes tab

  Widget _checkCircle(bool on) => Container(
    width: 26,
    height: 26,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: on ? Sc.accent : Colors.transparent,
      border: Border.all(
        color: on ? Sc.accent : const Color(0xffc9c0b7),
        width: 1.6,
      ),
    ),
    child: on
        ? const Icon(LucideIcons.check, size: 16, color: Colors.white)
        : null,
  );

  /// A note on the Notes tab: normally as it is (long-press starts choosing notes); while
  /// choosing, a tick circle beside it and a tap picks it. Songs cannot be grouped.
  Widget _selectableNote(CircuitNote note, Widget normal) {
    if (!_selecting) {
      return GestureDetector(
        onLongPress: () => _startSelecting(note.id),
        child: normal,
      );
    }
    if (note.isSong) {
      return Opacity(opacity: .4, child: AbsorbPointer(child: _noteTile(note)));
    }
    final picked = _selectedNoteIds.contains(note.id);
    return Semantics(
      container: true,
      checked: picked,
      label: note.title ?? 'Voice note',
      hint: picked ? 'Selected. Tap to unselect' : 'Tap to select',
      onTap: () => _toggleSelected(note.id),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleSelected(note.id),
        child: Row(
          children: [
            _checkCircle(picked),
            const SizedBox(width: 10),
            Expanded(child: AbsorbPointer(child: _noteTile(note))),
          ],
        ),
      ),
    );
  }

  Widget _selectionHeader() {
    final count = _selectedNoteIds.length;
    final pickable = [
      for (final n in _notes)
        if (!n.isSong) n.id,
    ];
    return Row(
      children: [
        ScIconButton(
          size: 44,
          icon: LucideIcons.x,
          tooltip: 'Cancel selecting',
          onPressed: _endSelecting,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            count == 0 ? 'Select notes' : '$count selected',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        TextButton(
          onPressed: () => _update(() {
            if (_selectedNoteIds.length == pickable.length) {
              _selectedNoteIds.clear();
            } else {
              _selectedNoteIds
                ..clear()
                ..addAll(pickable);
            }
          }),
          child: Text(
            _selectedNoteIds.length == pickable.length && pickable.isNotEmpty
                ? 'Clear'
                : 'Select all',
          ),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: count == 0 ? null : _openGroupSheet,
          // The app's filled buttons are full width; in a row this one is just its label.
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Group'),
        ),
      ],
    );
  }

  // ---- the Groups row

  Widget _groupsRow() {
    final spoken = _notes.where((n) => !n.isSong).toList();
    if (_selecting || spoken.isEmpty) return const SizedBox.shrink();
    Widget card(String id, String name, int count, double width) => Semantics(
      button: true,
      label: '$name, $count note${count == 1 ? '' : 's'}',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        height: 88,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Sc.line),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _openGroup(id),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    id == allNotesGroupId
                        ? LucideIcons.layers
                        : LucideIcons.messagesSquare,
                    size: 18,
                    color: Sc.accent,
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '$count note${count == 1 ? '' : 's'}',
                        style: const TextStyle(color: Sc.faint, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Two columns that wrap, so every group is on screen. A sideways list hid the later ones
    // off the edge with nothing to say they were there.
    const maxShown = 6;
    final all = <(String, String, int)>[
      (allNotesGroupId, 'All notes', spoken.length),
      for (final g in _groups)
        (g.id, g.name, _notesOfGroup(g).where((n) => !n.isSong).length),
    ];
    final shown = _groupsExpanded ? all : all.take(maxShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ScGroupLabel('Groups (${all.length - 1})'),
        LayoutBuilder(
          builder: (context, box) {
            final width = (box.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (id, name, count) in shown)
                  card(id, name, count, width),
              ],
            );
          },
        ),
        if (all.length > maxShown)
          TextButton(
            onPressed: () => _update(() => _groupsExpanded = !_groupsExpanded),
            child: Text(
              _groupsExpanded
                  ? 'Show fewer'
                  : 'Show all ${all.length - 1} groups',
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  void _openGroup(String id) {
    _update(() => _openGroupId = id);
    _goTo(_AppPage.group);
  }

  // ---- making and changing groups

  void _openGroupSheet() {
    final picked = _notes.where((n) => _selectedNoteIds.contains(n.id)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (picked.isEmpty) return;
    final d = picked.first.createdAt.toLocal();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Sc.bg,
      builder: (sheetContext) => _GroupSheet(
        count: picked.length,
        suggestedName: 'Notes · ${d.day} ${_monthNames[d.month - 1]}',
        groups: _groups,
        onCreate: (name) async {
          final group = await _createGroup(name, picked.map((n) => n.id));
          if (!mounted) return;
          _endSelecting();
          _openGroup(group.id);
        },
        onAdd: (group) async {
          await _addNotesToGroup(group.id, picked.map((n) => n.id));
          if (!mounted) return;
          _endSelecting();
          _setStatus('Added ${picked.length} to "${group.name}".');
          _openGroup(group.id);
        },
      ),
    );
  }

  void _showAddNotesSheet(NoteGroup group) {
    final inGroup = group.noteIds.toSet();
    final candidates =
        _notes.where((n) => !n.isSong && !inGroup.contains(n.id)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final chosen = <String>{};
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Sc.bg,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Add notes',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      onPressed: chosen.isEmpty
                          ? null
                          : () async {
                              Navigator.pop(sheetContext);
                              await _addNotesToGroup(group.id, chosen);
                            },
                      child: Text(
                        chosen.isEmpty ? 'Add' : 'Add ${chosen.length}',
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: candidates.isEmpty
                    ? const Center(
                        child: Text(
                          'Every note is already in this group.',
                          style: TextStyle(color: Sc.muted),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        children: [
                          for (final n in candidates)
                            CheckboxListTile(
                              value: chosen.contains(n.id),
                              onChanged: (v) => setSheet(() {
                                if (v == true) {
                                  chosen.add(n.id);
                                } else {
                                  chosen.remove(n.id);
                                }
                              }),
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                n.title ?? 'Voice note',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(_noteStamp(n.createdAt)),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _promptRenameGroup(NoteGroup group) async {
    final controller = TextEditingController(text: group.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await _renameGroup(group.id, name);
  }

  Future<void> _confirmDeleteGroup(NoteGroup group) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${group.name}"?'),
        content: const Text(
          'Only the group and its chat are deleted. The notes stay where they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete group'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await _deleteGroup(group.id);
    if (mounted) _goBack();
  }

  // ---- the group page and its chat

  void _openGroupChat(NoteGroup group) {
    final context0 = buildGroupContext(_notesOfGroup(group));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NoteChatPage(
          noteId: 'group-${group.id}',
          title: group.name,
          subject: 'group',
          banner: context0.banner,
          starters: const [
            (LucideIcons.textAlignStart, 'Summarize all of these notes'),
            (LucideIcons.listChecks, 'List every task across these notes'),
            (LucideIcons.history, 'What changed over time?'),
          ],
          loadHistory: _loadNoteChat,
          saveHistory: _saveNoteChat,
          ask: (_, history) => _askAboutGroup(group.id, history),
          onAddTask: (title, detail) => _addTask(title, detail: detail),
        ),
      ),
    );
  }

  List<Widget> _groupPage() {
    final group = _groupById(_openGroupId ?? '');
    if (group == null) {
      return [
        ScBackRow(label: 'Notes', onBack: _goBack, eyebrow: 'Group'),
        const ScTile(
          icon: LucideIcons.layers,
          title: 'This group no longer exists',
          subtitle: 'Go back to Notes to see your groups.',
        ),
      ];
    }
    final isAll = group.id == allNotesGroupId;
    final notes = _notesOfGroup(group);
    final ctx = buildGroupContext(notes);
    final canChat = ctx.transcribed > 0;
    return [
      ScBackRow(
        label: 'Notes',
        onBack: _goBack,
        eyebrow: isAll ? 'Everything' : 'Group',
      ),
      Row(
        children: [
          Expanded(child: ScTitle(group.name)),
          if (!isAll)
            PopupMenuButton<String>(
              tooltip: 'Group options',
              onSelected: (value) {
                if (value == 'rename') _promptRenameGroup(group);
                if (value == 'delete') _confirmDeleteGroup(group);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete group')),
              ],
            ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '${ctx.total} note${ctx.total == 1 ? '' : 's'} · ${ctx.transcribed} transcribed',
        style: const TextStyle(color: Sc.muted, fontSize: 12),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: canChat ? () => _openGroupChat(group) : null,
        icon: const Icon(LucideIcons.messageCircle, size: 18),
        label: Text(isAll ? 'Chat with all notes' : 'Chat with this group'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      if (!canChat) ...[
        const SizedBox(height: 8),
        const Text(
          'None of these notes are transcribed yet. Transcribe a note first, then you can chat with it here.',
          style: TextStyle(color: Sc.orange, fontSize: 12, height: 1.4),
        ),
      ] else if (ctx.notTranscribed > 0 || ctx.leftOut > 0) ...[
        const SizedBox(height: 8),
        Text(ctx.banner, style: const TextStyle(color: Sc.muted, fontSize: 12)),
      ],
      if (!isAll) ...[
        const SizedBox(height: 12),
        ScButton(
          label: 'Add notes',
          icon: LucideIcons.plus,
          onPressed: () => _showAddNotesSheet(group),
        ),
      ],
      const SizedBox(height: 22),
      const ScGroupLabel('Notes'),
      if (notes.isEmpty)
        const ScTile(
          icon: LucideIcons.mic,
          title: 'No notes in this group',
          subtitle: 'Add notes to chat with them together.',
        )
      else
        for (final note in notes) ...[
          if (isAll)
            _noteTile(note)
          else
            Dismissible(
              key: ValueKey('g-${group.id}-${note.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: Sc.accentSoft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text(
                  'Remove from group',
                  style: TextStyle(
                    color: Sc.accentInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              onDismissed: (_) => _removeNoteFromGroup(group.id, note.id),
              child: _noteTile(note),
            ),
          const SizedBox(height: 10),
        ],
    ];
  }
}

/// "Group N notes": a name and Create, or add them to a group you already have.
class _GroupSheet extends StatefulWidget {
  const _GroupSheet({
    required this.count,
    required this.suggestedName,
    required this.groups,
    required this.onCreate,
    required this.onAdd,
  });

  final int count;
  final String suggestedName;
  final List<NoteGroup> groups;
  final Future<void> Function(String name) onCreate;
  final Future<void> Function(NoteGroup group) onAdd;

  @override
  State<_GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<_GroupSheet> {
  late final _name = TextEditingController(text: widget.suggestedName);
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    Navigator.of(context).pop();
    await action();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      20 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Group ${widget.count} note${widget.count == 1 ? '' : 's'}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _name.text.trim().isEmpty || _busy
              ? null
              : () => _run(() => widget.onCreate(_name.text)),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: const Text('Create group'),
        ),
        if (widget.groups.isNotEmpty) ...[
          const SizedBox(height: 18),
          const ScGroupLabel('Or add to a group you have'),
          for (final g in widget.groups)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${g.noteIds.length} note${g.noteIds.length == 1 ? '' : 's'}',
              ),
              trailing: const Icon(LucideIcons.plus, size: 18),
              onTap: () => _run(() => widget.onAdd(g)),
            ),
        ],
      ],
    ),
  );
}
