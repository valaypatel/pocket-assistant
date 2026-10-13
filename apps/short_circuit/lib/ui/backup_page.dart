part of '../main.dart';

typedef BackupSaver = Future<bool> Function(String fileName, Uint8List bytes);
typedef BackupPicker = Future<Uint8List?> Function();
typedef FilesDirectory = Future<Directory> Function();

Future<bool> _saveBackupFile(String fileName, Uint8List bytes) async =>
    await FilePicker.platform.saveFile(
      dialogTitle: 'Save backup',
      fileName: fileName,
      bytes: bytes,
    ) !=
    null;

Future<Uint8List?> _pickBackupFile() async {
  final result = await FilePicker.platform.pickFiles(withData: true);
  return result?.files.single.bytes;
}

class BackupPage extends StatefulWidget {
  const BackupPage({
    super.key,
    required this.onRestored,
    this.save = _saveBackupFile,
    this.pick = _pickBackupFile,
    this.filesDirectory = getApplicationSupportDirectory,
    this.iterations = BackupCodec.defaultIterations,
  });

  /// Called after a restore so the app reloads what it shows.
  final Future<void> Function() onRestored;
  final BackupSaver save;
  final BackupPicker pick;
  final FilesDirectory filesDirectory;
  final int iterations;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  final _restorePassphrase = TextEditingController();
  bool _includeAudio = true;
  bool _busy = false;
  bool _restoreMode = false;
  String? _feedback;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    _restorePassphrase.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    setState(() => _feedback = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _backUp() async {
    if (_busy) return;
    final problem = BackupCodec.passphraseProblem(_passphrase.text);
    if (problem != null) return _snack(problem);
    if (_passphrase.text != _confirm.text) {
      return _snack('The two passphrases do not match.');
    }
    setState(() => _busy = true);
    try {
      final data = await BackupStore.collect(includeAudio: _includeAudio);
      final audioBytes = data.audio.fold<int>(0, (sum, a) => sum + a.length);
      if (audioBytes > BackupCodec.maxAudioBytes) {
        return _snack(
          'Your recordings come to ${audioBytes ~/ (1024 * 1024)} MB, too much for one backup file on this phone. '
          'Turn off "Include recordings" to back up the notes, or delete old recordings first.',
        );
      }
      final file = await BackupCodec.encode(
        data,
        _passphrase.text,
        iterations: widget.iterations,
      );
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final saved = await widget.save('short-circuit-backup-$stamp.cbk', file);
      if (saved) {
        _passphrase.clear();
        _confirm.clear();
        _snack(
          'Backed up ${data.notes.length} notes'
          '${data.audio.isEmpty ? '' : ' and ${data.audio.length} recordings'}.',
        );
      }
    } catch (error) {
      _snack('Backup failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    if (_restorePassphrase.text.isEmpty) {
      return _snack('Enter the passphrase you backed up with.');
    }
    setState(() => _busy = true);
    try {
      final bytes = await widget.pick();
      if (bytes == null) return;
      final data = await BackupCodec.decode(bytes, _restorePassphrase.text);
      final result = await BackupStore.restore(
        data,
        filesDir: await widget.filesDirectory(),
      );
      await widget.onRestored();
      _restorePassphrase.clear();
      _snack(
        'Restored ${result.notesAdded} notes'
        '${result.notesSkipped > 0 ? ', ${result.notesSkipped} were already here' : ''}.',
      );
    } on BackupException catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('Restore failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
        children: [
          ScBackRow(
            label: 'Settings',
            onBack: () => Navigator.pop(context),
            eyebrow: 'Backup',
          ),
          const ScTitle('Your thoughts.\nSafely packed.'),
          const SizedBox(height: 12),
          Text(
            'Notes, tasks, groups and chats in one encrypted file. API keys are never included.',
            style: TextStyle(
              color: context.sc.muted,
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Back up'),
                icon: Icon(LucideIcons.download, size: 18),
              ),
              ButtonSegment(
                value: true,
                label: Text('Restore'),
                icon: Icon(LucideIcons.upload, size: 18),
              ),
            ],
            selected: {_restoreMode},
            onSelectionChanged: _busy
                ? null
                : (value) => setState(() {
                    _restoreMode = value.first;
                    _feedback = null;
                  }),
          ),
          const SizedBox(height: 24),
          if (!_restoreMode) ...[
            const ScGroupLabel('Protect your archive'),
            ScSecretField(
              controller: _passphrase,
              label: 'Passphrase',
              enabled: !_busy,
            ),
            const SizedBox(height: 16),
            ScSecretField(
              controller: _confirm,
              label: 'Passphrase again',
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            ScRow(
              title: 'Include recordings',
              caption: 'Includes audio and the keys that open it',
              trailing: Switch(
                value: _includeAudio,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _includeAudio = v),
              ),
            ),
            const SizedBox(height: 16),
            ScPanel(
              color: context.sc.warmCard,
              child: Text(
                'Keep the passphrase safe. Anyone with the file and passphrase can open your notes. A forgotten passphrase cannot be recovered.',
                style: TextStyle(
                  color: context.sc.neutralInk,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 20),
            ScIconButton(
              expand: true,
              size: 54,
              icon: LucideIcons.download,
              tone: ScTone.dark,
              busy: _busy,
              tooltip: 'Create backup',
              onPressed: _busy ? null : _backUp,
            ),
          ] else ...[
            ScPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ScGroupLabel('Restore missing content'),
                  Text(
                    'Bring it all back.',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.8,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Only missing content is added. Existing notes are kept and duplicates are skipped.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: context.sc.neutralInk,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            ScSecretField(
              controller: _restorePassphrase,
              label: 'Passphrase',
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            Text(
              'Enter the passphrase you used to create the archive, then choose your backup file.',
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: context.sc.muted,
              ),
            ),
            const SizedBox(height: 20),
            ScIconButton(
              expand: true,
              size: 54,
              icon: LucideIcons.upload,
              tone: ScTone.dark,
              busy: _busy,
              tooltip: 'Choose backup file',
              onPressed: _busy ? null : _restore,
            ),
          ],
          if (_feedback != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                _feedback!,
                style: TextStyle(
                  color: context.sc.neutralInk,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
