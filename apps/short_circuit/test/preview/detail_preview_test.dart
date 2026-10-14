import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

Widget _page() => TranscriptPage(
  createdAt: DateTime(2026, 10, 13, 8, 31),
  noteId: 'n1',
  category: 'note',
  title: 'Election commission and the SIR scrap demand',
  status: 'Transcription ready',
  transcript: 'There are two demands: the Election Commission head should resign, and the special revision should be scrapped completely. [Moment 1] Then he said it again, and asked for a public statement before the weekend.',
  onForceTranscribe: (_) async => null,
  audioPath: '/nonexistent/circuit-note-1-208.cnote',
  onPlayNote: (_) async {},
  onPlayMoment: (_, _) async {},
  onDeleteNote: (_) async {},
  onCreateReminder: (_, _) async => null,
  onAddTask: (_, _) async {},
  summary: 'Two demands about the election commission, with a request for a public statement.',
  language: 'English',
  categories: const ['meeting'],
  tags: const ['election', 'statement'],
  suggestions: const [
    NoteActionSuggestion(
      id: 's1',
      type: 'task',
      title: 'Ask for a public statement',
      details: 'Before the weekend',
    ),
  ],
  onSuggestionState: (_, _, _) async {},
  onOpenChat: () {},
  onEnrich: (_) async {},
  onEditNote: (_, _, _) async {},
);

void main() {
  setUpAll(loadRoboto);
  for (final scale in [1.0, 2.0]) {
    testWidgets('note detail at ${scale}x', (tester) async {
      await renderPreview(
        tester,
        'detail_${scale.toStringAsFixed(0)}x',
        _page(),
        theme: buildScTheme(),
        height: 1100,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      // Stop the page's refresh timer before the test ends.
      await tester.pumpWidget(const SizedBox());
    });
  }
}
