import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

TranscriptPage _page(
  List<NoteActionSuggestion> suggestions, {
  required List<(String, DateTime)> reminders,
  required List<String> tasks,
  List<String>? states,
  String category = 'reminder',
  CircuitNote? Function(String id)? noteById,
}) => TranscriptPage(
  createdAt: DateTime(2026, 10, 4, 21, 53),
  noteId: 'n1',
  category: category,
  noteById: noteById,
  title: 'Dentist',
  status: 'Transcription ready',
  transcript: 'Remind me to call the dentist.',
  onForceTranscribe: (_) async => null,
  audioPath: null,
  onPlayNote: (_) async {},
  onDeleteNote: (_) async {},
  onCreateReminder: (_, _) async => null,
  onAddTask: (title, _) async => tasks.add(title),
  onAddReminder: (title, _, at) async {
    reminders.add((title, at));
    return true;
  },
  suggestions: suggestions,
  onSuggestionState: (_, _, state) async => (states ?? []).add(state),
);

Future<void> _open(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildScTheme(), home: page));
}

void main() {
  test(
    'a task keeps its reminder time, and old tasks without one still load',
    () {
      final at = DateTime(2030, 1, 2, 16, 30);
      final task = CircuitTask(id: '1', title: 'Call', dueAt: at);
      expect(CircuitTask.fromJson(task.toJson()).dueAt, at);
      expect(
        CircuitTask.fromJson({'id': '2', 'title': 'Old', 'done': false}).dueAt,
        isNull,
      );
      expect(task.copyWith(done: true).dueAt, at);
      expect(task.copyWith(clearDue: true).dueAt, isNull);
    },
  );

  test('a reminder time reads as a day and a 12 hour clock', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    expect(
      reminderLabel(today.add(const Duration(hours: 16, minutes: 5))),
      'Today 4:05 pm',
    );
    expect(
      reminderLabel(today.add(const Duration(days: 1, hours: 9))),
      'Tomorrow 9:00 am',
    );
    expect(
      reminderLabel(today.add(const Duration(days: 1, hours: 12))),
      'Tomorrow 12:00 pm',
    );
    expect(
      reminderLabel(today.add(const Duration(days: 1, minutes: 5))),
      'Tomorrow 12:05 am',
    );
  });

  testWidgets('approving a reminder suggestion sets a reminder at its time', (
    tester,
  ) async {
    final reminders = <(String, DateTime)>[];
    final states = <String>[];
    final at = DateTime.now().add(const Duration(days: 2));
    await _open(
      tester,
      _page(
        [
          NoteActionSuggestion(
            id: 's1',
            type: 'reminder',
            title: 'Call the dentist',
            details: '',
            scheduledAt: at.toIso8601String(),
          ),
        ],
        reminders: reminders,
        tasks: [],
        states: states,
      ),
    );
    await tester.tap(find.byTooltip('Approve suggestion'));
    await tester.pumpAndSettle();
    expect(find.text('Remind you?'), findsOneWidget);
    await tester.tap(find.byTooltip('Set reminder'));
    await tester.pumpAndSettle();
    expect(reminders.single.$1, 'Call the dentist');
    expect(reminders.single.$2, at);
    expect(states, ['approved']);
  });

  testWidgets('a reminder whose time has passed becomes a task', (
    tester,
  ) async {
    final reminders = <(String, DateTime)>[];
    final tasks = <String>[];
    await _open(
      tester,
      _page(
        [
          NoteActionSuggestion(
            id: 's1',
            type: 'reminder',
            title: 'Call the dentist',
            details: '',
            scheduledAt: DateTime.now()
                .subtract(const Duration(days: 1))
                .toIso8601String(),
          ),
        ],
        reminders: reminders,
        tasks: tasks,
      ),
    );
    await tester.tap(find.byTooltip('Approve suggestion'));
    await tester.pumpAndSettle();
    expect(find.text('That time has already passed.'), findsOneWidget);
    expect(find.text('Add to your tasks?'), findsOneWidget);
    await tester.tap(find.byTooltip('Add as task'));
    await tester.pumpAndSettle();
    expect(reminders, isEmpty);
    expect(tasks, ['Call the dentist']);
  });

  testWidgets(
    'with nothing suggested, the three ways to follow up are listed',
    (tester) async {
      await _open(
        tester,
        _page(const [], reminders: [], tasks: [], category: 'task'),
      );
      expect(find.text('FOLLOW UP'), findsOneWidget);
      expect(find.text('Add to tasks'), findsOneWidget);
      expect(find.text('Remind me'), findsOneWidget);
      expect(find.text('Add to calendar'), findsOneWidget);
      expect(find.text('Add something else'), findsNothing);
    },
  );

  testWidgets('with a suggestion, the same options wait behind one row', (
    tester,
  ) async {
    await _open(
      tester,
      _page(
        [
          NoteActionSuggestion(
            id: 's1',
            type: 'task',
            title: 'Call the dentist',
            details: '',
          ),
        ],
        reminders: [],
        tasks: [],
        category: 'task',
      ),
    );
    expect(find.text('Add to tasks'), findsNothing);
    expect(find.text('Remind me'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Add something else'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add something else'));
    await tester.pumpAndSettle();
    expect(find.text('Add to tasks'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
    expect(find.text('Add to calendar'), findsOneWidget);
  });

  testWidgets('a note deleted while its page is open closes the page', (
    tester,
  ) async {
    CircuitNote? note = CircuitNote(
      id: 'n1',
      createdAt: DateTime(2026, 10, 4, 21, 53),
      status: 'Ready for review',
      kind: 'text',
      title: 'Dentist',
      transcript: 'Call the dentist.',
    );
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildScTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StatefulBuilder(
                      builder: (context, setState) {
                        refresh = setState;
                        return _page(
                          const [],
                          reminders: [],
                          tasks: [],
                          noteById: (_) => note,
                        );
                      },
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TranscriptPage), findsOneWidget);
    note = null;
    refresh(() {});
    await tester.pumpAndSettle();
    expect(find.byType(TranscriptPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
