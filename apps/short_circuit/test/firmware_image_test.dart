import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/firmware_image.dart';

Uint8List image({
  int magic = 0xE9,
  int desc = 0xABCD5432,
  String project = 'circuit_ble_display',
  String version = '2.0.0',
  int size = 300 * 1024,
}) {
  final bytes = Uint8List(size);
  final data = ByteData.sublistView(bytes);
  bytes[0] = magic;
  data.setUint32(32, desc, Endian.little);
  bytes.setRange(48, 48 + version.length, version.codeUnits);
  bytes.setRange(80, 80 + project.length, project.codeUnits);
  return bytes;
}

void main() {
  test(
    'reads whether Circuit works on its own (sync mode) or stays linked',
    () {
      expect(
        BoardReport.modeFrom(
          '@sync-status\nfw=3.0.1|aa\npm=saver|auto\nmode=sync',
        ),
        'sync',
      );
      expect(
        BoardReport.modeFrom('@sync-status\npm=saver|auto\nmode=connected'),
        'connected',
      );
      // Older firmware sends none: it stays linked.
      expect(
        BoardReport.modeFrom('@sync-status\nfw=2.0.0|aaaaaaaa\npm=deep|auto'),
        isNull,
      );
      expect(BoardReport.modeFrom('@sync-status\nmode=weird'), isNull);
    },
  );

  test('a firmware update needs 30% battery', () {
    expect(BoardReport.minUpdatePercent, 30);
  });

  test('reads the power mode Circuit reports', () {
    expect(
      BoardReport.powerFrom('@sync-status\nfw=2.0.0|aaaaaaaa\npm=deep|auto'),
      (mode: 'deep', choice: 'auto'),
    );
    expect(BoardReport.powerFrom('@sync-status\npm=rec|saver'), (
      mode: 'rec',
      choice: 'saver',
    ));
    expect(BoardReport.powerFrom('@sync-status\nfw=2.0.0|aaaaaaaa'), isNull);
    expect(BoardReport.powerFrom('@sync-status\npm=weird|auto'), isNull);
  });

  test('compares firmware versions as numbers, with dev builds below the release', () {
    int c(String a, String b) => FirmwareImage.compareVersions(a, b).sign;
    expect(c('2.0.0-dev.10', '2.0.0-dev.9'), 1);
    expect(c('2.0.0-dev.2', '2.0.0-dev1'), 1);
    expect(c('2.0.0-dev.3', '2.0.0-dev.3'), 0);
    expect(c('2.0.0', '2.0.0-dev.99'), 1);
    expect(c('2.1.0-dev.1', '2.0.9'), 1);
    expect(c('1.9.0', '2.0.0-dev.1'), -1);
    // Firmware 3 is newer than every 2.x, and its development builds count up.
    expect(c('3.0.0-dev.34', '2.0.99'), 1);
    expect(c('3.0.12', '3.0.0-dev.40'), 1);
    expect(FirmwareImage.relation('2.0.0-dev.3', '2.0.0-dev.2'), 'newer than');
    expect(FirmwareImage.relation('2.0.0-dev.1', '2.0.0-dev.2'), 'older than');
    expect(FirmwareImage.relation('2.0.0', '2.0.0'), 'the same version as');
  });

  test('reads the previous firmware and the card figures Circuit reports', () {
    const status =
        '@sync-status\nfw=2.0.0|aaaaaaaa\nprev=1.9.0|bbbbbbbb\nsd=3250000|31000000';
    expect(BoardReport.previousFrom(status)?.built, 'bbbbbbbb');
    expect(
      BoardReport.previousFrom('@sync-status\nfw=2.0.0|aaaaaaaa\nprev=\nsd=')
          ?.version,
      isNull,
    );
    final card = BoardReport.storageFrom(status)!;
    expect(card.usedKb, 3250000);
    expect(BoardReport.describeStorage(card), '3.1 GB of 29.6 GB used');
    expect(BoardReport.storageFrom('@sync-status\nsd='), isNull);
    expect(
      BoardReport.describeStorage((usedKb: 5120, totalKb: 204800)),
      '5 MB of 200 MB used',
    );
  });

  test('accepts a Circuit image and reads its version', () {
    final parsed = FirmwareImage.parse(image(version: '2.1.0-rc1'));
    expect(parsed.version, '2.1.0-rc1');
    expect(parsed.bytes.length, 300 * 1024);
  });

  test('reads the build fingerprint, and what Circuit says is running', () {
    final bytes = image(version: '2.0.0');
    bytes.setRange(176, 180, [0x3f, 0xa9, 0x1c, 0x2d]);
    final parsed = FirmwareImage.parse(bytes);
    expect(parsed.built, '3fa91c2d');
    final running = FirmwareImage.runningFrom(
      '@sync-status\nplayback=idle\nrecording=idle\nfw=2.0.0|3fa91c2d',
    );
    expect(running, isNotNull);
    expect(parsed.sameBuildAs(running!), isTrue);
    expect(parsed.sameBuildAs((version: '2.0.0', built: '00000000')), isFalse);
    expect(FirmwareImage.describe('2.0.0', '3fa91c2d'), '2.0.0');
    expect(FirmwareImage.runningFrom('@sync-status\nplayback=idle'), isNull);
  });

  test('refuses files that are not Circuit firmware, with a reason', () {
    expect(
      () => FirmwareImage.parse(image(magic: 0x00)),
      throwsFormatException,
    );
    expect(() => FirmwareImage.parse(image(desc: 0)), throwsFormatException);
    expect(
      () => FirmwareImage.parse(image(project: 'other_device')),
      throwsFormatException,
    );
    expect(() => FirmwareImage.parse(image(size: 1000)), throwsFormatException);
    expect(
      () => FirmwareImage.parse(image(size: 100 * 1024)),
      throwsFormatException,
    );
    expect(
      () => FirmwareImage.parse(image(size: 0x320000)),
      throwsFormatException,
    );
  });

  test(
    'accepts the firmware the project really builds, when one is built here',
    () {
      final file = File(
        '../../firmware/CircuitBleDisplay/build-dev/circuit_ble_display.bin',
      );
      if (!file.existsSync()) {
        return; // CI has no board build next to the app tests
      }
      final parsed = FirmwareImage.parse(file.readAsBytesSync());
      expect(parsed.version, isNotEmpty);
    },
  );
}
