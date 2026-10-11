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

  testWidgets('Stop stays its own control for a screen reader', (tester) async {
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
      tester.getSemantics(find.byTooltip('Stop recording')),
      matchesSemantics(
        label: 'Stop recording',
        tooltip: 'Stop recording',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
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
}
