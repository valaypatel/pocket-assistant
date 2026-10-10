import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

CircuitNote note(
  String id,
  DateTime at, {
  String? transcript = 'hello',
  String? title,
  String kind = 'voice',
}) => CircuitNote(
  id: id,
  createdAt: at,
  status: 'Transcription ready',
  transcript: transcript,
  title: title ?? 'Note $id',
  kind: kind,
);

void main() {
  group('NoteGroup', () {
    test('survives a round trip through JSON', () {
      final group = NoteGroup(
        id: 'g1',
        name: 'Trip',
        noteIds: const ['a', 'b'],
        createdAt: DateTime.utc(2026, 10, 5),
      );
      final back = NoteGroup.fromJson(
        jsonDecode(jsonEncode(group.toJson())) as Map<String, dynamic>,
      );
      expect(back.id, 'g1');
      expect(back.name, 'Trip');
      expect(back.noteIds, ['a', 'b']);
      expect(back.createdAt, group.createdAt);
    });

    test('a blank name and missing fields still load', () {
      final group = NoteGroup.fromJson({'id': 'g2', 'name': '  '});
      expect(group.name, 'Group');
      expect(group.noteIds, isEmpty);
    });
  });

  group('buildGroupContext', () {
    test('puts notes oldest first, whatever order they come in', () {
      final context = buildGroupContext([
        note('new', DateTime(2026, 3, 1), transcript: 'second thing'),
        note('old', DateTime(2026, 1, 1), transcript: 'first thing'),
      ]);
      expect(
        context.text.indexOf('first thing'),
        lessThan(context.text.indexOf('second thing')),
      );
      expect(context.included, 2);
      expect(context.banner, 'Using 2 of 2 notes');
    });

    test('counts notes with no transcript but does not send them', () {
      final context = buildGroupContext([
        note('a', DateTime(2026, 1, 1)),
        note('b', DateTime(2026, 1, 2), transcript: null),
        note('c', DateTime(2026, 1, 3), transcript: '   '),
      ]);
      expect(context.total, 3);
      expect(context.transcribed, 1);
      expect(context.included, 1);
      expect(context.banner, 'Using 1 of 3 notes · 2 not transcribed yet');
    });

    test('songs are not notes you can talk about', () {
      final context = buildGroupContext([
        note('a', DateTime(2026, 1, 1)),
        note('s', DateTime(2026, 1, 2), kind: 'song'),
      ]);
      expect(context.total, 1);
    });

    test(
      'over the budget, the newest notes stay and the oldest are left out',
      () {
        final notes = [
          for (var i = 1; i <= 5; i++)
            note(
              'n$i',
              DateTime(2026, 1, i),
              transcript: 'x' * 300,
              title: 'T$i',
            ),
        ];
        final context = buildGroupContext(notes, budget: 700);
        expect(context.included, lessThan(5));
        expect(context.leftOut, 5 - context.included);
        expect(context.text, contains('T5'));
        expect(context.text, isNot(contains('T1')));
        expect(context.banner, contains('older left out to fit'));
      },
    );

    test('one note bigger than the whole budget is cut, not dropped', () {
      final context = buildGroupContext([
        note('big', DateTime(2026, 1, 1), transcript: 'y' * 5000),
      ], budget: 1000);
      expect(context.included, 1);
      expect(context.text.length, lessThanOrEqualTo(1000));
    });

    test('an empty group has nothing to send', () {
      final context = buildGroupContext(const []);
      expect(context.included, 0);
      expect(context.text, isEmpty);
      expect(context.banner, 'Using 0 of 0 notes');
    });
  });

  group('grouping notes in the app', () {
    Future<void> openNotes(WidgetTester tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        'circuit_notes': jsonEncode([
          note('a', DateTime(2026, 10, 1, 9), title: 'Groceries').toJson(),
          note('b', DateTime(2026, 10, 2, 9), title: 'Trip plan').toJson(),
          note('c', DateTime(2026, 10, 3, 9), title: 'Idea for app').toJson(),
        ]),
      });
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Notes').last);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('select two notes, group them, and land on the group', (
      tester,
    ) async {
      await openNotes(tester);
      // Before grouping there is only the built-in group.
      expect(find.text('All notes'), findsWidgets);

      await tester.tap(find.byTooltip('Select notes to group'));
      await tester.pump();
      expect(find.text('Select notes'), findsOneWidget);

      // While selecting, the tile itself ignores touches (so its buttons do not fire) and the
      // row around it takes the tap; hence warnIfMissed.
      await tester.tap(find.text('Groceries'), warnIfMissed: false);
      await tester.tap(find.text('Trip plan'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.text('Group'));
      await tester.pumpAndSettle();
      expect(find.text('Group 2 notes'), findsOneWidget);
      // A name is suggested from the newest note's date.
      expect(find.text('Notes · 2 Oct'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'Planning');
      await tester.tap(find.text('Create group'));
      await tester.pumpAndSettle();

      // On the group's page, with its two notes and a chat button.
      expect(find.text('Planning'), findsWidgets);
      expect(find.text('2 notes · 2 transcribed'), findsOneWidget);
      expect(find.text('Chat with this group'), findsOneWidget);
      expect(find.text('Idea for app'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Cancel leaves the notes as they were', (tester) async {
      await openNotes(tester);
      await tester.tap(find.byTooltip('Select notes to group'));
      await tester.pump();
      await tester.tap(find.text('Groceries'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel selecting'));
      await tester.pump();
      expect(find.text('Notes'), findsWidgets);
      expect(find.text('1 selected'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Group stays off until a note is picked', (tester) async {
      await openNotes(tester);
      await tester.tap(find.byTooltip('Select notes to group'));
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Group'),
      );
      expect(button.onPressed, isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('groups across restarts and pages', () {
    final notesJson = jsonEncode([
      note('a', DateTime(2026, 10, 1, 9), title: 'Groceries').toJson(),
      note('b', DateTime(2026, 10, 2, 9), title: 'Trip plan').toJson(),
      note('c', DateTime(2026, 10, 3, 9), title: 'Idea for app').toJson(),
    ]);
    final groupsJson = jsonEncode([
      NoteGroup(
        id: 'g1',
        name: 'Planning',
        noteIds: const ['a', 'b'],
        createdAt: DateTime(2026, 10, 4),
      ).toJson(),
    ]);

    Future<void> openNotes(WidgetTester tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        'circuit_notes': notesJson,
        'circuit_groups': groupsJson,
      });
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Notes').last);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('a saved group is there after the app starts again', (
      tester,
    ) async {
      await openNotes(tester);
      expect(find.text('Planning'), findsOneWidget);
      expect(find.text('2 notes'), findsOneWidget);
      // The built-in group counts every spoken note.
      expect(find.text('3 notes'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('All notes lists every note and offers a chat', (tester) async {
      await openNotes(tester);
      await tester.tap(find.text('All notes').first);
      await tester.pumpAndSettle();
      expect(find.text('3 notes · 3 transcribed'), findsOneWidget);
      expect(find.text('Chat with all notes'), findsOneWidget);
      // The built-in group is not edited or deleted.
      expect(find.byTooltip('Group options'), findsNothing);
      expect(find.text('Add notes'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the group chat says how many notes it is using', (
      tester,
    ) async {
      await openNotes(tester);
      await tester.tap(find.text('Planning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat with this group'));
      await tester.pumpAndSettle();
      expect(find.text('Using 2 of 2 notes'), findsOneWidget);
      expect(find.text('Ask anything about this group.'), findsOneWidget);
      expect(find.text('List every task across these notes'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('deleting a note takes it out of its groups', (tester) async {
      await openNotes(tester);
      expect(
        find.text('2 notes'),
        findsOneWidget,
      ); // Planning: Groceries and Trip plan
      await tester.drag(find.text('Groceries'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete note'));
      await tester.pumpAndSettle();
      expect(find.text('Groceries'), findsNothing);
      // Planning is down to one note; All notes went from three to two.
      expect(find.text('1 note'), findsOneWidget);
      expect(find.text('2 notes'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('deleting a group keeps its notes', (tester) async {
      await openNotes(tester);
      await tester.tap(find.text('Planning'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Group options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete group'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The notes stay where they are'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete group'));
      await tester.pumpAndSettle();
      // Back on Notes: the group is gone, the notes are not.
      expect(find.text('Planning'), findsNothing);
      expect(find.text('Groceries'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Trip plan'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Trip plan'), findsOneWidget);
      final saved = (await SharedPreferences.getInstance()).getString(
        'circuit_groups',
      );
      expect(saved, isNotNull);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('many groups on a phone', () {
    testWidgets('every group is visible, not hidden off the edge', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        'circuit_notes': jsonEncode([
          note('a', DateTime(2026, 10, 1, 9), title: 'Groceries').toJson(),
          note('b', DateTime(2026, 10, 2, 9), title: 'Trip plan').toJson(),
        ]),
        'circuit_groups': jsonEncode([
          for (final name in ['First', 'Second', 'Third'])
            NoteGroup(
              id: name,
              name: name,
              noteIds: const ['a'],
              createdAt: DateTime(2026, 10, 4),
            ).toJson(),
        ]),
      });
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Notes').last);
      await tester.pump(const Duration(milliseconds: 400));
      for (final name in ['All notes', 'First', 'Second', 'Third']) {
        expect(
          find.text(name),
          findsOneWidget,
          reason: '$name should be on screen',
        );
        final box = tester.getRect(find.text(name));
        expect(
          box.right,
          lessThanOrEqualTo(400),
          reason: '$name runs off the edge',
        );
      }
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'with many groups, the first few show and Show all reveals the rest',
      (tester) async {
        tester.view.physicalSize = const Size(400, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({
          'circuit_notes': jsonEncode([
            note('a', DateTime(2026, 10, 1, 9), title: 'Groceries').toJson(),
          ]),
          'circuit_groups': jsonEncode([
            for (var i = 1; i <= 8; i++)
              NoteGroup(
                id: 'g$i',
                name: 'Group $i',
                noteIds: const ['a'],
                createdAt: DateTime(2026, 10, 4),
              ).toJson(),
          ]),
        });
        await tester.pumpWidget(const ShortCircuitApp());
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('Notes').last);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('GROUPS (8)'), findsOneWidget);
        expect(
          find.text('Group 5'),
          findsOneWidget,
        ); // six cards: All notes + five groups
        expect(find.text('Group 6'), findsNothing);
        await tester.tap(find.text('Show all 8 groups'));
        await tester.pump();
        expect(find.text('Group 8'), findsOneWidget);
        await tester.tap(find.text('Show fewer'));
        await tester.pump();
        expect(find.text('Group 8'), findsNothing);
        await tester.pump(const Duration(seconds: 3));
      },
    );
  });

  group('choosing notes ends when you leave Notes', () {
    testWidgets('going to another tab and back starts clean', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        'circuit_notes': jsonEncode([
          note('a', DateTime(2026, 10, 1, 9), title: 'Groceries').toJson(),
        ]),
      });
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Notes').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Select notes to group'));
      await tester.pump();
      await tester.tap(find.text('Groceries'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Tasks').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Notes').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1 selected'), findsNothing);
      expect(find.byTooltip('Select notes to group'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
