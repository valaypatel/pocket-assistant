import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

/// The whole app (real pages, real navigation) rendered in light and dark, so the redesign can be
/// looked at without a phone. Set PREVIEW_DIR to write the images.
Future<void> _snap(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['PREVIEW_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadRoboto);

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets('the app in $mode mode', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        'circuit_notes': jsonEncode([
          CircuitNote(
            id: 'a',
            createdAt: DateTime.now().subtract(const Duration(hours: 2)),
            status: 'Transcription ready',
            transcript: 'Remember to call the plumber about the kitchen tap.',
            title: 'Call the plumber about the kitchen tap',
            kind: 'voice',
          ).toJson(),
          CircuitNote(
            id: 'b',
            createdAt: DateTime.now().subtract(const Duration(days: 1)),
            status: 'No speech detected. Audio kept for review.',
            title: 'Voice note',
            kind: 'voice',
          ).toJson(),
        ]),
      });
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: const ShortCircuitApp()),
      );
      await tester.pump(const Duration(seconds: 1));
      await _snap(tester, key, 'app_notes_$mode');
      for (final tab in ['Tasks', 'Circuit', 'Settings']) {
        await tester.tap(find.text(tab).last);
        await tester.pump(const Duration(milliseconds: 500));
        await _snap(tester, key, 'app_${tab.toLowerCase()}_$mode');
      }
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
