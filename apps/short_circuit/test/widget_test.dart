import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  test('extracts readable fields from Gemini JSON instead of showing JSON', () {
    final parsed = parseGeminiTranscriptionPayload(
      '```json\n{"category":"task","title":"Buy milk",'
      '"transcript":"Buy milk tomorrow"}\n```',
    );

    expect(parsed?['category'], 'task');
    expect(parsed?['title'], 'Buy milk');
    expect(parsed?['transcript'], 'Buy milk tomorrow');
  });

  test('extracts nested Gemini response envelopes', () {
    final parsed = parseGeminiTranscriptionPayload(
      '{"result":{"category":"note","title":"Idea",'
      '"transcript":"A useful idea"}}',
    );

    expect(parsed?['title'], 'Idea');
    expect(parsed?['transcript'], 'A useful idea');
  });

  testWidgets('shows the Short-Circuit home with bottom navigation', (tester) async {
    await tester.pumpWidget(const ShortCircuitApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('Hey,'), findsOneWidget);
    expect(find.text('YOUR DAY AT A GLANCE'), findsOneWidget);
    expect(find.text('Circuit'), findsWidgets);
    for (final label in ['Home', 'Notes', 'Tasks', 'Settings']) {
      expect(find.text(label), findsWidgets);
    }

    await tester.tap(find.text('Tasks'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Nothing to do right now.'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Google Gemini'), findsOneWidget);
    // CircuitHomePage schedules a one-time audio cleanup after startup.
    await tester.pump(const Duration(seconds: 3));
  });
}
