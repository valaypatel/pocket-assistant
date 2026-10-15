import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  final text = CircuitNote(
    id: 't1',
    createdAt: DateTime(2026, 10, 15),
    status: 'Ready for review',
    kind: 'text',
    transcript: 'Call the dentist',
  );

  test('a note written on the phone is a phone note, not a Circuit one', () {
    expect(text.isText, isTrue);
    expect(text.source, 'Phone');
    expect(CircuitNote.fromJson(text.toJson()).source, 'Phone');
  });

  test('a note written on the phone is not counted as waiting on Circuit', () {
    final counts = boardNoteCounts([text]);
    expect(counts.pending, 0);
    expect(counts.synced, 0);
  });

  test('a voice note with no audio is still Circuit\'s', () {
    final voice = CircuitNote(
      id: 'v1',
      createdAt: DateTime(2026, 10, 15),
      status: 'Recording saved on Circuit',
    );
    expect(voice.source, 'Circuit');
    expect(boardNoteCounts([voice]).pending, 1);
  });
}
