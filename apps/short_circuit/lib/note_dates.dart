part of 'main.dart';

/// How long ago a note was made, in the steps the Notes page groups by.
enum NoteAge {
  today('Today'),
  yesterday('Yesterday'),
  earlierThisWeek('Earlier this week'),
  older('Older than a week');

  const NoteAge(this.label);
  final String label;
}

/// Calendar days, not 24-hour spans: a note from 23:50 last night is "Yesterday" at 00:10.
NoteAge noteAge(DateTime created, DateTime now) {
  final a = DateTime.utc(created.year, created.month, created.day);
  final b = DateTime.utc(now.year, now.month, now.day);
  final days = b.difference(a).inDays;
  if (days <= 0) return NoteAge.today;
  if (days == 1) return NoteAge.yesterday;
  if (days < 7) return NoteAge.earlierThisWeek;
  return NoteAge.older;
}
