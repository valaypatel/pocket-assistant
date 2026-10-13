import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

Widget _strips() => ListView(
  padding: const EdgeInsets.all(20),
  children: [
    const ScTitle('Notes'),
    const SizedBox(height: 16),
    ScStatusStrip(
      tone: ScStripTone.danger,
      leading: LucideIcons.refreshCwOff,
      title: 'Sync needs attention',
      detail: 'Could not reach Circuit on Wi-Fi. Check that your phone and Circuit are on the same network.',
      actions: [
        TextButton(onPressed: () {}, child: const Text('Retry')),
        IconButton(
          tooltip: 'Dismiss',
          icon: const Icon(LucideIcons.x, size: 18),
          onPressed: () {},
        ),
      ],
    ),
    const SizedBox(height: 12),
    const ScStatusStrip(
      tone: ScStripTone.progress,
      title: 'Syncing a voice note',
      detail: '43%',
      showProgress: true,
      progress: .43,
    ),
    const SizedBox(height: 12),
    ScStatusStrip(
      tone: ScStripTone.neutral,
      leading: LucideIcons.unplug,
      title: 'Circuit is not connected',
      detail: 'Notes already on your phone are still here.',
      actions: [
        TextButton(onPressed: () {}, child: const Text('Open Circuit')),
      ],
    ),
    const SizedBox(height: 12),
    const ScStatusStrip(
      tone: ScStripTone.good,
      leading: LucideIcons.circleCheck,
      title: 'Circuit is connected and everything is synced',
    ),
  ],
);

void main() {
  setUpAll(loadRoboto);
  for (final scale in [1.0, 2.0]) {
    testWidgets('status strips at ${scale}x', (tester) async {
      await renderPreview(
        tester,
        'strips_${scale.toStringAsFixed(0)}x',
        _strips(),
        theme: buildScTheme(),
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
