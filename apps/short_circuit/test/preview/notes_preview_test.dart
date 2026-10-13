import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

/// A sample of the Notes list as the redesigned tile draws it.
Widget _notesSample() => ListView(
  padding: const EdgeInsets.symmetric(horizontal: 20),
  children: [
    const SizedBox(height: 12),
    const ScTitle('Notes'),
    const SizedBox(height: 16),
    const TextField(
      decoration: InputDecoration(
        hintText: 'Search notes, transcripts, tags',
        prefixIcon: Icon(LucideIcons.search, size: 18),
      ),
    ),
    const SizedBox(height: 18),
    const ScGroupLabel('Needs attention'),
    ScTile(
      icon: LucideIcons.mic,
      title: 'Voice note',
      meta: const ['Today · 08:31', '0:19', 'Circuit'],
      status: 'No speech found',
      statusIcon: LucideIcons.circleAlert,
      statusColor: Sc.danger,
      trailing: ScPlayButton(onPressed: () {}),
      statusTrailing: [
        ScStateIcon(
          icon: LucideIcons.languages,
          label: 'Transcribe',
          state: ScStepState.todo,
          onPressed: () {},
        ),
        const ScStateIcon(
          icon: LucideIcons.sparkles,
          label: 'AI review needs a transcript first',
          state: ScStepState.disabled,
        ),
      ],
    ),
    const SizedBox(height: 18),
    const ScGroupLabel('Today'),
    ScTile(
      icon: LucideIcons.mic,
      title: 'चुनाव आयोग ज्ञानेश कुमार का इस्तीफा होना चाहिए',
      meta: const ['Today · 08:31', '0:49', 'Circuit'],
      statusTrailing: [
        ScStateIcon(
          icon: LucideIcons.languages,
          label: 'Transcribed',
          state: ScStepState.done,
          onPressed: () {},
        ),
        ScStateIcon(
          icon: LucideIcons.sparkles,
          label: 'AI reviewed',
          state: ScStepState.done,
          onPressed: () {},
        ),
      ],
      trailing: ScPlayButton(onPressed: () {}),
    ),
    ScTile(
      icon: LucideIcons.mic,
      title: 'Buy milk and call the plumber about the kitchen tap on Friday',
      meta: const ['Today · 07:12', '1:07', 'Phone'],
      status: 'Transcribing…',
      statusColor: Sc.accentInk,
      statusTrailing: [
        ScStateIcon(
          icon: LucideIcons.languages,
          label: 'Transcribing',
          state: ScStepState.busy,
          onPressed: () {},
        ),
        const ScStateIcon(
          icon: LucideIcons.sparkles,
          label: 'AI review',
          state: ScStepState.failed,
        ),
      ],
      trailing: ScPlayButton(onPressed: () {}),
    ),
    ScTile(
      icon: LucideIcons.mic,
      title: 'Voice recording',
      meta: const ['Yesterday · 21:40', 'Circuit'],
      status: 'Syncing',
      statusColor: Sc.accentInk,
      trailing: ScPlayButton(onPressed: null),
    ),
  ],
);

void main() {
  setUpAll(loadRoboto);

  for (final scale in [1.0, 2.0]) {
    testWidgets('notes list at text ${scale}x', (tester) async {
      await renderPreview(
        tester,
        'notes_after_${scale.toStringAsFixed(0)}x',
        _notesSample(),
        theme: buildScTheme(),
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Notes'), findsOneWidget);
    });
  }
}
