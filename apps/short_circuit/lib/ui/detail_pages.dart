part of '../main.dart';

class GeminiSettingsPage extends StatefulWidget {
  const GeminiSettingsPage({super.key});

  @override
  State<GeminiSettingsPage> createState() => _GeminiSettingsPageState();
}

class HermesSettingsPage extends StatefulWidget {
  const HermesSettingsPage({super.key});

  @override
  State<HermesSettingsPage> createState() => _HermesSettingsPageState();
}

class _HermesSettingsPageState extends State<HermesSettingsPage> {
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
    final url = await _hermes.baseUrl();
    final model = await _hermes.model();
    _url.text = url == _defaultHermesBaseUrl ? '' : url;
    _key.text = await _hermes.apiKey() ?? '';
    _model.text = model == _defaultHermesModel ? '' : model;
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _save({bool test = false}) async {
    setState(() => _busy = true);
    try {
      await _hermes.save(
        apiKey: _key.text,
        baseUrl: _url.text,
        model: _model.text,
      );
      if (test) await _hermes.testConnection();
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
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
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
                FilledButton.icon(
                  onPressed: _busy ? null : () => _save(test: true),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(_busy ? 'Testing…' : 'Save and test AI'),
                ),
                const SizedBox(height: 10),
                ScButton(
                  label: 'Save without testing',
                  onPressed: _busy ? null : _save,
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
                        icon: Icon(
                          _obscureKey ? Icons.visibility : Icons.visibility_off,
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
                  FilledButton.icon(
                    onPressed: _saving || _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(_testing ? 'Testing…' : 'Save and test Gemini'),
                  ),
                  const SizedBox(height: 10),
                  ScButton(
                    label: 'Clear Gemini settings',
                    danger: true,
                    onPressed: _saving || _testing ? null : _clear,
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
  });

  final DateTime createdAt;
  final String noteId;
  final String category;
  final String title;
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

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  late String _title;
  late String _transcript;
  late String _category;
  bool _forcing = false;
  bool _extractingReminder = false;

  Future<void> _approveSuggestion(NoteActionSuggestion suggestion) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use this suggestion?'),
        content: Text(
          '${suggestion.title}${suggestion.details.isEmpty ? '' : '\n\n${suggestion.details}'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (suggestion.type == 'task') {
      await widget.onAddTask(suggestion.title, suggestion.details);
    } else {
      final when = DateTime.tryParse(suggestion.scheduledAt ?? '');
      if (when == null) {
        _snack(
          'This suggestion needs a clear date and time before it can open Calendar.',
        );
        return;
      }
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
    _snack('Suggestion approved.');
  }

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _transcript = widget.transcript;
    _category = widget.category;
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
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('No dated reminder found'),
            content: const Text(
              'Gemini could not find a clear reminder date or time in this note.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        );
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Open Calendar'),
            ),
          ],
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

  Future<void> _delete() async {
    final confirmed = await _confirmDeleteNote(context);
    if (!confirmed || !mounted) return;
    await widget.onDeleteNote(widget.noteId);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    unawaited(_relayChannel.invokeMethod<void>('stopPlayback'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.createdAt.toLocal();
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
            ScTitle(_title),
            const SizedBox(height: 8),
            Text(
              'Transcribed · AI reviewed · ${_category.replaceAll('_', ' ')}${widget.language?.isNotEmpty == true ? ' · ${widget.language}' : ''}',
              style: const TextStyle(
                color: Sc.muted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            const ScGroupLabel('Transcript'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Sc.warmCard,
                borderRadius: BorderRadius.circular(18),
              ),
              child: SelectableText(
                _transcript,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.summary?.isNotEmpty == true) ...[
              const SizedBox(height: 20),
              const ScGroupLabel('Summary'),
              Text(
                widget.summary!,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: Sc.muted,
                ),
              ),
            ],
            if (widget.englishTranslation?.isNotEmpty == true &&
                widget.englishTranslation != _transcript) ...[
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
                  widget.englishTranslation!,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ],
            if (widget.categories.isNotEmpty || widget.tags.isNotEmpty) ...[
              const SizedBox(height: 20),
              const ScGroupLabel('Metadata'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ...widget.categories.map((item) => Chip(label: Text(item))),
                  ...widget.tags.map((item) => Chip(label: Text('#$item'))),
                ],
              ),
            ],
            if (widget.suggestions
                .where((item) => item.state == 'pending')
                .isNotEmpty) ...[
              const SizedBox(height: 22),
              const ScGroupLabel('Suggested actions'),
              for (final suggestion in widget.suggestions.where(
                (item) => item.state == 'pending',
              ))
                Column(
                  children: [
                    ScRow(
                      title: suggestion.title,
                      caption: suggestion.details.isEmpty
                          ? suggestion.type.replaceAll('_', ' ')
                          : suggestion.details,
                      trailing: const Text(
                        'Review',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Sc.accent,
                        ),
                      ),
                      onTap: () => _approveSuggestion(suggestion),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () async {
                            await widget.onSuggestionState(
                              widget.noteId,
                              suggestion.id,
                              'dismissed',
                            );
                            _snack('Suggestion dismissed.');
                          },
                          child: const Text('Dismiss'),
                        ),
                        const SizedBox(width: 6),
                        FilledButton.tonal(
                          onPressed: () => _approveSuggestion(suggestion),
                          child: const Text('Approve'),
                        ),
                      ],
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
                trailing: const Text(
                  'Add task',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xff6d5e51),
                  ),
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
                trailing: const Text(
                  'Create',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xff6d5e51),
                  ),
                ),
                onTap: _extractingReminder ? null : _createReminder,
              ),
            ],
            const SizedBox(height: 22),
            ScButton(
              label: 'Play recording',
              icon: Icons.play_arrow,
              onPressed: widget.audioPath == null
                  ? null
                  : () => widget.onPlayNote(widget.audioPath),
            ),
            const SizedBox(height: 10),
            ScButton(
              label: _forcing ? 'Transcribing…' : 'Transcribe again',
              icon: Icons.refresh,
              busy: _forcing,
              onPressed: _transcribeAgain,
            ),
            const SizedBox(height: 10),
            ScButton(label: 'Delete note', danger: true, onPressed: _delete),
          ],
        ),
      ),
    );
  }
}
