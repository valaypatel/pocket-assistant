import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

Widget _states() => Builder(
  builder: (context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const ScTitle('Capture dock'),
      const SizedBox(height: 24),
      const CaptureDock(mode: DockMode.pill),
      const SizedBox(height: 24),
      const CaptureDock(mode: DockMode.pill, collapsed: true),
      const SizedBox(height: 24),
      CaptureDock(
        mode: DockMode.recording,
        title: 'Recording on this phone',
        elapsed: () => const Duration(minutes: 2, seconds: 14),
        level: () => .7,
        onTogglePause: () {},
        onStop: () {},
      ),
      const SizedBox(height: 24),
      CaptureDock(
        mode: DockMode.recording,
        paused: true,
        elapsed: () => const Duration(minutes: 2, seconds: 14),
        onTogglePause: () {},
        onStop: () {},
      ),
      const SizedBox(height: 24),
      CaptureDock(
        mode: DockMode.recording,
        title: 'Recording on Circuit',
        elapsed: () => const Duration(seconds: 9),
        onStop: () {},
      ),
    ],
  ),
);

void main() {
  setUpAll(loadRoboto);
  for (final dark in [false, true]) {
    testWidgets('dock states ${dark ? 'dark' : 'light'}', (tester) async {
      await renderPreview(
        tester,
        'dock_${dark ? 'dark' : 'light'}',
        _states(),
        theme: dark ? buildScDarkTheme() : buildScTheme(),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
