import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

NoteActionSuggestion _action(String type, String? at) => NoteActionSuggestion(
  id: '$type$at',
  type: type,
  title: 'x',
  details: '',
  scheduledAt: at,
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => notesUnreadableForTest = false);

  test(
    'saved notes are never overwritten while they could not be read',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await writeSecretForTest(prefs, 'circuit_notes', '[{"id":"keep"}]');
      final before = prefs.getString('circuit_notes');
      notesUnreadableForTest = true;
      await writeSecretForTest(prefs, 'circuit_notes', '[]');
      expect(prefs.getString('circuit_notes'), before);
      // other data is not held back
      await writeSecretForTest(prefs, 'circuit_tasks', '[]');
      expect(prefs.getString('circuit_tasks'), isNotNull);
      // and once the notes open again, saving works
      notesUnreadableForTest = false;
      await writeSecretForTest(prefs, 'circuit_notes', '[]');
      expect(prefs.getString('circuit_notes'), isNot(before));
    },
  );

  test(
    'an event for a time that had passed when the note was recorded is dropped',
    () {
      final spoken = DateTime(2026, 10, 13, 1, 11);
      final kept = dropPastActions([
        _action(
          'calendar_event',
          '2026-10-12T16:00:00',
        ), // news about yesterday
        _action('reminder', '2026-10-13T01:12:00'), // a minute later: fine
        _action('calendar_event', '2026-10-14T16:00:00'),
        _action('task', null),
        _action('reminder', null),
      ], spoken);
      expect(kept.map((a) => '${a.type} ${a.scheduledAt}').toList(), [
        'reminder 2026-10-13T01:12:00',
        'calendar_event 2026-10-14T16:00:00',
        'task null',
        'reminder null',
      ]);
    },
  );
}
