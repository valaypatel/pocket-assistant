import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

TranscriptPage _page(List<NoteActionSuggestion> suggestions) => TranscriptPage(
  createdAt: DateTime(2026, 10, 4, 21, 53),
  noteId: 'n1',
  category: 'task',
  title: 'Sync Fix Test',
  status: 'Transcription ready',
  transcript: 'Remember to test the sync fix tomorrow.',
  onForceTranscribe: (_) async => null,
  audioPath: null,
  onPlayNote: (_) async {},
  onDeleteNote: (_) async {},
  onCreateReminder: (_) async => null,
  onAddTask: (_, _) async {},
  suggestions: suggestions,
  onSuggestionState: (_, _, _) async {},
);

void main() {
  // A button inside a Row must not demand infinite width. When it did, the whole
  // page failed to lay out and rendered blank, so notes with a pending suggestion
  // (the ones in the Review queue) could not be opened.
  testWidgets('a note with a pending suggestion lays out and can be read', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildScTheme(),
        home: _page(const [
          NoteActionSuggestion(
            id: 's1',
            type: 'task',
            title: 'Test the sync fix',
            details: 'Tomorrow morning',
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Sync Fix Test'), findsWidgets);
    expect(
      find.text('Remember to test the sync fix tomorrow.'),
      findsOneWidget,
    );
    expect(find.byTooltip('Approve suggestion'), findsOneWidget);
    expect(find.byTooltip('Dismiss suggestion'), findsOneWidget);
    // Deleting must be possible from the note page too (it is further down).
    await tester.scrollUntilVisible(
      find.byTooltip('Delete note'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byTooltip('Delete note'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a note with no transcript still opens', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildScTheme(),
        home: TranscriptPage(
          createdAt: DateTime(2026, 10, 4, 21, 47),
          noteId: 'n2',
          category: 'note',
          title: 'Voice note',
          status: 'Synced. Ready to transcribe.',
          transcript: '',
          onForceTranscribe: (_) async => null,
          audioPath: null,
          onPlayNote: (_) async {},
          onDeleteNote: (_) async {},
          onCreateReminder: (_) async => null,
          onAddTask: (_, _) async {},
          onSuggestionState: (_, _, _) async {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Transcript not available'), findsOneWidget);
  });

  chatTests();

  testWidgets('"Run AI review again" calls back with the note id', (
    tester,
  ) async {
    String? requested;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildScTheme(),
        home: TranscriptPage(
          createdAt: DateTime(2026, 10, 4, 21, 47),
          noteId: 'n3',
          category: 'note',
          title: 'Voice note',
          status: 'Transcription ready',
          transcript: 'Some words.',
          onForceTranscribe: (_) async => null,
          audioPath: null,
          onPlayNote: (_) async {},
          onDeleteNote: (_) async {},
          onCreateReminder: (_) async => null,
          onAddTask: (_, _) async {},
          onSuggestionState: (_, _, _) async {},
          onEnrich: (id) async => requested = id,
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byTooltip('Run AI review again'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('Run AI review again'));
    await tester.pump();
    expect(requested, 'n3');
    expect(tester.takeException(), isNull);
    // Stop the page's refresh timer before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}

void chatTests() {
  Widget chat({
    required Future<String> Function(String, List<ChatMessage>) ask,
    List<ChatMessage> history = const [],
    void Function(List<ChatMessage>)? onSave,
    void Function(String)? onTask,
  }) => MaterialApp(
    theme: buildScTheme(),
    home: NoteChatPage(
      noteId: 'n1',
      title: 'Sync Fix Test',
      loadHistory: (_) async => history,
      saveHistory: (_, messages) async => onSave?.call(messages),
      ask: ask,
      onAddTask: (title, _) async => onTask?.call(title),
    ),
  );

  testWidgets('chat answers a question and saves the conversation', (
    tester,
  ) async {
    List<ChatMessage> saved = [];
    List<ChatMessage>? asked;
    await tester.pumpWidget(
      chat(
        ask: (_, history) async {
          asked = history;
          return 'You said to test the sync fix tomorrow.';
        },
        onSave: (m) => saved = m,
      ),
    );
    await tester.pump();
    expect(find.text('Ask anything about this note.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'What did I say?');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('What did I say?'), findsOneWidget);
    expect(
      find.text('You said to test the sync fix tomorrow.'),
      findsOneWidget,
    );
    expect(asked!.single.text, 'What did I say?');
    expect(saved.map((m) => m.role), ['user', 'assistant']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat shows an error and retries without losing the question', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      chat(
        ask: (_, _) async {
          calls++;
          if (calls == 1) throw Exception('AI service is unreachable');
          return 'Second try works.';
        },
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('AI service is unreachable'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    await tester.tap(find.byTooltip('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Second try works.'), findsOneWidget);
    expect(find.text('AI service is unreachable'), findsNothing);
  });

  testWidgets('an answer can be added to tasks', (tester) async {
    String? task;
    await tester.pumpWidget(
      chat(
        ask: (_, _) async => 'unused',
        history: [
          ChatMessage(role: 'user', text: 'Q', at: DateTime(2026)),
          ChatMessage(
            role: 'assistant',
            text: 'Call the vendor',
            at: DateTime(2026),
          ),
        ],
        onTask: (t) => task = t,
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Add this answer to your tasks'));
    await tester.pump();
    expect(task, 'Call the vendor');
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
