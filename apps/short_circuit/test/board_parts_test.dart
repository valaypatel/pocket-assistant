import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  group('BoardPart.parse', () {
    test('reads first, part and last', () {
      final part = BoardPart.parse('10,3,1\n')!;
      expect(part.first, 10);
      expect(part.part, 3);
      expect(part.last, isTrue);
      expect(BoardPart.parse('10,1,0')!.last, isFalse);
    });

    test('anything that makes no sense is not a part', () {
      for (final text in [
        '',
        'x',
        '10,3',
        '10,3,2',
        '0,1,0',
        '10,0,0',
        '10,a,1',
      ]) {
        expect(BoardPart.parse(text), isNull, reason: text);
      }
    });
  });

  test('boardFileId reads the number from a downloaded file name', () {
    expect(boardFileId('/data/files/circuit-note-1789000060-11.cnote'), 11);
    expect(boardFileId('/data/files/circuit-note-1789000060-11.wav'), 11);
    expect(boardFileId('/data/files/phone-note-5.cnote'), isNull);
  });

  group('collectBoardParts', () {
    BoardPart p(int n, {bool last = false}) =>
        BoardPart(first: 10, part: n, last: last);

    test('is incomplete until the last part is here', () {
      final arrived = collectBoardParts({'a': p(1), 'b': p(2)});
      expect(arrived.complete, isFalse);
      expect(arrived.lastPart, isNull);
      expect(arrived.statusText, 'Receiving part 2 from Circuit…');
    });

    test('says which part it is waiting for once the end is known', () {
      final arrived = collectBoardParts({'a': p(1), 'c': p(3, last: true)});
      expect(arrived.complete, isFalse);
      expect(arrived.firstMissing, 2);
      expect(arrived.statusText, 'Waiting for part 2 from Circuit…');
    });

    test(
      'is complete when 1 to the last are here, whatever order they came',
      () {
        final arrived = collectBoardParts({
          'c': p(3, last: true),
          'a': p(1),
          'b': p(2),
        });
        expect(arrived.complete, isTrue);
        expect(arrived.ordered, ['a', 'b', 'c']);
        expect(arrived.statusText, 'Receiving 3 parts from Circuit…');
      },
    );
  });

  test('readBoardPart reads the description saved next to a file', () async {
    final dir = await Directory.systemTemp.createTemp('board_parts');
    addTearDown(() => dir.delete(recursive: true));
    final note = File('${dir.path}/circuit-note-1789000060-11.cnote')
      ..writeAsStringSync('x');
    expect(await readBoardPart(note.path), isNull);
    File('${dir.path}/circuit-group-11.txt').writeAsStringSync('10,2,0');
    final part = (await readBoardPart(note.path))!;
    expect((part.first, part.part, part.last), (10, 2, false));
  });
}
