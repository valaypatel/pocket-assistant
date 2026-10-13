import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

const _capture = bool.fromEnvironment('SC_CAPTURE_UI');

Future<void> _shot(WidgetTester tester, String name) async {
  if (!_capture) return;
  await tester.pump();
  final render = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary),
  );
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _host(Widget child, {double scale = 1}) => RepaintBoundary(
  child: MaterialApp(
    theme: buildScTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  ),
);

TranscriptPage _note() => TranscriptPage(
  createdAt: DateTime(2026, 10, 10, 10, 24),
  noteId: 'preview',
  category: 'work',
  title: 'Launch, without the noise.',
  status: 'Ready',
  summary:
      'Make the launch about one moment: a thought becoming something useful.',
  transcript:
      'Send the outline first, then book a design review tomorrow at ten.',
  englishTranslation: 'Share the outline before the design review.',
  onForceTranscribe: (_) async => null,
  audioPath: null,
  onPlayNote: (_) async {},
  onDeleteNote: (_) async {},
  onCreateReminder: (_) async => null,
  onAddTask: (_, _) async {},
  onOpenChat: () {},
  onSuggestionState: (_, _, _) async {},
  suggestions: const [
    NoteActionSuggestion(
      id: 'suggestion',
      type: 'task',
      title: 'Send the launch outline',
      details: 'Share the core story before the review.',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_capture) return;
    final fontDirectory = Platform.environment['SC_FONT_DIR'];
    if (fontDirectory != null) {
      final loader = FontLoader('Roboto');
      for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']) {
        final bytes = await File('$fontDirectory/$name').readAsBytes();
        loader.addFont(Future.value(bytes.buffer.asByteData()));
      }
      await loader.load();
    }
    final icons = FontLoader('packages/lucide_icons_flutter/Lucide');
    icons.addFont(
      rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
    );
    await icons.load();
  });
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'circuit/audio_status',
      'circuit/phone_recorder_events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(const MethodChannel('circuit/relay'), (
      call,
    ) async {
      return switch (call.method) {
        'status' => 'Stopped',
        'syncedNotes' => <String>[],
        'requestLocalNetwork' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('circuit/phone_recorder'),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('capture remains reachable on a narrow phone with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          theme: buildScTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const CircuitHomePage(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Capture a thought'));
    await tester.pumpAndSettle();
    expect(find.text('This phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, 'capture-large-text');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('reading tabs switch between original, summary and translation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(_note()));
    await tester.pump();
    expect(find.textContaining('Make the launch about'), findsOneWidget);
    await _shot(tester, 'note-summary');
    await tester.tap(find.text('Transcript'));
    await tester.pump();
    expect(find.textContaining('Send the outline first'), findsOneWidget);
    await tester.tap(find.text('Translation'));
    await tester.pump();
    expect(
      find.text('Share the outline before the design review.'),
      findsOneWidget,
    );
    expect(find.byTooltip('Approve suggestion'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search clears immediately and restores the note list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'circuit_notes': jsonEncode([
        CircuitNote(
          id: 'n1',
          createdAt: DateTime(2026, 10, 10),
          title: 'Launch planning',
          transcript: 'Share the outline',
          status: 'Ready',
        ).toJson(),
        CircuitNote(
          id: 'n2',
          createdAt: DateTime(2026, 10, 9),
          title: 'Morning ideas',
          transcript: 'Take a walk',
          status: 'Ready',
        ).toJson(),
      ]),
    });
    await tester.pumpWidget(const RepaintBoundary(child: ShortCircuitApp()));
    await tester.pumpAndSettle();
    await _shot(tester, 'home');
    await tester.tap(find.text('Notes').last);
    await tester.pumpAndSettle();
    await _shot(tester, 'notes');
    await tester.enterText(find.byType(TextField), 'unfindable phrase');
    await tester.pump();
    expect(find.text('Nothing matches “unfindable phrase”'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.textContaining('Nothing matches'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.tap(find.text('Tasks').last);
    await tester.pumpAndSettle();
    await _shot(tester, 'tasks');
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await _shot(tester, 'settings');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backup modes keep secrets masked and expose a reveal action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(BackupPage(onRestored: () async {})));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show passphrase').first);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).obscureText,
      isFalse,
    );
    await _shot(tester, 'backup');
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('Choose backup file'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byTooltip('Choose backup file'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await _shot(tester, 'restore');
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording stop remains reachable with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var stops = 0;
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: SafeArea(
              child: RecordingView(
                elapsed: const Duration(seconds: 42),
                song: false,
                busy: false,
                onStop: () => stops++,
              ),
            ),
          ),
          scale: scale,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (scale == 1) await _shot(tester, 'recording');
      await tester.scrollUntilVisible(
        find.byTooltip('Stop recording'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Stop recording'));
      expect(tester.takeException(), isNull);
    }
    expect(stops, 2);
  });

  testWidgets('action controls wrap at large text sizes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: ScActionBar(
              children: [
                for (final label in [
                  'Play',
                  'Ask',
                  'AI review',
                  'Transcribe',
                  'Delete',
                ])
                  ScIconButton(
                    icon: Icons.check,
                    tooltip: label,
                    caption: label,
                    onPressed: () {},
                  ),
              ],
            ),
          ),
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    for (final label in ['Play', 'Ask', 'AI review', 'Transcribe', 'Delete']) {
      expect(find.text(label), findsOneWidget);
    }
  });
}
