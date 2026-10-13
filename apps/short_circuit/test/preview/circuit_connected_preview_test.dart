import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadRoboto);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets('connected Circuit page in $mode', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      messenger.setMockMethodCallHandler(const MethodChannel('circuit/relay'), (
        call,
      ) async {
        return switch (call.method) {
          'write' => true,
          'status' => 'Connected to Circuit',
          'syncedNotes' => <String>[],
          'requestLocalNetwork' => true,
          _ => null,
        };
      });
      for (final c in [
        'circuit/audio_status',
        'circuit/phone_recorder_events',
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
      }
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
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.text('Circuit').last);
      await tester.pump(const Duration(milliseconds: 500));
      await _snap(tester, key, 'connected_$mode');
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
