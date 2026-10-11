import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// flutter_blue_plus can only pair a device that is connected, so createBond must come
// after connect. The other way round fails every time ("device is not connected"), and
// from the outside it looks like Connect doing nothing. Flutter tests do not run the
// Bluetooth code, so this guards the order in the source.
void main() {
  test('Circuit is connected before pairing is asked for', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _connect(');
    final body = source.substring(
      start,
      source.indexOf('Future<void> _repairPairing('),
    );
    final connect = body.indexOf('await device.connect(');
    final pair = body.indexOf('await device.createBond(');
    expect(connect, greaterThan(-1));
    expect(pair, greaterThan(-1));
    expect(connect, lessThan(pair));
  });
}
