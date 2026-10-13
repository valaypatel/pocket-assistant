import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

Widget _host(Widget dock, {double scale = 1}) => MaterialApp(
  theme: buildScTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: Padding(padding: const EdgeInsets.all(20), child: dock),
    ),
  ),
);

void main() {
  testWidgets('at rest it is a labelled pill that can be tapped', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(CaptureDock(mode: DockMode.pill, onPill: () => taps++)),
    );
    expect(find.text('Record'), findsOneWidget);
    await tester.tap(find.text('Record'));
    expect(taps, 1);
  });

  testWidgets(
    'scrolling collapses it to the icon, still named for screen readers',
    (tester) async {
      await tester.pumpWidget(
        _host(const CaptureDock(mode: DockMode.pill, collapsed: true)),
      );
      // The label is folded to nothing, and the pill is just the icon.
      expect(tester.getSize(find.byType(Container).first).width, 56);
      expect(find.bySemanticsLabel('Record'), findsOneWidget);
    },
  );

  testWidgets('recording grows into a bar with the time and Stop', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      _host(
        CaptureDock(
          mode: DockMode.recording,
          title: 'Recording on this phone',
          elapsed: () => const Duration(seconds: 75),
          level: () => .5,
          onStop: () => stopped = true,
          onTogglePause: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1:15'), findsOneWidget);
    expect(find.text('Recording on this phone'), findsOneWidget);
    expect(find.byTooltip('Pause recording'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop and save'));
    expect(stopped, isTrue);
    // The bar spans the page width.
    expect(tester.getSize(find.byType(Container).first).width, 800 - 40);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('paused says so and offers Resume', (tester) async {
    await tester.pumpWidget(
      _host(
        CaptureDock(
          mode: DockMode.recording,
          paused: true,
          elapsed: () => const Duration(seconds: 5),
          onTogglePause: () {},
          onStop: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Paused'), findsOneWidget);
    expect(find.byTooltip('Resume recording'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the recording bar fits a narrow phone with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        CaptureDock(
          mode: DockMode.recording,
          title: 'Recording on this phone',
          elapsed: () => const Duration(minutes: 12, seconds: 3),
          level: () => .8,
          onTogglePause: () {},
          onStop: () {},
        ),
        scale: 1.6,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Stop and save'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden shows nothing', (tester) async {
    await tester.pumpWidget(_host(const CaptureDock(mode: DockMode.hidden)));
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('the pill grows into the bar in small steps, not a jump', (
    tester,
  ) async {
    Widget dock(DockMode mode) => _host(
      CaptureDock(
        mode: mode,
        elapsed: () => const Duration(seconds: 3),
        onStop: () {},
      ),
    );
    await tester.pumpWidget(dock(DockMode.pill));
    await tester.pumpWidget(dock(DockMode.recording));
    final widths = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      widths.add(tester.getSize(find.byType(Container).first).width);
    }
    for (var i = 1; i < widths.length; i++) {
      expect(widths[i], greaterThanOrEqualTo(widths[i - 1]));
      // No single frame covers more than a third of the whole distance.
      expect(widths[i] - widths[i - 1], lessThan((800 - 40 - 130) / 3));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(find.byType(Container).first).width, 800 - 40);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
