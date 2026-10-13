import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen previews: render a widget to a PNG with the real Roboto font, so a layout can be looked at
/// without a phone. Set PREVIEW_DIR to a folder to write the images; without it nothing is written.
///
///   PREVIEW_DIR=/tmp/previews flutter test test/preview
Future<void> loadRoboto() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  final fonts = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!fonts.existsSync()) return;
  final loader = FontLoader('Roboto');
  for (final name in ['Regular', 'Medium', 'Bold']) {
    final file = File('${fonts.path}/Roboto-$name.ttf');
    if (file.existsSync()) {
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
    }
  }
  await loader.load();

  // The icon font ships inside the lucide_icons_flutter package; tests do not load package fonts.
  final home = Platform.environment['HOME'];
  final pub = home == null
      ? null
      : Directory('$home/.pub-cache/hosted/pub.dev');
  if (pub != null && pub.existsSync()) {
    for (final dir in pub.listSync().whereType<Directory>()) {
      if (!dir.path.split('/').last.startsWith('lucide_icons_flutter-'))
        continue;
      final ttf = File('${dir.path}/assets/lucide.ttf');
      if (ttf.existsSync()) {
        final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(ByteData.sublistView(ttf.readAsBytesSync())));
        await icons.load();
        break;
      }
    }
  }
}

/// Renders [child] at [width] x [height] dp (3x pixels) with the given text scale, and writes
/// $PREVIEW_DIR/[name].png when PREVIEW_DIR is set.
Future<void> renderPreview(
  WidgetTester tester,
  String name,
  Widget child, {
  required ThemeData theme,
  double width = 390,
  double height = 844,
  double textScale = 1,
}) async {
  final dir = Platform.environment['PREVIEW_DIR'];
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          devicePixelRatio: 2,
          textScaler: TextScaler.linear(textScale),
        ),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(body: SafeArea(child: child)),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
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
