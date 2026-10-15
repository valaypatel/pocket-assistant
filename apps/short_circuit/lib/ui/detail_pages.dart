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
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
              children: [
                ScBackRow(
                  label: 'Settings',
                  onBack: () => Navigator.pop(context),
                  eyebrow: 'AI service',
                ),
                const ScTitle('AI service'),
                const SizedBox(height: 8),
                Text(
                  'Your AI service turns transcripts into headings, summaries, and suggested actions. It stays in the app; Circuit never receives your key.',
                  style: TextStyle(
                    color: context.sc.muted,
                    fontSize: 12,
                    height: 1.4,
                  ),
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
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
                children: [
                  ScBackRow(
                    label: 'Settings',
                    onBack: () => Navigator.pop(context),
                    eyebrow: 'Gemini',
                  ),
                  const ScTitle('AI settings'),
                  const SizedBox(height: 8),
                  Text(
                    'Gemini runs from the app. Circuit never receives or stores your API key.',
                    style: TextStyle(
                      color: context.sc.muted,
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
                  Text(
                    'The default model handles text and audio. Change it only if you need to.',
                    style: TextStyle(color: context.sc.muted, fontSize: 11),
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
    this.onUseRun,
    required this.onForceTranscribe,
    this.onSyncNote,
    required this.audioPath,
    required this.onPlayNote,
    this.onPlayMoment,
    this.playerBar,
    required this.onDeleteNote,
    this.onDeletePhoneOnly,
    required this.onCreateReminder,
    required this.onAddTask,
    this.onAddReminder,
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
    this.isCall = false,
  });

  final DateTime createdAt;
  final String noteId;
  final String category;
  final String title;
  final String status;
  final String transcript;
  final Future<GeminiTranscription?> Function(String noteId) onForceTranscribe;

  /// Asks Circuit to send just this note. Shown while the note has no audio on the phone yet.
  final Future<void> Function(String noteId)? onSyncNote;
  final String? audioPath;
  final Future<void> Function(String? path) onPlayNote;

  /// Plays the note from a Moment: the note's id and the time from the start of the whole note.
  /// The Moments list is not shown when this is null.
  final Future<void> Function(String noteId, int noteMs)? onPlayMoment;

  /// The player bar (pause, stop, position) shown at the bottom while a note plays, built by
  /// the app so it is the same bar as on Home and Notes. It appears only while something plays.
  final Widget Function()? playerBar;
  final Future<void> Function(String noteId) onDeleteNote;

  /// Set for a note that is also on Circuit: deletes only the phone's copy.
  final Future<void> Function(String noteId)? onDeletePhoneOnly;
  final Future<ReminderDraft?> Function(String transcript, DateTime recordedAt)
  onCreateReminder;
  final Future<void> Function(String title, String? detail) onAddTask;

  /// Adds a task that rings an app notification at [at]; false when notifications are off.
  final Future<bool> Function(String title, String? detail, DateTime at)?
  onAddReminder;
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

  /// Makes the transcription at this index the working transcript again.
  final Future<void> Function(String noteId, int runIndex)? onUseRun;

  /// Saves a hand-edited title and transcript. Hides the edit button when null.
  final Future<void> Function(String noteId, String title, String transcript)?
  onEditNote;

  /// The recording was judged to be a phone call.
  final bool isCall;

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  late String _title;
  late String _transcript;
  late String _category;
  String _readingTab = 'Summary';
  bool _forcing = false;
  bool _extractingReminder = false;
  Timer? _ticker;

  /// Bookmarks added on Circuit during the recording, in ms from the start of the note.
  List<int> _moments = const [];

  /// How long the recording plays, worked out from its files; 0 until known.
  int _lengthMs = 0;

  CircuitNote? get _live => widget.noteById?.call(widget.noteId);

  /// Sets a reminder that rings as an app notification. [when] is what the AI found; the
  /// person can change it first. Without a usable future time the note becomes a task.
  Future<void> _remindMe({
    required String title,
    required String details,
    required DateTime? found,
  }) async {
    var when = found != null && found.isAfter(DateTime.now()) ? found : null;
    final passed = found != null && when == null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: Text(when == null ? 'Add to your tasks?' : 'Remind you?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$title${details.isEmpty ? '' : '\n\n$details'}'),
              const SizedBox(height: 12),
              Text(
                when != null
                    ? reminderLabel(when!)
                    : passed
                    ? 'That time has already passed.'
                    : 'No date or time was found.',
                style: ScType.caption.copyWith(color: dialogContext.sc.muted),
              ),
              TextButton.icon(
                icon: const Icon(LucideIcons.clock, size: 16),
                label: Text(when == null ? 'Pick a time' : 'Change time'),
                onPressed: () async {
                  final picked = await pickReminderTime(
                    dialogContext,
                    initial: when,
                  );
                  if (picked != null) setLocal(() => when = picked);
                },
              ),
            ],
          ),
          actions: scDialogActions(
            dialogContext,
            confirmIcon: when == null
                ? LucideIcons.listPlus
                : LucideIcons.bellRing,
            confirmTooltip: when == null ? 'Add as task' : 'Set reminder',
            onCancel: () => Navigator.pop(dialogContext, false),
            onConfirm: () => Navigator.pop(dialogContext, true),
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    final at = when;
    if (at == null || widget.onAddReminder == null) {
      await widget.onAddTask(title, details);
      _snack('Added to your tasks.');
      return;
    }
    final allowed = await widget.onAddReminder!(title, details, at);
    _snack(
      allowed ? 'Reminder set for ${reminderLabel(at)}.' : 'Saved as a task, but notifications are off for Circuit. Turn them on in Android settings to hear it.',
    );
  }

  Future<void> _approveSuggestion(NoteActionSuggestion suggestion) async {
    if (suggestion.type == 'reminder' && widget.onAddReminder != null) {
      await _remindMe(
        title: suggestion.title,
        details: suggestion.details,
        found: DateTime.tryParse(suggestion.scheduledAt ?? ''),
      );
      await widget.onSuggestionState(widget.noteId, suggestion.id, 'approved');
      return;
    }
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
          '${suggestion.title}${when == null ? '' : '\n${reminderLabel(when)}'}'
          '${suggestion.details.isEmpty ? '' : '\n\n${suggestion.details}'}$note',
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
    unawaited(_loadMoments());
  }

  @override
  void didUpdateWidget(TranscriptPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioPath != widget.audioPath) unawaited(_loadMoments());
  }

  Future<void> _loadMoments() async {
    final files = _live?.audioFiles ?? [?widget.audioPath];
    if (files.isEmpty) return;
    var total = 0;
    for (final path in files) {
      try {
        total += await Moments.partDurationMs(path);
      } catch (_) {
        // a file that cannot be read adds nothing
      }
    }
    if (mounted && total != _lengthMs) setState(() => _lengthMs = total);
    final live = _live;
    final found = live == null
        ? await Moments.forNote(files)
        : await Moments.allForNote(live);
    final same =
        found.length == _moments.length &&
        Iterable<int>.generate(found.length)
            .every((i) => found[i] == _moments[i]);
    if (!mounted || same) return;
    setState(() => _moments = found);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _actionable =>
      {'reminder', 'task', 'calendar_event'}.contains(_category);

  Future<void> _createReminder({bool inApp = false}) async {
    setState(() => _extractingReminder = true);
    try {
      final draft = await widget.onCreateReminder(
        _transcript,
        widget.createdAt,
      );
      if (!mounted || draft == null) return;
      if (inApp) {
        await _remindMe(
          title: draft.title,
          details: draft.details,
          found: draft.hasReminder ? draft.scheduledAt : null,
        );
        return;
      }
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

  TextStyle _readStyle(BuildContext context, bool filled) => ScType.transcript
      .copyWith(color: filled ? context.sc.ink : context.sc.muted);

  String _runLabel(TranscriptRun run) =>
      '${run.model.isEmpty ? 'Unknown model' : run.model} · ${_dayLabel(run.at)} ${_two(run.at.hour)}:${_two(run.at.minute)}';

  /// The transcript as a first-class thing: where it came from, whether it was edited, what the AI
  /// review has seen, and the two actions that matter (edit it, then review it).
  Widget _transcriptPanel(
    BuildContext context,
    CircuitNote? live,
    bool hasTranscript,
    bool enriching,
  ) {
    final runs = live?.transcriptRuns ?? const <TranscriptRun>[];
    final edited = live?.transcriptEdited ?? false;
    final stale = live?.reviewStale ?? false;
    final reviewed = live?.enrichmentStatus == 'ready';
    final source = runs.isEmpty
        ? 'Original transcript'
        : edited
        ? 'Edited by you · original by ${runs.last.model}'
        : 'Original · ${_runLabel(runs.last)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasTranscript) ...[
          Row(
            children: [
              Icon(
                edited ? LucideIcons.pencil : LucideIcons.fileText,
                size: 16,
                color: context.sc.muted,
              ),
              const SizedBox(width: ScSpace.sm),
              Expanded(
                child: Text(
                  source,
                  style: ScType.caption.copyWith(color: context.sc.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: ScSpace.md),
        ],
        if (stale && hasTranscript && !enriching) ...[
          ScStatusStrip(
            tone: ScStripTone.neutral,
            leading: LucideIcons.refreshCw,
            title: 'The summary is out of date',
            detail: 'You changed the transcript after the AI review.',
            actions: [
              if (widget.onEnrich != null)
                TextButton(
                  onPressed: () => widget.onEnrich!(widget.noteId),
                  child: const Text('Review again'),
                ),
            ],
          ),
          const SizedBox(height: ScSpace.md),
        ],
        SelectableText(
          hasTranscript ? _transcript : 'Transcript not available yet. The recording will appear here after sync and transcription.',
          style: _readStyle(context, hasTranscript),
        ),
        if (hasTranscript) ...[
          const SizedBox(height: ScSpace.lg),
          Wrap(
            spacing: ScSpace.sm,
            runSpacing: ScSpace.sm,
            children: [
              if (widget.onEditNote != null)
                ScActionChip(
                  icon: LucideIcons.pencil,
                  label: 'Edit transcript',
                  onPressed: _edit,
                ),
              if (widget.onEnrich != null)
                ScActionChip(
                  icon: LucideIcons.sparkles,
                  label: enriching
                      ? 'AI review running'
                      : reviewed && !stale
                      ? 'Review again'
                      : 'Run AI review',
                  onPressed: enriching
                      ? null
                      : () => widget.onEnrich!(widget.noteId),
                ),
              if (edited && runs.isNotEmpty && widget.onUseRun != null)
                ScActionChip(
                  icon: LucideIcons.undo2,
                  label: 'Back to original',
                  onPressed: () async {
                    await widget.onUseRun!(widget.noteId, runs.length - 1);
                    if (!mounted) return;
                    setState(() => _transcript = runs.last.text);
                    _snack('Original transcript restored.');
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Every transcription of this note, to read side by side and to pick one as the working copy.
  Future<void> _showVersions() async {
    final runs = _live?.transcriptRuns ?? const <TranscriptRun>[];
    if (runs.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.sc.bg,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .8,
        maxChildSize: .95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            const ScTitle('Transcript versions'),
            const SizedBox(height: ScSpace.sm),
            Text(
              'Each time this note is transcribed, the result is kept here with the model that wrote it.',
              style: ScType.caption.copyWith(color: context.sc.muted),
            ),
            const SizedBox(height: ScSpace.lg),
            for (var i = runs.length - 1; i >= 0; i--) ...[
              Container(
                padding: const EdgeInsets.all(ScSpace.lg),
                decoration: BoxDecoration(
                  color: context.sc.surface,
                  borderRadius: ScRadius.cardBorder,
                  border: Border.all(color: context.sc.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      i == runs.length - 1
                          ? 'Latest · ${_runLabel(runs[i])}'
                          : _runLabel(runs[i]),
                      style: ScType.label.copyWith(color: context.sc.ink),
                    ),
                    const SizedBox(height: ScSpace.sm),
                    SelectableText(
                      runs[i].text.isEmpty ? '(empty)' : runs[i].text,
                      style: ScType.body.copyWith(color: context.sc.ink),
                    ),
                    if (widget.onUseRun != null &&
                        runs[i].text != _transcript) ...[
                      const SizedBox(height: ScSpace.md),
                      ScActionChip(
                        icon: LucideIcons.check,
                        label: 'Use this version',
                        onPressed: () async {
                          await widget.onUseRun!(widget.noteId, i);
                          if (!mounted) return;
                          setState(() => _transcript = runs[i].text);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                          _snack('Using this version.');
                        },
                      ),
                    ] else if (runs[i].text == _transcript) ...[
                      const SizedBox(height: ScSpace.sm),
                      Text(
                        'This is the transcript in use.',
                        style: ScType.caption.copyWith(
                          color: context.sc.accentInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: ScSpace.md),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final choice = await _chooseNoteDelete(
      context,
      fromCircuit: widget.onDeletePhoneOnly != null,
    );
    if (choice == null || !mounted) return;
    if (choice == NoteDeleteChoice.phoneOnly) {
      await widget.onDeletePhoneOnly!(widget.noteId);
    } else {
      await widget.onDeleteNote(widget.noteId);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // Playback carries on when this page closes: the player bar has the Stop button, and
    // leaving the app still stops it.
    super.dispose();
  }

  /// The recording: play it, see how long it is, and jump to a Moment.
  Widget _playerCard(BuildContext context) {
    final p = context.sc;
    return Container(
      padding: const EdgeInsets.all(ScSpace.lg),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: ScRadius.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScPlayButton(
                onPressed: () => widget.onPlayNote(widget.audioPath),
              ),
              const SizedBox(width: ScSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Original recording', style: ScType.label),
                    Text(
                      _lengthMs >= 1000
                          ? nowPlayingClock(_lengthMs)
                          : 'Tap to listen',
                      style: ScType.caption.copyWith(color: p.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_moments.isNotEmpty && widget.onPlayMoment != null) ...[
            const SizedBox(height: ScSpace.lg),
            Text(
              'MOMENTS',
              style: ScType.caption.copyWith(
                color: p.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: .9,
              ),
            ),
            const SizedBox(height: ScSpace.sm),
            Wrap(
              spacing: ScSpace.sm,
              runSpacing: ScSpace.sm,
              children: [
                for (final ms in _moments)
                  Semantics(
                    button: true,
                    label: 'Play from ${nowPlayingClock(ms)}',
                    excludeSemantics: true,
                    child: Material(
                      color: p.bg,
                      shape: StadiumBorder(side: BorderSide(color: p.line)),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: () => widget.onPlayMoment!(widget.noteId, ms),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 40),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: ScSpace.md + 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.bookmark,
                                  size: 16,
                                  color: p.accentInk,
                                ),
                                const SizedBox(width: ScSpace.xs + 2),
                                Text(nowPlayingClock(ms), style: ScType.label),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
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
    final isCall = live?.isCall ?? widget.isCall;
    final hasTranscript = _transcript.trim().isNotEmpty;
    return Scaffold(
      bottomNavigationBar: widget.playerBar?.call(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          children: [
            ScBackRow(
              label: 'Notes',
              onBack: () => Navigator.pop(context),
              eyebrow:
                  '${_dayLabel(widget.createdAt)} · ${_two(local.hour)}:${_two(local.minute)}'
                  ' · ${live?.source ?? noteSourceOf(widget.audioPath)}',
            ),
            Semantics(
              header: true,
              child: Text(live?.title ?? _title, style: ScType.display),
            ),
            const SizedBox(height: 8),
            Text(
              '$status · ${_category.replaceAll('_', ' ')}${language?.isNotEmpty == true ? ' · $language' : ''}',
              style: ScType.caption.copyWith(color: context.sc.muted),
            ),
            const SizedBox(height: 20),
            if ((live?.audioPath ?? widget.audioPath) == null &&
                !(live?.isText ?? false) &&
                widget.onSyncNote != null) ...[
              ValueListenableBuilder<SyncUiState>(
                valueListenable: syncUiState,
                builder: (context, sync, _) {
                  final syncing =
                      sync.active || status.startsWith('Sync queued');
                  final percent = sync.progress;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ScButton(
                        label: syncing
                            ? (percent == null
                                  ? 'Syncing…'
                                  : 'Syncing… $percent%')
                            : 'Sync this note from Circuit',
                        icon: LucideIcons.refreshCw,
                        busy: syncing,
                        onPressed: () => widget.onSyncNote!(widget.noteId),
                      ),
                      if (syncing && percent != null) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: percent / 100,
                            minHeight: 5,
                            color: context.sc.accent,
                            backgroundColor: context.sc.line,
                          ),
                        ),
                      ],
                      if (!syncing && sync.error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          sync.error!,
                          style: TextStyle(
                            color: context.sc.danger,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                'Only this note is sent. Hold Circuit\'s button for 2 seconds to send everything.',
                style: TextStyle(
                  color: context.sc.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (widget.audioPath != null) ...[
              _playerCard(context),
              const SizedBox(height: ScSpace.lg),
            ],
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final tab in [
                        if (summary?.isNotEmpty == true) 'Summary',
                        'Transcript',
                        if (translation?.isNotEmpty == true &&
                            translation != _transcript)
                          'Translation',
                      ])
                        TextButton(
                          onPressed: () => setState(() => _readingTab = tab),
                          style: TextButton.styleFrom(
                            foregroundColor:
                                (_readingTab == tab ||
                                    (_readingTab == 'Summary' &&
                                        summary?.isNotEmpty != true &&
                                        tab == 'Transcript'))
                                ? context.sc.accentInk
                                : context.sc.muted,
                            backgroundColor:
                                (_readingTab == tab ||
                                    (_readingTab == 'Summary' &&
                                        summary?.isNotEmpty != true &&
                                        tab == 'Transcript'))
                                ? context.sc.accentSoft
                                : Colors.transparent,
                            minimumSize: const Size(48, 48),
                          ),
                          child: Text(tab),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(LucideIcons.ellipsis),
                  onSelected: (choice) {
                    switch (choice) {
                      case 'edit':
                        _edit();
                      case 'review':
                        widget.onEnrich?.call(widget.noteId);
                      case 'transcribe':
                        _transcribeAgain();
                      case 'versions':
                        _showVersions();
                      case 'delete':
                        _delete();
                    }
                  },
                  itemBuilder: (context) => [
                    if (widget.onEditNote != null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit note'),
                      ),
                    PopupMenuItem(
                      value: 'review',
                      enabled:
                          hasTranscript &&
                          widget.onEnrich != null &&
                          !enriching,
                      child: Text(
                        enriching ? 'AI review running' : 'Run AI review again',
                      ),
                    ),
                    if ((live?.transcriptRuns.isNotEmpty ?? false))
                      PopupMenuItem(
                        value: 'versions',
                        child: Text(
                          'Transcript versions (${live!.transcriptRuns.length})',
                        ),
                      ),
                    PopupMenuItem(
                      value: 'transcribe',
                      enabled: !_forcing,
                      child: Text(
                        _forcing ? 'Transcribing' : 'Transcribe again',
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete note',
                        style: TextStyle(color: context.sc.danger),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_readingTab == 'Translation' && translation?.isNotEmpty == true)
              SelectableText(translation!, style: _readStyle(context, true))
            else if (_readingTab == 'Summary' && summary?.isNotEmpty == true)
              SelectableText(summary!, style: _readStyle(context, true))
            else
              _transcriptPanel(context, live, hasTranscript, enriching),
            const SizedBox(height: 20),
            if (widget.onOpenChat != null)
              ScButton(
                primary: true,
                icon: LucideIcons.messageCircle,
                label: 'Ask this note',
                onPressed: hasTranscript ? widget.onOpenChat : null,
              ),
            if (isCall || categories.isNotEmpty || tags.isNotEmpty) ...[
              const SizedBox(height: 20),
              const ScGroupLabel('Categories & tags'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (isCall) const ScChip('phone call'),
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
                      trailing: Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: context.sc.accent,
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
                            caption: 'Dismiss',
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
                            caption: 'Approve',
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
                trailing: Icon(
                  LucideIcons.listPlus,
                  size: 20,
                  color: context.sc.muted,
                ),
                onTap: () async {
                  await widget.onAddTask(_title, null);
                  _snack('Added to your tasks');
                },
              ),
              if (widget.onAddReminder != null)
                ScRow(
                  title: 'Remind me',
                  caption: _extractingReminder
                      ? 'Checking the note…'
                      : 'Ring a notification at the time in this note',
                  trailing: Icon(
                    LucideIcons.bellRing,
                    size: 20,
                    color: context.sc.muted,
                  ),
                  onTap: _extractingReminder
                      ? null
                      : () => _createReminder(inApp: true),
                ),
              ScRow(
                title: 'Calendar reminder',
                caption: _extractingReminder
                    ? 'Checking the note…'
                    : 'Find a date and time in this note',
                trailing: Icon(
                  LucideIcons.calendarPlus,
                  size: 20,
                  color: context.sc.muted,
                ),
                onTap: _extractingReminder ? null : _createReminder,
              ),
            ],
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
