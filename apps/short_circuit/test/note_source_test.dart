import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

CircuitNote _note(String audio) => CircuitNote(
  id: audio,
  createdAt: DateTime.utc(2026, 10, 6),
  status: 'ok',
  audioPath: audio,
);

Future<List<String>> _pumpFilter(
  WidgetTester tester, {
  String selected = noteSourceAll,
}) async {
  final chosen = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NoteSourceFilter(
          selected: selected,
          counts: const {noteSourceAll: 9, 'Phone': 2, 'Circuit': 7},
          onChanged: chosen.add,
        ),
      ),
    ),
  );
  return chosen;
}

void main() {
  group('which notes a choice shows', () {
    final phone = _note('/f/phone-note-1.cnote');
    final circuit = _note('/f/circuit-note-1-1.cnote');
    final old = _note('/f/older.wav');

    test('All shows everything', () {
      for (final note in [phone, circuit, old]) {
        expect(noteMatchesSource(note, noteSourceAll), isTrue);
      }
    });

    test('Phone shows only the phone recordings', () {
      expect(noteMatchesSource(phone, 'Phone'), isTrue);
      expect(noteMatchesSource(circuit, 'Phone'), isFalse);
      expect(noteMatchesSource(old, 'Phone'), isFalse);
    });

    test('Circuit shows the board notes, including older ones', () {
      expect(noteMatchesSource(circuit, 'Circuit'), isTrue);
      expect(noteMatchesSource(old, 'Circuit'), isTrue);
      expect(noteMatchesSource(phone, 'Circuit'), isFalse);
    });
  });

  group('the filter row', () {
    testWidgets('shows each choice with its count', (tester) async {
      await _pumpFilter(tester);
      expect(find.text('All 9'), findsOneWidget);
      expect(find.text('Phone 2'), findsOneWidget);
      expect(find.text('Circuit 7'), findsOneWidget);
    });

    testWidgets('tapping a choice reports it', (tester) async {
      final chosen = await _pumpFilter(tester);
      await tester.tap(find.text('Phone 2'));
      await tester.tap(find.text('Circuit 7'));
      await tester.tap(find.text('All 9'));
      expect(chosen, ['Phone', 'Circuit', noteSourceAll]);
    });

    testWidgets('the chosen one is marked selected for screen readers', (
      tester,
    ) async {
      await _pumpFilter(tester, selected: 'Phone');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Phone, 2 notes')),
        containsSemantics(
          label: 'Phone, 2 notes',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
        ),
      );
      // The others are buttons that are not selected.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Circuit, 7 notes')),
        containsSemantics(isSelected: false, hasSelectedState: true),
      );
      expect(find.bySemanticsLabel('Circuit, 7 notes'), findsOneWidget);
    });
  });

  group('the badge', () {
    testWidgets('a phone note shows a phone, a Circuit note the Circuit mark', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                NoteSourceBadge(source: 'Phone'),
                NoteSourceBadge(source: 'Circuit'),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(Icon), findsOneWidget); // the phone icon
      expect(find.byType(ScDeviceMark), findsOneWidget); // the Circuit mark
    });

    testWidgets('a tile shows the badge on its icon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ScTile(
              icon: Icons.mic,
              title: 'A note',
              subtitle: 'Today · 21:03 · Phone',
              badge: NoteSourceBadge(source: 'Phone'),
            ),
          ),
        ),
      );
      expect(find.byType(NoteSourceBadge), findsOneWidget);
      expect(find.text('Today · 21:03 · Phone'), findsOneWidget);
    });
  });
}
