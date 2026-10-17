import 'dart:typed_data';

/// What the phone checks in a Circuit firmware file before sending it. Circuit checks it again; this just
/// stops the wrong file (or a half-downloaded one) from ever leaving the phone.
class FirmwareImage {
  const FirmwareImage({
    required this.version,
    required this.built,
    required this.bytes,
  });

  /// The version string baked into the image, such as "2.0.0".
  final String version;

  /// The build's fingerprint (eight hex digits): no two builds share it, even with the same version.
  final String built;
  final Uint8List bytes;

  /// What Circuit says is running, as `fw=<version>|<built>` in its status. Null when it sent none (older
  /// firmware).
  static ({String version, String built})? runningFrom(String status) {
    final match = RegExp(r'fw=([^|\n]*)\|([^\n]*)').firstMatch(status);
    if (match == null) return null;
    return (version: match.group(1)!.trim(), built: match.group(2)!.trim());
  }

  /// What to show a person: the version ("2.0.0-dev.12"). The fingerprint is only for telling two builds
  /// of the same version apart, which a numbered build never needs.
  static String describe(String version, String built) => version;

  /// Compares two firmware versions: negative when [a] is older than [b], zero when the same, positive when
  /// newer. Numbers compare as numbers ("2.0.0-dev.10" is newer than "2.0.0-dev.9"), and a development build
  /// ("-dev") is older than the release of the same number ("2.0.0").
  static int compareVersions(String a, String b) {
    List<int> key(String version) {
      final numbers = RegExp(r'\d+')
          .allMatches(version.split('-').first)
          .map((m) => int.parse(m.group(0)!))
          .toList();
      while (numbers.length < 3) {
        numbers.add(0);
      }
      final dev = version.contains('-dev');
      final devNumber = RegExp(r'dev\.?(\d+)').firstMatch(version);
      return [
        ...numbers.take(3),
        dev ? 0 : 1,
        dev ? int.tryParse(devNumber?.group(1) ?? '') ?? 0 : 0,
      ];
    }

    final x = key(a), y = key(b);
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return 0;
  }

  /// "newer than", "older than" or "the same version as", for the install dialog.
  static String relation(String file, String running) {
    final c = compareVersions(file, running);
    return c > 0
        ? 'newer than'
        : c < 0
        ? 'older than'
        : 'the same version as';
  }

  /// True when [other] is the very same build as what is running.
  bool sameBuildAs(({String version, String built}) running) =>
      running.version == version && running.built == built;

  /// An ESP-IDF app image: a one-byte 0xE9 magic, an 24-byte header, one 8-byte segment header, then the
  /// app description (magic 0xABCD5432, version at +16, project name at +48, build fingerprint at +144).
  static const _descriptionAt = 32;
  static const projectName = 'circuit_ble_display';
  static const minBytes = 256 * 1024;
  static const maxBytes =
      0x320000 - 0x1000; // an app slot on the board, less a sector

  /// Reads [bytes], or throws a [FormatException] saying in plain words why it is not Circuit firmware.
  static FirmwareImage parse(Uint8List bytes) {
    if (bytes.length < _descriptionAt + 112) {
      throw const FormatException(
        'That file is too small to be Circuit firmware.',
      );
    }
    if (bytes[0] != 0xE9) {
      throw const FormatException(
        'That is not a firmware image (.bin built for the board).',
      );
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(_descriptionAt, Endian.little) != 0xABCD5432) {
      throw const FormatException('That firmware has no version information.');
    }
    String text(int from, int length) {
      final slice = bytes.sublist(from, from + length);
      final end = slice.indexOf(0);
      return String.fromCharCodes(end < 0 ? slice : slice.sublist(0, end));
    }

    if (text(_descriptionAt + 48, 32) != projectName) {
      throw const FormatException(
        'That firmware is for a different device, not Circuit.',
      );
    }
    if (bytes.length < minBytes) {
      throw const FormatException('That firmware file looks incomplete.');
    }
    if (bytes.length > maxBytes) {
      throw const FormatException('That firmware is too big for Circuit.');
    }
    // The app description ends its text fields with the ELF's SHA-256 (+144); Circuit reports its first
    // four bytes as eight hex digits.
    final fingerprint = bytes
        .sublist(_descriptionAt + 144, _descriptionAt + 148)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return FirmwareImage(
      version: text(_descriptionAt + 16, 32),
      built: fingerprint,
      bytes: bytes,
    );
  }
}

/// What Circuit reports about the firmware it could switch back to, and about its card.
class BoardReport {
  const BoardReport._();

  /// `prev=<version>|<build>` in a status; null when it says there is none (or sent nothing).
  static ({String version, String built})? previousFrom(String status) {
    final match = RegExp(r'prev=([^|\n]*)\|([^\n]*)').firstMatch(status);
    if (match == null) return null;
    return (version: match.group(1)!.trim(), built: match.group(2)!.trim());
  }

  /// `sd=<used KB>|<total KB>` in a status; null when it sent no card figures (no card, or older firmware).
  static ({int usedKb, int totalKb})? storageFrom(String status) {
    final match = RegExp(r'sd=(\d+)\|(\d+)').firstMatch(status);
    if (match == null) return null;
    final used = int.parse(match.group(1)!);
    final total = int.parse(match.group(2)!);
    return total <= 0 ? null : (usedKb: used, totalKb: total);
  }

  /// "3.1 GB of 29.7 GB used" (or in MB for small figures).
  static String describeStorage(({int usedKb, int totalKb}) card) {
    String size(int kb) => kb >= 1024 * 1024
        ? '${(kb / (1024 * 1024)).toStringAsFixed(1)} GB'
        : '${(kb / 1024).round()} MB';
    return '${size(card.usedKb)} of ${size(card.totalKb)} used';
  }
}
