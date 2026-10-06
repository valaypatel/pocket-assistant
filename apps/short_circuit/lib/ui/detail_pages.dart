part of '../main.dart';

class GeminiSettingsPage extends StatefulWidget {
  const GeminiSettingsPage({super.key});

  @override
  State<GeminiSettingsPage> createState() => _GeminiSettingsPageState();
}

class AiServiceSettingsPage extends StatefulWidget {
  const AiServiceSettingsPage({super.key});

  @override
  State<AiServiceSettingsPage> createState() => _AiServiceSettingsPageState();
}

class _AiServiceSettingsPageState extends State<AiServiceSettingsPage> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Built-in defaults are never shown as if the user had typed them.
    final url = await _ai.baseUrl();
    final model = await _ai.model();
    _url.text = url == _defaultAiBaseUrl ? '' : url;
    _key.text = await _ai.apiKey() ?? '';
    _model.text = model == _defaultAiModel ? '' : model;
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _save({bool test = false}) async {
    setState(() => _busy = true);
    try {
      await _ai.save(apiKey: _key.text, baseUrl: _url.text, model: _model.text);
      if (test) await _ai.testConnection();
      _snack(test ? 'AI service is connected.' : 'AI settings saved securely.');
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
              children: [
                ScBackRow(
                  label: 'Settings',
                  onBack: () => Navigator.pop(context),
                  eyebrow: 'AI service',
                ),
                const ScTitle('AI service'),
                const SizedBox(height: 8),
                const Text(
                  'Your AI service turns transcripts into headings, summaries, and suggested actions. It stays in the app; Circuit never receives your key.',
                  style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 22),
                const ScGroupLabel('Base URL'),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: 'https://your-service.example/v1',
                  ),
                ),
                const SizedBox(height: 18),
                const ScGroupLabel('API key'),
                TextField(
                  controller: _key,
                  obscureText: _obscure,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      tooltip: 'Show or hide the key',
                      icon: Icon(
                        _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const ScGroupLabel('Model'),
                TextField(
                  controller: _model,
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'Model name'),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: ScIconButton(
                        expand: true,
                        size: 54,
                        icon: LucideIcons.flaskConical,
                        tone: ScTone.primary,
                        busy: _busy,
                        tooltip: 'Save and test the AI service',
                        onPressed: _busy ? null : () => _save(test: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ScIconButton(
                      size: 54,
                      icon: LucideIcons.save,
                      tooltip: 'Save without testing',
                      onPressed: _busy ? null : _save,
                    ),
                  ],
                ),
              ],
            ),
    ),
  );
}

