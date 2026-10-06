part of '../main.dart';

typedef BackupSaver = Future<bool> Function(String fileName, Uint8List bytes);
typedef BackupPicker = Future<Uint8List?> Function();
typedef FilesDirectory = Future<Directory> Function();

Future<bool> _saveBackupFile(String fileName, Uint8List bytes) async =>
    await FilePicker.saveFile(
      dialogTitle: 'Save backup',
      fileName: fileName,
      bytes: bytes,
    ) !=
    null;

Future<Uint8List?> _pickBackupFile() async {
  final result = await FilePicker.pickFiles(withData: true);
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

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    _restorePassphrase.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _backUp() async {
    final problem = BackupCodec.passphraseProblem(_passphrase.text);
    if (problem != null) return _snack(problem);
    if (_passphrase.text != _confirm.text) {
      return _snack('The two passphrases do not match.');
    }
    setState(() => _busy = true);
    try {
      final data = await BackupStore.collect(includeAudio: _includeAudio);
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
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
        children: [
          ScBackRow(
            label: 'Settings',
            onBack: () => Navigator.pop(context),
            eyebrow: 'Backup',
          ),
          const ScTitle('Back up and restore'),
          const SizedBox(height: 8),
          const Text(
            'Your notes, tasks, groups and chats go into one file, sealed with a passphrase. API keys are never included. Save it somewhere safe, such as Google Drive.',
            style: TextStyle(color: Sc.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 22),
          const ScGroupLabel('Back up'),
          TextField(
            controller: _passphrase,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Passphrase'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Passphrase again'),
          ),
          const SizedBox(height: 8),
          ScRow(
            title: 'Include recordings',
            caption:
                'Makes the file larger, and includes the keys that open them',
            trailing: Switch(
              value: _includeAudio,
              onChanged: (value) => setState(() => _includeAudio = value),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Anyone with this file and the passphrase can read your notes and hear your recordings. If you forget the passphrase, the backup cannot be opened.',
            style: TextStyle(color: Sc.faint, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 14),
          ScIconButton(
            expand: true,
            size: 54,
            icon: LucideIcons.download,
            tone: ScTone.primary,
            busy: _busy,
            tooltip: 'Create backup',
            onPressed: _busy ? null : _backUp,
          ),
          const SizedBox(height: 28),
          const ScGroupLabel('Restore'),
          TextField(
            controller: _restorePassphrase,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Passphrase'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Restoring only adds what this phone is missing. Nothing already here is changed or deleted.',
            style: TextStyle(color: Sc.faint, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 14),
          ScIconButton(
            expand: true,
            size: 54,
            icon: LucideIcons.upload,
            busy: _busy,
            tooltip: 'Choose backup file',
            onPressed: _busy ? null : _restore,
          ),
        ],
      ),
    ),
  );
}
