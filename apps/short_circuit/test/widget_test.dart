import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  testWidgets('shows the Short-Circuit connection screen', (tester) async {
    await tester.pumpWidget(const ShortCircuitApp());

    expect(find.text('Short-Circuit'), findsOneWidget);
    expect(find.text('Scan for Circuit'), findsOneWidget);
  });
}
