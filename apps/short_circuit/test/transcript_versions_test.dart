import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

CircuitNote _note({
  String transcript = 'Edited words',
  bool edited = true,
  bool stale = true,
  String enrichment = 'ready',
}) => CircuitNote(
  id: 'n1',
  createdAt: DateTime(2026, 10, 13, 10, 43),
  status: 'Transcription ready',
  title: 'Plan',
  transcript: transcript,
  summary: 'A short summary.',
  enrichmentStatus: enrichment,
  transcriptEdited: edited,
  reviewStale: stale,
  transcriptRuns: [
    TranscriptRun(
      model: 'model-a',
      text: 'First words',
      at: DateTime(2026, 10, 13, 10, 43),
    ),
    TranscriptRun(
      model: 'model-b',
      text: 'Second words',
      at: DateTime(2026, 10, 13, 11, 5),
    ),
  ],
);

Widget _page(
  CircuitNote note, {
  List<(String, int)>? used,
  List<String>? reviewed,
}) => MaterialApp(
  theme: buildScTheme(),
  home: TranscriptPage(
    createdAt: note.createdAt,
    noteId: note.id,
    category: 'note',
    title: note.title!,
    status: note.status,
    transcript: note.transcript!,
    summary: note.summary,
    noteById: (_) => note,
    onForceTranscribe: (_) async => null,
    audioPath: null,
    onPlayNote: (_) async {},
    onDeleteNote: (_) async {},
    onCreateReminder: (_) async => null,
    onAddTask: (_, _) async {},
    onSuggestionState: (_, _, _) async {},
    onEnrich: (id) async => reviewed?.add(id),
    onEditNote: (_, _, _) async {},
    onUseRun: (id, i) async => used?.add((id, i)),
  ),
);

void main() {
  test(
    'every transcription, the edits and the review model survive a save',
    () {
      final note = _note();
      final back = CircuitNote.fromJson(
        jsonDecode(jsonEncode(note.toJson())) as Map<String, dynamic>,
      );
      expect(back.transcriptRuns.map((r) => r.model), ['model-a', 'model-b']);
      expect(back.transcriptRuns.last.text, 'Second words');
      expect(back.transcriptEdited, isTrue);
      expect(back.reviewStale, isTrue);
    },
  );

  test('a note saved before versions existed still loads', () {
    final back = CircuitNote.fromJson({
      'id': 'x',
      'createdAt': '2026-10-01T10:00:00.000',
      'status': 'Transcription ready',
      'transcript': 'Old words',
    });
    expect(back.transcriptRuns, isEmpty);
    expect(back.transcriptEdited, isFalse);
  });

  testWidgets(
    'the transcript tab says it was edited and offers edit and review',
    (tester) async {
      final reviewed = <String>[];
      await tester.pumpWidget(_page(_note(), reviewed: reviewed));
      await tester.tap(find.text('Transcript').first);
      await tester.pumpAndSettle();
      expect(find.text('Edited words'), findsOneWidget);
      expect(find.textContaining('Edited by you'), findsOneWidget);
      expect(find.text('The summary is out of date'), findsOneWidget);
      expect(find.text('Edit transcript'), findsOneWidget);
      await tester.tap(find.text('Run AI review'));
      await tester.pump();
      expect(reviewed, ['n1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an untouched original shows its model and no warning', (
    tester,
  ) async {
    await tester.pumpWidget(
      _page(_note(transcript: 'Second words', edited: false, stale: false)),
    );
    await tester.tap(find.text('Transcript').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Original · model-b'), findsOneWidget);
    expect(find.text('The summary is out of date'), findsNothing);
    expect(find.text('Review again'), findsOneWidget);
    expect(find.text('Back to original'), findsNothing);
  });

  testWidgets('Back to original restores the latest transcription', (
    tester,
  ) async {
    final used = <(String, int)>[];
    await tester.pumpWidget(_page(_note(), used: used));
    await tester.tap(find.text('Transcript').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back to original'));
    await tester.pumpAndSettle();
    expect(used, [('n1', 1)]);
    expect(find.text('Second words'), findsOneWidget);
  });

  testWidgets('versions lists every model and lets one be used', (
    tester,
  ) async {
    final used = <(String, int)>[];
    await tester.pumpWidget(_page(_note(), used: used));
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript versions (2)'));
    await tester.pumpAndSettle();
    expect(find.text('First words'), findsOneWidget);
    expect(find.text('Second words'), findsOneWidget);
    expect(find.textContaining('model-a'), findsOneWidget);
    await tester.tap(find.text('Use this version').first);
    await tester.pumpAndSettle();
    expect(used, [('n1', 1)]);
    expect(tester.takeException(), isNull);
  });
}
