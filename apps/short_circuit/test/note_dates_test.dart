import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  final now = DateTime(2026, 10, 11, 0, 10); // ten past midnight

  test('today, yesterday, earlier this week, older', () {
    expect(noteAge(DateTime(2026, 10, 11, 0, 5), now), NoteAge.today);
    expect(noteAge(DateTime(2026, 10, 10, 23, 50), now), NoteAge.yesterday);
    expect(noteAge(DateTime(2026, 10, 9, 8), now), NoteAge.earlierThisWeek);
    expect(noteAge(DateTime(2026, 10, 5, 8), now), NoteAge.earlierThisWeek);
    expect(noteAge(DateTime(2026, 10, 4, 23, 59), now), NoteAge.older);
    expect(noteAge(DateTime(2026, 9, 1), now), NoteAge.older);
  });

  test('a note dated in the future counts as today', () {
    expect(noteAge(DateTime(2026, 10, 12), now), NoteAge.today);
  });

  test('headings read as the person asked', () {
    expect(NoteAge.today.label, 'Today');
    expect(NoteAge.yesterday.label, 'Yesterday');
    expect(NoteAge.earlierThisWeek.label, 'Earlier this week');
    expect(NoteAge.older.label, 'Older than a week');
  });
}
