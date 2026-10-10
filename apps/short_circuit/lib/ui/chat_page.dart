part of '../main.dart';

/// Chat about one note, or about a group of notes. The AI sees only those notes; the history is
/// saved with them.
class NoteChatPage extends StatefulWidget {
  const NoteChatPage({
    super.key,
    required this.noteId,
    required this.title,
    required this.loadHistory,
    required this.saveHistory,
    required this.ask,
    required this.onAddTask,
    this.banner,
    this.starters,
    this.subject = 'note',
  });

  final String noteId;
  final String title;
  final Future<List<ChatMessage>> Function(String noteId) loadHistory;
  final Future<void> Function(String noteId, List<ChatMessage> messages)
  saveHistory;

  /// Returns the assistant's reply to the last message in [history].
  final Future<String> Function(String noteId, List<ChatMessage> history) ask;
  final Future<void> Function(String title, String? detail) onAddTask;

  /// A line under the title, for a group chat: "Using 18 of 22 notes · …".
  final String? banner;

  /// Suggested first questions; the single-note ones when null.
  final List<(IconData, String)>? starters;

  /// 'note' or 'group': what the chat is about, for its wording.
  final String subject;

  @override
  State<NoteChatPage> createState() => _NoteChatPageState();
}

class _NoteChatPageState extends State<NoteChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  bool _waiting = false;
  String? _error;

  static const _starters = [
    (LucideIcons.textAlignStart, 'Summarize this note'),
    (LucideIcons.listChecks, 'What do I need to do?'),
    (LucideIcons.languages, 'Translate this to English'),
  ];

  @override
  void initState() {
    super.initState();
    widget.loadHistory(widget.noteId).then((history) {
      if (!mounted) return;
      setState(() {
        _messages = history;
        _loading = false;
      });
      _scrollToEnd();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _waiting) return;
    _input.clear();
    setState(() {
      _messages = [
        ..._messages,
        ChatMessage(role: 'user', text: text, at: DateTime.now()),
      ];
      _waiting = true;
      _error = null;
    });
    _scrollToEnd();
    await _reply();
  }

  /// Asks for a reply to the current history; also used to retry after an error.
  Future<void> _reply() async {
    setState(() {
      _waiting = true;
      _error = null;
    });
    try {
      final answer = await widget.ask(widget.noteId, _messages);
      if (!mounted) return;
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(role: 'assistant', text: answer, at: DateTime.now()),
        ];
        _waiting = false;
      });
      await widget.saveHistory(widget.noteId, _messages);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _waiting = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
      // Keep what the user typed so a retry does not lose it.
      await widget.saveHistory(widget.noteId, _messages);
    }
    _scrollToEnd();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear this chat?'),
        content: const Text('The note itself is not changed.'),
        actions: scDialogActions(
          dialogContext,
          confirmIcon: LucideIcons.trash2,
          confirmTooltip: 'Clear chat',
          danger: true,
          onCancel: () => Navigator.pop(dialogContext, false),
          onConfirm: () => Navigator.pop(dialogContext, true),
        ),
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _messages = [];
      _error = null;
    });
    await widget.saveHistory(widget.noteId, const []);
  }

  Future<void> _addAsTask(ChatMessage message) async {
    final text = message.text.trim();
    final firstLine = text.split('\n').first.trim();
    final title = firstLine.length > 80
        ? '${firstLine.substring(0, 77)}…'
        : firstLine;
    await widget.onAddTask(title, text == title ? null : text);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Added to your tasks')));
  }

  Widget _bubble(ChatMessage message) {
    final mine = message.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * .82,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: mine ? Sc.hero : Sc.bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 5),
                bottomRight: Radius.circular(mine ? 5 : 18),
              ),
            ),
            child: SelectableText(
              message.text,
              style: TextStyle(fontSize: 16, height: 1.6, color: Sc.ink),
            ),
          ),
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Tooltip(
                message: 'Add this answer to your tasks',
                child: TextButton.icon(
                  onPressed: () => _addAsTask(message),
                  icon: const Icon(LucideIcons.listPlus, size: 18),
                  label: const Text('Save as a task'),
                  style: TextButton.styleFrom(foregroundColor: Sc.accentInk),
                ),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _empty() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 24),
      const Icon(LucideIcons.messageCircle, size: 28, color: Sc.faint),
      const SizedBox(height: 12),
      Text(
        'Ask anything about this ${widget.subject}.',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 16),
      for (final starter in widget.starters ?? _starters)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Sc.line),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _send(starter.$2),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Icon(starter.$1, size: 18, color: Sc.tileInk),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        starter.$2,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Sc.bg,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(
              children: [
                ScIconButton(
                  icon: LucideIcons.arrowLeft,
                  tooltip: 'Back to ${widget.subject}',
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.4,
                    ),
                  ),
                ),
                ScIconButton(
                  icon: LucideIcons.trash2,
                  tooltip: _messages.isEmpty
                      ? 'Clear chat (nothing to clear yet)'
                      : 'Clear chat',
                  onPressed: _messages.isEmpty ? null : _clear,
                ),
              ],
            ),
          ),
          if (widget.banner != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.banner!,
                  style: const TextStyle(color: Sc.muted, fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                    children: [
                      if (_messages.isEmpty && !_waiting) _empty(),
                      for (final message in _messages) _bubble(message),
                      if (_waiting)
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      if (_error != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Sc.dangerSoft,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.35,
                                    color: Sc.danger,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ScIconButton(
                                size: 40,
                                icon: LucideIcons.refreshCw,
                                tooltip: 'Try again',
                                tone: ScTone.danger,
                                onPressed: _waiting ? null : _reply,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Ask about this ${widget.subject}',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ScIconButton(
                  icon: LucideIcons.arrowUp,
                  tooltip: 'Send',
                  tone: ScTone.primary,
                  busy: _waiting,
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
