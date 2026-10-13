import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

void main() {
  Widget page({
    VoidCallback? onFinish,
    VoidCallback? onOpenCircuit,
    VoidCallback? onOpenAi,
  }) => MaterialApp(
    theme: buildScTheme(),
    home: OnboardingPage(
      onFinish: onFinish ?? () {},
      onOpenCircuit: onOpenCircuit ?? () {},
      onOpenAi: onOpenAi ?? () {},
    ),
  );

  group('the welcome screens', () {
    testWidgets('three steps, Next moves on, the last says Get started', (
      tester,
    ) async {
      var finished = 0;
      await tester.pumpWidget(page(onFinish: () => finished++));
      expect(find.text('Your voice notes, kept private'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Connect Circuit'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Add AI when you want it'), findsOneWidget);
      expect(find.text('Get started'), findsOneWidget);
      expect(finished, 0);
      await tester.tap(find.text('Get started'));
      expect(finished, 1);
    });

    testWidgets('Skip finishes at once', (tester) async {
      var finished = 0;
      await tester.pumpWidget(page(onFinish: () => finished++));
      await tester.tap(find.text('Skip'));
      expect(finished, 1);
    });

    testWidgets('each action leads where it says', (tester) async {
      var circuit = 0;
      var ai = 0;
      await tester.pumpWidget(
        page(onOpenCircuit: () => circuit++, onOpenAi: () => ai++),
      );
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open the Circuit tab'));
      expect(circuit, 1);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Settings'));
      expect(ai, 1);
    });

    testWidgets('text at 200% still shows the button', (tester) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: page(),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Next'), findsOneWidget);
    });
  });

  group('when the app shows them', () {
    setUp(() {
      Onboarding.enabled = true;
      FlutterSecureStorage.setMockInitialValues({});
    });
    tearDown(() => Onboarding.enabled = false);

    testWidgets('a new install sees them once, and not again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Your voice notes, kept private'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No notes yet'), findsOneWidget);
      final saved = await SharedPreferences.getInstance();
      expect(saved.getBool(Onboarding.doneKey), isTrue);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('an app that already has notes never shows them', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'circuit_notes': '[]'});
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Your voice notes, kept private'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
