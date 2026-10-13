import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:short_circuit/main.dart';

void main() {
  Widget host(ScStateIcon icon) => MaterialApp(
    theme: buildScTheme(),
    home: Scaffold(body: Center(child: icon)),
  );

  testWidgets('a step that can be run runs when tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        ScStateIcon(
          icon: LucideIcons.languages,
          label: 'Transcribe',
          state: ScStepState.todo,
          onPressed: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Transcribe'));
    expect(taps, 1);
  });

  testWidgets('a step in progress or not available ignores taps', (
    tester,
  ) async {
    var taps = 0;
    for (final state in [ScStepState.busy, ScStepState.disabled]) {
      await tester.pumpWidget(
        host(
          ScStateIcon(
            icon: LucideIcons.sparkles,
            label: 'AI review',
            state: state,
            onPressed: () => taps++,
          ),
        ),
      );
      await tester.tap(find.byTooltip('AI review'));
    }
    expect(taps, 0);
  });

  testWidgets('every state has a label for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        ScStateIcon(
          icon: LucideIcons.sparkles,
          label: 'AI reviewed. Tap to review again',
          state: ScStepState.done,
          onPressed: () {},
        ),
      ),
    );
    expect(
      find.bySemanticsLabel('AI reviewed. Tap to review again'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('the icon is 44 dp to tap', (tester) async {
    await tester.pumpWidget(
      host(
        ScStateIcon(
          icon: LucideIcons.languages,
          label: 'Transcribe',
          state: ScStepState.todo,
          onPressed: () {},
        ),
      ),
    );
    final size = tester.getSize(find.byType(InkResponse));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });
}
