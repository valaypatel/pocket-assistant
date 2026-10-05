import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  ),
);

void main() {
  testWidgets('a voice note shows what is happening and counts up', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        RecordingIsland(
          elapsed: const Duration(seconds: 75),
          song: false,
          busy: false,
          onStop: () {},
          onExpand: () {},
        ),
      ),
    );
    expect(find.text('Recording on Circuit'), findsOneWidget);
    expect(find.text('01:15'), findsOneWidget);
  });

  testWidgets('a song clip counts down and shows its progress', (tester) async {
    await tester.pumpWidget(
      _host(
        RecordingIsland(
          elapsed: const Duration(seconds: 4),
          song: true,
          busy: false,
          onStop: () {},
          onExpand: () {},
        ),
      ),
    );
    expect(find.text('Listening for a song'), findsOneWidget);
    expect(find.text('00:08'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('Stop stops, and the rest of the pill opens the full view', (
    tester,
  ) async {
    var stopped = 0;
    var expanded = 0;
    await tester.pumpWidget(
      _host(
        RecordingIsland(
          elapsed: const Duration(seconds: 3),
          song: false,
          busy: false,
          onStop: () => stopped++,
          onExpand: () => expanded++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Stop recording'));
    expect(stopped, 1);
    expect(expanded, 0);
    await tester.tap(find.text('Recording on Circuit'));
    expect(expanded, 1);
    expect(stopped, 1);
  });

  testWidgets('Stop cannot be pressed while a request is in flight', (
    tester,
  ) async {
    var stopped = 0;
    await tester.pumpWidget(
      _host(
        RecordingIsland(
          elapsed: Duration.zero,
          song: false,
          busy: true,
          onStop: () => stopped++,
          onExpand: () {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Stop recording'), warnIfMissed: false);
    expect(stopped, 0);
  });

  testWidgets('the pill is one labelled button for a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        RecordingIsland(
          elapsed: const Duration(seconds: 3),
          song: false,
          busy: false,
          onStop: () {},
          onExpand: () {},
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(RecordingIsland)),
      matchesSemantics(
        label: 'Recording on Circuit',
        hint: 'Opens the full recording view',
        isButton: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('it fits a 320 dp phone with text at double size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        RecordingIsland(
          elapsed: const Duration(seconds: 3),
          song: true,
          busy: false,
          onStop: () {},
          onExpand: () {},
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(RecordingIsland)).width, 296);
  });

  group('RecordingMorph', () {
    final chipKey = GlobalKey();
    Widget app(ValueNotifier<bool> active, {bool still = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: still),
        child: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (context, on, _) => RecordingMorph(
              active: on,
              chipKey: chipKey,
              island: () => RecordingIsland(
                decorated: false,
                elapsed: const Duration(seconds: 5),
                song: false,
                busy: false,
                onStop: () {},
                onExpand: () {},
              ),
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(key: chipKey, width: 90, height: 40),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('grows out of the indicator, then folds back into it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final active = ValueNotifier(false);
      await tester.pumpWidget(app(active));
      expect(find.text('Recording on Circuit'), findsNothing);
      final chipTop = tester.getTopLeft(find.byKey(chipKey));

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      // Partway: wider than the indicator (90), not yet the full pill (376).
      final partway = tester.getSize(find.byType(OverflowBox)).width;
      expect(partway, greaterThan(90));
      expect(partway, lessThan(376));

      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(OverflowBox)).width,
        376,
      ); // 400 - 2 x 12
      expect(find.text('Recording on Circuit'), findsOneWidget);
      // The page slid down to make room: the pill covers nothing.
      expect(tester.getTopLeft(find.byKey(chipKey)).dy, chipTop.dy + 72);

      active.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final folding = tester.getSize(find.byType(OverflowBox)).width;
      expect(folding, greaterThan(90));
      expect(folding, lessThan(376));
      await tester.pumpAndSettle();
      expect(find.text('Recording on Circuit'), findsNothing);
      expect(tester.getTopLeft(find.byKey(chipKey)), chipTop);
    });

    testWidgets('with animations off it just appears and disappears', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final active = ValueNotifier(false);
      await tester.pumpWidget(app(active, still: true));
      active.value = true;
      await tester.pump();
      expect(tester.getSize(find.byType(OverflowBox)).width, 376);
      active.value = false;
      await tester.pump();
      expect(find.text('Recording on Circuit'), findsNothing);
    });
  });
}
