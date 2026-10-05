import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  testWidgets(
    'the brand mark is the size asked for and hidden from screen readers',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: ScBrandMark(size: 38))),
      );
      expect(tester.getSize(find.byType(ScBrandMark)), const Size(38, 38));
      // Decorative: nothing about it is announced.
      expect(
        find.descendant(
          of: find.byType(ScBrandMark),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a header with the mark and a long greeting fits a 320 dp phone at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 2, right: 12),
                      child: ScBrandMark(size: 38),
                    ),
                    Expanded(child: Text('Hey, Valay Patel and friends.')),
                    SizedBox(width: 12),
                    Icon(Icons.bluetooth),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
