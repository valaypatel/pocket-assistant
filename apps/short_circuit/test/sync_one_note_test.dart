import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

Widget _page({String? audioPath, Future<void> Function(String)? onSync}) =>
    MaterialApp(
      theme: buildScTheme(),
      home: TranscriptPage(
        createdAt: DateTime(2026, 10, 11, 9, 30),
        noteId: 'note-1',
        category: 'note',
        title: 'Voice recording',
        status: 'Recording saved on Circuit.',
        transcript: '',
        onForceTranscribe: (_) async => null,
        onSyncNote: onSync,
        audioPath: audioPath,
        onPlayNote: (_) async {},
        onDeleteNote: (_) async {},
        onCreateReminder: (_) async => null,
        onAddTask: (_, _) async {},
        onOpenChat: () {},
        onSuggestionState: (_, _, _) async {},
      ),
    );

void main() {
  testWidgets(
    'a note still on Circuit has a button that syncs just that note',
    (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(_page(onSync: (id) async => asked.add(id)));
      expect(find.text('Sync this note from Circuit'), findsOneWidget);
      await tester.tap(find.text('Sync this note from Circuit'));
      expect(asked, ['note-1']);
    },
  );

  testWidgets('a note that has arrived has no sync button', (tester) async {
    await tester.pumpWidget(
      _page(audioPath: '/files/circuit-note-1-5.cnote', onSync: (_) async {}),
    );
    expect(find.text('Sync this note from Circuit'), findsNothing);
  });

  testWidgets('without a way to sync, no button is shown', (tester) async {
    await tester.pumpWidget(_page());
    expect(find.text('Sync this note from Circuit'), findsNothing);
  });
}
