part of '../main.dart';

class GeminiSettingsPage extends StatefulWidget {
  const GeminiSettingsPage({super.key});

  @override
  State<GeminiSettingsPage> createState() => _GeminiSettingsPageState();
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
      await _gemini.save(apiKey: _apiKeyController.text, model: _modelController.text);
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

  void _showError(Object error) => _snack(error.toString().replaceFirst('Exception: ', ''));

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
                  ScBackRow(label: 'Settings', onBack: () => Navigator.pop(context), eyebrow: 'Gemini'),
                  const ScTitle('AI settings'),
                  const SizedBox(height: 8),
                  const Text(
                    'Gemini runs from the app. Circuit never receives or stores your API key.',
                    style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
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
                        icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off, size: 20),
                        onPressed: () => setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const ScGroupLabel('Model'),
                  TextField(
                    controller: _modelController,
                    decoration: const InputDecoration(hintText: _defaultGeminiModel),
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
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(_testing ? 'Testing…' : 'Save and test Gemini'),
                  ),
                  const SizedBox(height: 10),
                  ScButton(label: 'Clear Gemini settings', danger: true, onPressed: _saving || _testing ? null : _clear),
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

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  late String _title;
  late String _transcript;
  late String _category;
  bool _forcing = false;
  bool _extractingReminder = false;

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

  bool get _actionable => {'reminder', 'task', 'calendar_event'}.contains(_category);

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
            content: const Text('Gemini could not find a clear reminder date or time in this note.'),
            actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
          ),
        );
        return;
      }
      final date = draft.scheduledAt!.toLocal();
      final dateText = '${date.day}/${date.month}/${date.year} at ${_two(date.hour)}:${_two(date.minute)}';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Create calendar reminder?'),
          content: Text('${draft.title}\n$dateText\n\n${draft.details}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
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
          'endMillis': date.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
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
              eyebrow: '${_dayLabel(widget.createdAt)} · ${_two(local.hour)}:${_two(local.minute)}',
            ),
            ScTitle(_title),
            const SizedBox(height: 8),
            Text(
              'Transcribed by Gemini · ${_category.replaceAll('_', ' ')}',
              style: const TextStyle(color: Sc.muted, fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 22),
            const ScGroupLabel('Transcript'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Sc.warmCard, borderRadius: BorderRadius.circular(18)),
              child: SelectableText(_transcript, style: const TextStyle(fontSize: 15, height: 1.5, fontWeight: FontWeight.w600)),
            ),
            if (_actionable) ...[
              const SizedBox(height: 22),
              const ScGroupLabel('Detected action'),
              ScRow(
                title: 'Add to tasks',
                caption: _title,
                trailing: const Text('Add task', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xff6d5e51))),
                onTap: () async {
                  await widget.onAddTask(_title, null);
                  _snack('Added to your tasks');
                },
              ),
              ScRow(
                title: 'Calendar reminder',
                caption: _extractingReminder ? 'Checking the note…' : 'Find a date and time in this note',
                trailing: const Text('Create', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xff6d5e51))),
                onTap: _extractingReminder ? null : _createReminder,
              ),
            ],
            const SizedBox(height: 22),
            ScButton(
              label: 'Play recording',
              icon: Icons.play_arrow,
              onPressed: widget.audioPath == null ? null : () => widget.onPlayNote(widget.audioPath),
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
