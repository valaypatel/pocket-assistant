import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

void main() {
  setUpAll(loadRoboto);
  testWidgets('the first-run screens', (tester) async {
    await renderPreview(
      tester,
      'onboarding_connect_light',
      OnboardingPage(onFinish: () {}, onOpenCircuit: () {}, onOpenAi: () {}),
      theme: buildScTheme(),
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await renderPreview(
      tester,
      'onboarding_step2_light',
      OnboardingPage(onFinish: () {}, onOpenCircuit: () {}, onOpenAi: () {}),
      theme: buildScTheme(),
    );
  });
}
