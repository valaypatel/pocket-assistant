part of '../main.dart';

/// Result of identifying a song clip: artwork, track, and what to do next.
class SongPage extends StatefulWidget {
  const SongPage({
    super.key,
    required this.noteId,
    required this.noteById,
    required this.onIdentify,
    required this.onPlay,
    required this.onDelete,
    this.onDeletePhoneOnly,
    required this.onOpenSettings,
    required this.onUseAsNote,
    this.openLink,
  });

  final String noteId;
  final CircuitNote? Function(String id) noteById;
  final Future<void> Function(String id) onIdentify;
  final Future<void> Function(String? path) onPlay;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function(String id)? onDeletePhoneOnly;
  final VoidCallback onOpenSettings;

  /// Turns a clip wrongly taken for a song back into a voice note.
  final Future<void> Function(String id) onUseAsNote;

  /// Opens the provider page; defaults to the phone's browser.
  final Future<bool> Function(Uri uri)? openLink;

  @override
  State<SongPage> createState() => _SongPageState();
}

class _SongPageState extends State<SongPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // The note changes in the background (sync, then recognition).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_relayChannel.invokeMethod<void>('stopPlayback'));
    super.dispose();
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
      await widget.onDelete(widget.noteId);
    }
    if (mounted) Navigator.pop(context);
  }

  void _useAsNote() {
    unawaited(widget.onUseAsNote(widget.noteId));
    Navigator.pop(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Transcribing as a voice note…')),
      );
  }

  Future<bool> _open(Uri uri) async {
    try {
      return await (widget.openLink ?? launchUrl)(uri);
    } catch (_) {
      return false;
    }
  }

  void _couldNotOpen() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Could not open the link.')));
  }

  Future<void> _openProvider(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !await _open(uri)) _couldNotOpen();
  }

  /// Opens the Spotify app on a search for this track, or the web page if the
  /// app is not installed.
  Future<void> _openSpotify(SongResult song) async {
    for (final uri in spotifyCandidates(song)) {
      if (await _open(uri)) return;
    }
    _couldNotOpen();
  }

  Widget _artwork(SongResult song) {
    final url = song.artworkUrl;
    final placeholder = Container(
      color: Sc.surface,
      alignment: Alignment.center,
      child: const Icon(LucideIcons.music, size: 44, color: Sc.faint),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        width: 220,
        height: 220,
        child: url == null
            ? placeholder
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : placeholder,
              ),
      ),
    );
  }

  Widget _status(IconData icon, String title, String message, {Color? tone}) =>
      Column(
        children: [
          Icon(icon, size: 34, color: tone ?? Sc.faint),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Sc.muted, fontSize: 13, height: 1.4),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final note = widget.noteById(widget.noteId);
    final song = note?.song ?? const SongResult();
    final hasAudio = note?.audioPath != null;
    final waitingForSync = note != null && !hasAudio;
    final busy = song.busy && hasAudio;
    final local = (note?.createdAt ?? DateTime.now()).toLocal();

    final Widget body;
    if (note == null) {
      body = _status(
        LucideIcons.music,
        'This clip is gone',
        'It was deleted. Go back to your notes.',
      );
    } else if (song.matched) {
      body = Column(
        children: [
          Center(child: _artwork(song)),
          const SizedBox(height: 20),
          Text(
            song.title ?? 'Unknown title',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              letterSpacing: -.5,
            ),
          ),
          if (song.artist != null) ...[
            const SizedBox(height: 4),
            Text(
              song.artist!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: Sc.muted),
            ),
          ],
          if (song.album != null) ...[
            const SizedBox(height: 2),
            Text(
              song.album!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Sc.faint),
            ),
          ],
        ],
      );
    } else if (waitingForSync) {
      body = _status(
        LucideIcons.refreshCw,
        'Waiting for the clip to sync',
        'It is identified automatically once it reaches this phone.',
      );
    } else if (busy) {
      body = Column(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 14),
          const Text(
            'Identifying…',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ],
      );
    } else if (song.state == 'no_match') {
      body = _status(
        LucideIcons.searchX,
        'No match found',
        'Try again closer to the speaker, with less background noise.',
      );
    } else {
      body = _status(
        LucideIcons.circleAlert,
        'Could not identify this clip',
        song.error ?? 'Something went wrong. The recording is kept.',
        tone: Sc.danger,
      );
    }

    final provider = song.providerUrl;
    return Scaffold(
      backgroundColor: Sc.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          children: [
            ScBackRow(
              label: 'Notes',
              onBack: () => Navigator.pop(context),
              eyebrow: 'Song identification',
            ),
            const ScEyebrow('Music recognition'),
            const SizedBox(height: 8),
            ScTitle(song.matched ? 'A good find.' : 'Find that song.'),
            const SizedBox(height: 24),
            body,
            const SizedBox(height: 14),
            Center(
              child: Text(
                '${_dayLabel(note?.createdAt ?? DateTime.now())} · '
                '${_two(local.hour)}:${_two(local.minute)} · '
                '$_songClipSeconds second clip',
                style: const TextStyle(fontSize: 11, color: Sc.faint),
              ),
            ),
            const SizedBox(height: 24),
            ScActionBar(
              children: [
                ScIconButton(
                  icon: LucideIcons.play,
                  tooltip: hasAudio
                      ? 'Play the clip'
                      : 'Play (the clip has not synced yet)',
                  caption: 'Play',
                  onPressed: hasAudio
                      ? () => widget.onPlay(note?.audioPath)
                      : null,
                ),
                ScIconButton(
                  icon: LucideIcons.refreshCw,
                  tooltip: !hasAudio
                      ? 'Identify again (the clip has not synced yet)'
                      : busy
                      ? 'Identifying'
                      : 'Identify again',
                  caption: 'Retry',
                  busy: busy,
                  tone: song.matched ? ScTone.neutral : ScTone.primary,
                  onPressed: hasAudio && !busy
                      ? () => widget.onIdentify(widget.noteId)
                      : null,
                ),
                if (song.matched)
                  ScIconButton(
                    icon: LucideIcons.circlePlay,
                    tooltip: 'Open in Spotify',
                    caption: 'Spotify',
                    tone: ScTone.primary,
                    onPressed: () => _openSpotify(song),
                  ),
                if (provider != null)
                  ScIconButton(
                    icon: LucideIcons.externalLink,
                    tooltip: 'Open the track page in your browser',
                    caption: 'Page',
                    onPressed: () => _openProvider(provider),
                  ),
                if (hasAudio && !busy && !song.matched)
                  ScIconButton(
                    icon: LucideIcons.mic,
                    tooltip: 'This is a voice note, not a song. Transcribe it',
                    caption: 'Note',
                    onPressed: _useAsNote,
                  ),
                if (song.state == 'failed')
                  ScIconButton(
                    icon: LucideIcons.settings2,
                    tooltip: 'Music recognition settings',
                    caption: 'Settings',
                    onPressed: widget.onOpenSettings,
                  ),
                ScIconButton(
                  icon: LucideIcons.trash2,
                  tooltip: 'Delete this clip',
                  caption: 'Delete',
                  tone: ScTone.danger,
                  onPressed: note == null ? null : _delete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MusicSettingsPage extends StatefulWidget {
  const MusicSettingsPage({super.key});

  @override
  State<MusicSettingsPage> createState() => _MusicSettingsPageState();
}

class _MusicSettingsPageState extends State<MusicSettingsPage> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  bool _loading = true;
  bool _testing = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _urlController.text = await _music.functionUrl() ?? '';
    _keyController.text = await _music.serviceKey() ?? '';
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    await _music.save(url: _urlController.text, key: _keyController.text);
    _snack('Music recognition settings saved securely.');
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await _music.save(url: _urlController.text, key: _keyController.text);
      await _music.testConnection();
      _snack('Music recognition is connected.');
    } catch (error) {
      _snack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _clear() async {
    await _music.clear();
    _urlController.clear();
    _keyController.clear();
    _snack('Music recognition settings cleared.');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
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
                  eyebrow: 'Music recognition',
                ),
                const ScTitle('Music recognition'),
                const SizedBox(height: 8),
                const Text(
                  'Identify song sends a 12 second clip from this phone to your own service. '
                  'The service does not keep the audio. The key stays on this phone.',
                  style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 22),
                const ScGroupLabel('Service address'),
                TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    hintText: 'https://…lambda-url.…on.aws',
                  ),
                ),
                const SizedBox(height: 18),
                const ScGroupLabel('Service key'),
                TextField(
                  controller: _keyController,
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
                        tooltip: 'Save and test music recognition',
                        onPressed: _testing ? null : _test,
                      ),
                    ),
                    const SizedBox(width: 10),
                    ScIconButton(
                      size: 54,
                      icon: LucideIcons.save,
                      tooltip: 'Save without testing',
                      onPressed: _save,
                    ),
                    const SizedBox(width: 10),
                    ScIconButton(
                      size: 54,
                      icon: LucideIcons.trash2,
                      tone: ScTone.danger,
                      tooltip: 'Remove the saved address and key',
                      onPressed: _clear,
                    ),
                  ],
                ),
              ],
            ),
    ),
  );
}
