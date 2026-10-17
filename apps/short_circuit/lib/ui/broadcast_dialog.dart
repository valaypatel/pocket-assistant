part of '../main.dart';

/// What the Broadcast dialog hands back: typed text for Gemini to speak, or 16 kHz speech held to talk.
class _BroadcastChoice {
  const _BroadcastChoice.text(String this.text) : speech = null;
  const _BroadcastChoice.speech(Uint8List this.speech) : text = null;
  final String? text;
  final Uint8List? speech;
}

class _BroadcastDialog extends StatefulWidget {
  const _BroadcastDialog();

  @override
  State<_BroadcastDialog> createState() => _BroadcastDialogState();
}

class _BroadcastDialogState extends State<_BroadcastDialog> {
  final _controller = TextEditingController();
  bool _pressed = false;
  bool _talking = false;
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    if (_talking) unawaited(_relayChannel.invokeMethod<Uint8List>('talkStop'));
    super.dispose();
  }

  Future<void> _startTalking() async {
    _pressed = true;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        setState(
          () => _problem = 'Allow the microphone to talk through Circuit.',
        );
      }
      return;
    }
    if (!_pressed) return; // let go while the permission was asked
    final problem = await _relayChannel.invokeMethod<String>('talkStart');
    if (!mounted) {
      if (problem == null) {
        unawaited(_relayChannel.invokeMethod<Uint8List>('talkStop'));
      }
      return;
    }
    setState(() {
      _talking = problem == null;
      _problem = problem;
    });
    if (_talking && !_pressed) {
      await _stopTalking(); // a tap shorter than the microphone took to start
    }
  }

  Future<void> _stopTalking() async {
    _pressed = false;
    if (!_talking) return;
    setState(() => _talking = false);
    final speech = await _relayChannel.invokeMethod<Uint8List>('talkStop');
    if (!mounted) return;
    // Under half a second is a tap, not a message.
    if (speech == null || speech.length < 16000) {
      setState(
        () => _problem = 'Hold the button while you speak, then let go.',
      );
      return;
    }
    Navigator.pop(context, _BroadcastChoice.speech(speech));
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return AlertDialog(
      title: const Text('Broadcast on Circuit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            maxLength: broadcastMaxCharacters,
            maxLines: 5,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Type what Circuit should say',
            ),
          ),
          const SizedBox(height: ScSpace.md),
          Text(
            'Or speak it yourself',
            style: ScType.caption.copyWith(color: sc.muted),
          ),
          const SizedBox(height: ScSpace.sm),
          Semantics(
            button: true,
            label: 'Hold to talk through Circuit',
            child: Listener(
              onPointerDown: (_) => unawaited(_startTalking()),
              onPointerUp: (_) => unawaited(_stopTalking()),
              onPointerCancel: (_) => unawaited(_stopTalking()),
              child: Container(
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _talking ? sc.accent : sc.dark,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.mic, size: 20, color: Colors.white),
                    const SizedBox(width: ScSpace.sm),
                    Text(
                      _talking ? 'Listening… let go to send' : 'Hold to talk',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_problem != null) ...[
            const SizedBox(height: ScSpace.sm),
            Text(_problem!, style: ScType.caption.copyWith(color: sc.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) {
              setState(
                () =>
                    _problem = 'Type a message, or hold the button and speak.',
              );
              return;
            }
            Navigator.pop(context, _BroadcastChoice.text(text));
          },
          child: const Text('Broadcast'),
        ),
      ],
    );
  }
}
