import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

void main() {
  test(
    'a note is reviewed on its own only with an AI service and the toggle on',
    () {
      expect(
        shouldEnrichAutomatically(aiConnected: true, autoEnrich: true),
        isTrue,
      );
      expect(
        shouldEnrichAutomatically(aiConnected: true, autoEnrich: false),
        isFalse,
      );
      expect(
        shouldEnrichAutomatically(aiConnected: false, autoEnrich: true),
        isFalse,
      );
      expect(
        shouldEnrichAutomatically(aiConnected: false, autoEnrich: false),
        isFalse,
      );
    },
  );

  Future<void> openSettings(
    WidgetTester tester,
    Map<String, Object> prefs,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(prefs);
    await tester.pumpWidget(const ShortCircuitApp());
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Settings').last);
    await tester.pump(const Duration(milliseconds: 400));
    // The page is a lazy list; scroll down to the row as a person would.
    await tester.scrollUntilVisible(
      find.text('Review new notes'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }

  Switch reviewSwitch(WidgetTester tester) => tester.widget<Switch>(
    find.descendant(
      of: find.ancestor(
        of: find.text('Review new notes'),
        matching: find.byType(ScRow),
      ),
      matching: find.byType(Switch),
    ),
  );

  testWidgets('Settings has the toggle, on by default, below transcribing', (
    tester,
  ) async {
    await openSettings(tester, {});
    expect(find.text('Review new notes'), findsOneWidget);
    expect(reviewSwitch(tester).value, isTrue);
    // Without an AI service it says so, rather than a switch that seems to do nothing.
    expect(find.textContaining('Needs an AI service'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('turning it off is remembered', (tester) async {
    await openSettings(tester, {});
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Review new notes'),
          matching: find.byType(ScRow),
        ),
        matching: find.byType(Switch),
      ),
    );
    await tester.pump();
    expect(reviewSwitch(tester).value, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool('auto_enrich'),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a saved off stays off when the app starts', (tester) async {
    await openSettings(tester, {'auto_enrich': false});
    expect(reviewSwitch(tester).value, isFalse);
    await tester.pump(const Duration(seconds: 3));
  });
}
