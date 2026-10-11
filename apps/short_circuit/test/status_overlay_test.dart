import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  tearDown(() {
    statusPill.value = null;
    statusSnack.value = null;
    statusPillHidden.value = false;
  });

  Widget app() => MaterialApp(
    builder: (context, child) => StatusOverlay(child: child!),
    home: const Scaffold(body: Text('page')),
  );

  testWidgets('shows nothing until something is happening', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('page'), findsOneWidget);
    expect(find.byType(StatusPillBar), findsNothing);
    expect(find.byType(StatusSnackBar), findsNothing);
  });

  testWidgets('the pill sits over the page and its action works', (
    tester,
  ) async {
    var retried = 0;
    await tester.pumpWidget(app());
    statusPill.value = StatusPillBar(
      icon: Icons.sync,
      title: 'Sync needs attention',
      detail: 'will retry',
      actionLabel: 'Retry',
      onAction: () => retried++,
      onTap: () {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Sync needs attention'), findsOneWidget);
    expect(find.text('page'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
    statusPill.value = null;
    await tester.pumpAndSettle();
    expect(find.byType(StatusPillBar), findsNothing);
  });

  testWidgets('the pill steps aside while a sheet is open', (tester) async {
    await tester.pumpWidget(app());
    statusPill.value = StatusPillBar(
      icon: Icons.mic,
      title: 'Recording',
      onTap: () {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Recording'), findsOneWidget);
    statusPillHidden.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Recording'), findsNothing);
  });

  testWidgets('the progress bar and the playback snackbar show', (
    tester,
  ) async {
    var stopped = 0;
    await tester.pumpWidget(app());
    statusPill.value = StatusPillBar(
      icon: Icons.sync,
      title: 'Syncing from Circuit · 40%',
      progress: 40,
      onTap: () {},
    );
    statusSnack.value = StatusSnackBar(
      icon: Icons.graphic_eq,
      text: 'Playing on Circuit · 0:12',
      actionLabel: 'Stop',
      onAction: () => stopped++,
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Playing on Circuit · 0:12'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    expect(stopped, 1);
  });

  testWidgets('the snackbar drops to the bottom edge on a pushed page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [statusRouteObserver],
        builder: (context, child) => StatusOverlay(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('detail')),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    statusSnack.value = StatusSnackBar(
      icon: Icons.graphic_eq,
      text: 'Playing on Circuit',
      onAction: () {},
    );
    await tester.pumpAndSettle();
    final homeY = tester.getBottomLeft(find.byType(StatusSnackBar)).dy;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(StatusSnackBar)).dy,
      greaterThan(homeY),
    );
    Navigator.of(tester.element(find.text('detail'))).pop();
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.byType(StatusSnackBar)).dy, homeY);
  });
}
