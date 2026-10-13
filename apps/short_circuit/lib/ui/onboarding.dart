part of '../main.dart';

/// First run: three short screens (what the app is, connect Circuit, add AI), each optional. Shown once,
/// only on an app with no notes yet, so nobody who already uses it meets it.
class Onboarding {
  const Onboarding._();

  /// Tests switch this off so the whole app starts on Notes (test/flutter_test_config.dart).
  static bool enabled = true;
  static const doneKey = 'onboarding_done_v1';
}

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.onFinish,
    required this.onOpenCircuit,
    required this.onOpenAi,
  });

  /// Skip, or the last button: mark it done and show the app.
  final VoidCallback onFinish;

  /// "Open the Circuit tab" on the second screen.
  final VoidCallback onOpenCircuit;

  /// "Open Settings" on the third screen.
  final VoidCallback onOpenAi;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _page = 0;

  static const _count = 3;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _count - 1) {
      widget.onFinish();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.sc;
    final pages = <_OnboardingStep>[
      const _OnboardingStep(
        art: ScBrandMark(size: 88),
        title: 'Your voice notes, kept private',
        body: 'Record a thought on Circuit or on your phone. Short-Circuit keeps it encrypted and turns it into text you can search.',
      ),
      _OnboardingStep(
        art: const ScDeviceMark(size: 96),
        title: 'Connect Circuit',
        body: 'Turn Circuit on, open the Circuit tab and tap Scan. Android asks for Bluetooth and notification access, then shows a six-digit code to confirm.',
        actionLabel: 'Open the Circuit tab',
        onAction: widget.onOpenCircuit,
      ),
      _OnboardingStep(
        art: Icon(LucideIcons.sparkles, size: 72, color: p.accent),
        title: 'Add AI when you want it',
        body: 'Notes work without AI. Add a Gemini key in Settings to turn recordings into text, and an AI service for summaries and chat.',
        actionLabel: 'Open Settings',
        onAction: widget.onOpenAi,
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onFinish,
                child: const Text('Skip'),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (index) => setState(() => _page = index),
                children: pages,
              ),
            ),
            Semantics(
              label: 'Step ${_page + 1} of $_count',
              child: ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _count; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(
                          horizontal: ScSpace.xs,
                        ),
                        width: i == _page ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _page ? p.accent : p.line,
                          borderRadius: ScRadius.pillBorder,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(ScSpace.xl),
              child: ScButton(
                primary: true,
                label: _page == _count - 1 ? 'Get started' : 'Next',
                onPressed: _next,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.art,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final Widget art;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(horizontal: ScSpace.xl),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: MediaQuery.sizeOf(context).height * .5,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: art),
          const SizedBox(height: ScSpace.xl),
          Semantics(header: true, child: Text(title, style: ScType.display)),
          const SizedBox(height: ScSpace.md),
          Text(body, style: ScType.body.copyWith(color: context.sc.muted)),
          if (actionLabel != null) ...[
            const SizedBox(height: ScSpace.lg),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