class _GeminiSettingsPageState extends State<GeminiSettingsPage> {
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController(text: _defaultGeminiModel);
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await _gemini.apiKey();
    final model = await _gemini.model();
    if (!mounted) return;
    _apiKeyController.text = key ?? '';
    _modelController.text = model;
    setState(() => _loading = false);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _gemini.save(
        apiKey: _apiKeyController.text,
        model: _modelController.text,
      );
      _snack('Gemini settings saved securely.');
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    await _save();
    if (!mounted) return;
    setState(() => _testing = true);
    try {
      await _gemini.testConnection();
      _snack('Gemini is connected.');
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _showError(Object error) =>
      _snack(error.toString().replaceFirst('Exception: ', ''));

  Future<void> _clear() async {
    await _gemini.clear();
    _apiKeyController.clear();
    _modelController.text = _defaultGeminiModel;
    _snack('Gemini settings cleared.');
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
                children: [
                  ScBackRow(
                    label: 'Settings',
                    onBack: () => Navigator.pop(context),
                    eyebrow: 'Gemini',
                  ),
                  const ScTitle('AI settings'),
                  const SizedBox(height: 8),
                  const Text(
                    'Gemini runs from the app. Circuit never receives or stores your API key.',
                    style: TextStyle(
                      color: Sc.muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 22),
                  const ScGroupLabel('Gemini API key'),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: _obscureKey,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      suffixIcon: IconButton(
                        tooltip: 'Show or hide the key',
                        icon: Icon(
                          _obscureKey ? LucideIcons.eye : LucideIcons.eyeOff,
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const ScGroupLabel('Model'),
                  TextField(
                    controller: _modelController,
                    decoration: const InputDecoration(
                      hintText: _defaultGeminiModel,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The default model handles text and audio. Change it only if you need to.',
                    style: TextStyle(color: Sc.faint, fontSize: 11),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: ScIconButton(
                          expand: true,
                          size: 54,
                          icon: LucideIcons.flaskConical,
                          tone: ScTone.primary,
                          busy: _testing,
                          tooltip: 'Save and test Gemini',
                          onPressed: _saving || _testing ? null : _test,
                        ),
                      ),
                      const SizedBox(width: 10),
                      ScIconButton(
                        size: 54,
                        icon: LucideIcons.trash2,
                        tone: ScTone.danger,
                        tooltip: 'Clear Gemini settings',
                        onPressed: _saving || _testing ? null : _clear,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class TranscriptPage extends StatefulWidget {
  const TranscriptPage({
    super.key,
    required this.createdAt,
    required this.noteId,
    required this.category,
    required this.title,
    required this.status,
    required this.transcript,
    required this.onForceTranscribe,
    required this.audioPath,
    required this.onPlayNote,
    required this.onDeleteNote,
    required this.onCreateReminder,
    required this.onAddTask,
    this.summary,
    this.englishTranslation,
    this.language,
    this.categories = const [],
    this.tags = const [],
    this.suggestions = const [],
    required this.onSuggestionState,
    this.noteById,
    this.onEnrich,
    this.onOpenChat,
    this.onEditNote,
  });

  final DateTime createdAt;
  final String noteId;
  final String category;
  final String title;
  final String status;
  final String transcript;
  final Future<GeminiTranscription?> Function(String noteId) onForceTranscribe;
  final String? audioPath;
  final Future<void> Function(String? path) onPlayNote;
  final Future<void> Function(String noteId) onDeleteNote;
  final Future<ReminderDraft?> Function(String transcript) onCreateReminder;
  final Future<void> Function(String title, String? detail) onAddTask;
  final String? summary;
  final String? englishTranslation;
  final String? language;
  final List<String> categories;
  final List<String> tags;
  final List<NoteActionSuggestion> suggestions;
  final Future<void> Function(String noteId, String suggestionId, String state)
  onSuggestionState;

  /// Lets the page show the latest saved version of its note, so it updates
  /// while an AI review runs in the background.
  final CircuitNote? Function(String noteId)? noteById;

  /// Runs the AI review of this note again.
  final Future<void> Function(String noteId)? onEnrich;

  /// Opens the chat about this note.
  final VoidCallback? onOpenChat;

  /// Saves a hand-edited title and transcript. Hides the edit button when null.
  final Future<void> Function(String noteId, String title, String transcript)?
  onEditNote;

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  late String _title;
  late String _transcript;
  late String _category;
  bool _forcing = false;
  bool _extractingReminder = false;
  Timer? _ticker;

  CircuitNote? get _live => widget.noteById?.call(widget.noteId);

  Future<void> _approveSuggestion(NoteActionSuggestion suggestion) async {
    final when = suggestion.type == 'task'
        ? null
        : DateTime.tryParse(suggestion.scheduledAt ?? '');
    // Without a clear date and time there is nothing for Calendar to open, so
    // the suggestion becomes a task instead of a dead end.
    final asTask = when == null;
    final note = suggestion.type != 'task' && when == null
        ? '\n\nNo date or time was found, so this will be a task.'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(asTask ? 'Add to your tasks?' : 'Add to Calendar?'),
        content: Text(
          '${suggestion.title}${suggestion.details.isEmpty ? '' : '\n\n${suggestion.details}'}$note',
        ),
        actions: scDialogActions(
          context,
          confirmIcon: asTask ? LucideIcons.listPlus : LucideIcons.calendarPlus,
          confirmTooltip: asTask ? 'Add as task' : 'Open Calendar',
          onCancel: () => Navigator.pop(context, false),
          onConfirm: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (confirmed != true) return;
    if (when == null) {
      await widget.onAddTask(suggestion.title, suggestion.details);
    } else {
      await _relayChannel.invokeMethod<void>('openCalendarEvent', {
        'title': suggestion.title,
        'description': suggestion.details,
        'startMillis': when.millisecondsSinceEpoch,
        'endMillis': when
            .add(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
      });
    }
    await widget.onSuggestionState(widget.noteId, suggestion.id, 'approved');
    _snack(asTask ? 'Added to your tasks.' : 'Suggestion approved.');
  }

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _transcript = widget.transcript;
    _category = widget.category;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _actionable =>
      {'reminder', 'task', 'calendar_event'}.contains(_category);

  Future<void> _createReminder() async {
    setState(() => _extractingReminder = true);
    try {
      final draft = await widget.onCreateReminder(_transcript);
      if (!mounted || draft == null) return;
      if (!draft.hasReminder || draft.scheduledAt == null) {
        final addTask = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('No date or time found'),
            content: const Text(
              'This note has no clear date or time for Calendar. Add it to your tasks instead?',
            ),
            actions: scDialogActions(
              dialogContext,
              confirmIcon: LucideIcons.listPlus,
              confirmTooltip: 'Add as task',
              onCancel: () => Navigator.pop(dialogContext, false),
              onConfirm: () => Navigator.pop(dialogContext, true),
            ),
          ),
        );
        if (addTask == true) {
          await widget.onAddTask(_title, null);
          _snack('Added to your tasks');
        }
        return;
      }
      final date = draft.scheduledAt!.toLocal();
      final dateText =
          '${date.day}/${date.month}/${date.year} at ${_two(date.hour)}:${_two(date.minute)}';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Create calendar reminder?'),
          content: Text('${draft.title}\n$dateText\n\n${draft.details}'),
          actions: scDialogActions(
            dialogContext,
            confirmIcon: LucideIcons.calendarPlus,
            confirmTooltip: 'Open Calendar',
            onCancel: () => Navigator.pop(dialogContext, false),
            onConfirm: () => Navigator.pop(dialogContext, true),
          ),
        ),
      );
      if (confirmed == true && mounted) {
        await _relayChannel.invokeMethod<void>('openCalendarEvent', {
          'title': draft.title,
          'description': draft.details,
          'startMillis': date.millisecondsSinceEpoch,
          'endMillis': date
              .add(const Duration(minutes: 30))
              .millisecondsSinceEpoch,
        });
      }
    } finally {
      if (mounted) setState(() => _extractingReminder = false);
    }
  }

  Future<void> _transcribeAgain() async {
    setState(() => _forcing = true);
    try {
      final updated = await widget.onForceTranscribe(widget.noteId);
      if (!mounted || updated == null) return;
      setState(() {
        _title = updated.title;
        _transcript = updated.transcript;
        _category = updated.category;
      });
      _snack('Transcript updated and saved.');
    } finally {
      if (mounted) setState(() => _forcing = false);
    }
  }

  Future<void> _edit() async {
    final live = _live;
    final edited = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _EditNoteDialog(
        title: live?.title ?? _title,
        transcript: live?.transcript ?? _transcript,
      ),
    );
    if (edited == null || !mounted) return;
    final (title, transcript) = edited;
    if (title.isEmpty) {
      _snack('A note needs a title.');
      return;
    }
    await widget.onEditNote!(widget.noteId, title, transcript);
    if (!mounted) return;
    setState(() {
      _title = title;
      _transcript = transcript;
    });
    _snack('Note updated.');
  }

  Future<void> _delete() async {
    final confirmed = await _confirmDeleteNote(context);
    if (!confirmed || !mounted) return;
    await widget.onDeleteNote(widget.noteId);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_relayChannel.invokeMethod<void>('stopPlayback'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.createdAt.toLocal();
    final live = _live;
    final status = live?.status ?? widget.status;
    final summary = live?.summary ?? widget.summary;
    final translation = live?.englishTranslation ?? widget.englishTranslation;
    final language = live?.language ?? widget.language;
    final categories = live?.categories ?? widget.categories;
    final tags = live?.tags ?? widget.tags;
    final suggestions = live?.actionSuggestions ?? widget.suggestions;
    final enriching = live?.enrichmentStatus == 'enriching';
    final hasTranscript = _transcript.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          children: [
            ScBackRow(
              label: 'Notes',
              onBack: () => Navigator.pop(context),
              eyebrow:
                  '${_dayLabel(widget.createdAt)} · ${_two(local.hour)}:${_two(local.minute)}',
            ),
            ScTitle(live?.title ?? _title),
            const SizedBox(height: 8),
            Text(
              '$status · ${_category.replaceAll('_', ' ')}${language?.isNotEmpty == true ? ' · $language' : ''}',
              style: const TextStyle(
                color: Sc.muted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            const ScGroupLabel('Transcript'),
            if (widget.onEditNote != null)
              Align(
                alignment: Alignment.centerRight,
                child: ScIconButton(
                  size: 40,
                  icon: LucideIcons.pencil,
                  tooltip: 'Edit note',
                  onPressed: _edit,
                ),
              ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Sc.warmCard,
                borderRadius: BorderRadius.circular(18),
              ),
              child: _transcript.trim().isEmpty
                  ? const Text(
                      'Transcript not available yet. The recording will appear here after sync and transcription.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Sc.muted,
                      ),
                    )
                  : SelectableText(
                      _transcript,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            if (summary?.isNotEmpty == true) ...[
              const SizedBox(height: 20),
              const ScGroupLabel('Summary'),
              Text(
                summary!,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: Sc.muted,
                ),
              ),
            ],
            if (translation?.isNotEmpty == true &&
                translation != _transcript) ...[
              const SizedBox(height: 20),
              const ScGroupLabel('English translation'),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Sc.warmCard,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SelectableText(
                  translation!,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ],
            if (categories.isNotEmpty || tags.isNotEmpty) ...[
              const SizedBox(height: 20),
              const ScGroupLabel('Metadata'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ...categories.map((item) => ScChip(item)),
                  ...tags.map((item) => ScChip(item, tag: true)),
                ],
              ),
            ],
            if (suggestions
                .where((item) => item.state == 'pending')
                .isNotEmpty) ...[
              const SizedBox(height: 22),
              const ScGroupLabel('Suggested actions'),
              for (final suggestion in suggestions.where(
                (item) => item.state == 'pending',
              ))
                Column(
                  children: [
                    ScRow(
                      title: suggestion.title,
                      caption: suggestion.details.isEmpty
                          ? suggestion.type.replaceAll('_', ' ')
                          : suggestion.details,
                      trailing: const Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: Sc.accent,
                      ),
                      onTap: () => _approveSuggestion(suggestion),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ScIconButton(
                            size: 40,
                            icon: LucideIcons.x,
                            tooltip: 'Dismiss suggestion',
                            onPressed: () async {
                              await widget.onSuggestionState(
                                widget.noteId,
                                suggestion.id,
                                'dismissed',
                              );
                              _snack('Suggestion dismissed.');
                            },
                          ),
                          const SizedBox(width: 8),
                          ScIconButton(
                            size: 40,
                            icon: LucideIcons.check,
                            tooltip: 'Approve suggestion',
                            tone: ScTone.primary,
                            onPressed: () => _approveSuggestion(suggestion),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
            if (_actionable) ...[
              const SizedBox(height: 22),
              const ScGroupLabel('Detected action'),
              ScRow(
                title: 'Add to tasks',
                caption: _title,
                trailing: const Icon(
                  LucideIcons.listPlus,
                  size: 20,
                  color: Color(0xff6d5e51),
                ),
                onTap: () async {
                  await widget.onAddTask(_title, null);
                  _snack('Added to your tasks');
                },
              ),
              ScRow(
                title: 'Calendar reminder',
                caption: _extractingReminder
                    ? 'Checking the note…'
                    : 'Find a date and time in this note',
                trailing: const Icon(
                  LucideIcons.calendarPlus,
                  size: 20,
                  color: Color(0xff6d5e51),
                ),
                onTap: _extractingReminder ? null : _createReminder,
              ),
            ],
            const SizedBox(height: 22),
            ScActionBar(
              children: [
                ScIconButton(
                  icon: LucideIcons.play,
                  tone: ScTone.dark,
                  caption: 'Play',
                  tooltip: widget.audioPath == null
                      ? 'Play recording (not on this phone yet)'
                      : 'Play recording',
                  onPressed: widget.audioPath == null
                      ? null
                      : () => widget.onPlayNote(widget.audioPath),
                ),
                ScIconButton(
                  icon: LucideIcons.messageCircle,
                  caption: 'Ask',
                  tone: ScTone.primary,
                  tooltip: hasTranscript
                      ? 'Ask about this note'
                      : 'Ask about this note (needs a transcript first)',
                  onPressed: hasTranscript ? widget.onOpenChat : null,
                ),
                ScIconButton(
                  icon: LucideIcons.sparkles,
                  caption: 'AI review',
                  busy: enriching,
                  tooltip: !hasTranscript
                      ? 'Run AI review (needs a transcript first)'
                      : enriching
                      ? 'AI review running'
                      : 'Run AI review again',
                  onPressed: hasTranscript && widget.onEnrich != null
                      ? () => widget.onEnrich!(widget.noteId)
                      : null,
                ),
                ScIconButton(
                  icon: LucideIcons.languages,
                  caption: 'Transcribe',
                  busy: _forcing,
                  tooltip: _forcing ? 'Transcribing' : 'Transcribe again',
                  onPressed: _transcribeAgain,
                ),
                ScIconButton(
                  icon: LucideIcons.trash2,
                  caption: 'Delete',
                  tone: ScTone.danger,
                  tooltip: 'Delete note',
                  onPressed: _delete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Edits a note's title and transcript; pops a (title, transcript) pair on save.
class _EditNoteDialog extends StatefulWidget {
  const _EditNoteDialog({required this.title, required this.transcript});

  final String title;
  final String transcript;

  @override
  State<_EditNoteDialog> createState() => _EditNoteDialogState();
}

class _EditNoteDialogState extends State<_EditNoteDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _transcript = TextEditingController(text: widget.transcript);

  @override
  void dispose() {
    _title.dispose();
    _transcript.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit note'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _transcript,
            decoration: const InputDecoration(labelText: 'Transcript'),
            minLines: 4,
            maxLines: 12,
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
      ),
    ),
    actions: scDialogActions(
      context,
      confirmIcon: LucideIcons.check,
      confirmTooltip: 'Save changes',
      onCancel: () => Navigator.pop(context),
      onConfirm: () =>
          Navigator.pop(context, (_title.text.trim(), _transcript.text.trim())),
    ),
  );
}
