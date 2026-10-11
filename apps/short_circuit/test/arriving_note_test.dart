import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

CircuitNote _note(String status, {String? audioPath, int? boardId}) =>
    CircuitNote(
      id: 'x',
      createdAt: DateTime(2026, 10, 1),
      status: status,
      audioPath: audioPath,
      boardId: boardId,
    );

void main() {
  test('a long recording still collecting parts is arriving', () {
    expect(
      _note('Waiting for part 2 from Circuit…', boardId: 7).isArriving,
      isTrue,
    );
    expect(
      _note('Receiving part 1 from Circuit…', boardId: 7).isArriving,
      isTrue,
    );
    expect(
      _note('Receiving 3 parts from Circuit…', boardId: 7).isArriving,
      isTrue,
    );
  });

  test('a whole note, a phone note or a note with audio is not', () {
    expect(
      _note(
        'Synced. Ready to transcribe.',
        audioPath: '/a.cnote',
        boardId: 7,
      ).isArriving,
      isFalse,
    );
    expect(
      _note('Waiting for part 2 from Circuit…').isArriving,
      isFalse,
    ); // no board number
    expect(
      _note(
        'Receiving part 1 from Circuit…',
        audioPath: '/a',
        boardId: 7,
      ).isArriving,
      isFalse,
    );
  });
}
