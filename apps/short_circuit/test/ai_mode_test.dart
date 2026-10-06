import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

class _Active implements Entitlement {
  const _Active();
  @override
  Future<bool> isActive() async => true;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('an unknown or missing mode is the own-key mode', () {
    expect(AiMode.parse(null), AiMode.ownKey);
    expect(AiMode.parse('nonsense'), AiMode.ownKey);
    expect(AiMode.parse('subscription'), AiMode.subscription);
  });

  test('the chosen mode is remembered', () async {
    expect(await AiModeStore.read(), AiMode.ownKey);
    await AiModeStore.save(AiMode.subscription);
    expect(await AiModeStore.read(), AiMode.subscription);
  });

  test('own-key mode uses the Gemini client', () {
    expect(transcriberFor(AiMode.ownKey), isA<GeminiClient>());
    expect(transcriberFor(AiMode.subscription), isA<SubscriptionTranscriber>());
  });

  test('subscription mode refuses without a subscription', () {
    expect(
      () => const SubscriptionTranscriber().transcribeWav(Uint8List(0)),
      throwsA(isA<SubscriptionUnavailable>()),
    );
  });

  test('subscription mode still refuses while no backend exists', () {
    expect(
      () =>
          const SubscriptionTranscriber(entitlement: _Active())
              .transcribeWav(Uint8List(0)),
      throwsA(isA<SubscriptionUnavailable>()),
    );
  });

  testWidgets('settings offer own key, with subscription not selectable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildScTheme(), home: const GeminiSettingsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('My own key'), findsOneWidget);
    expect(find.text('Subscription'), findsOneWidget);
    await tester.tap(find.text('Subscription'));
    await tester.pumpAndSettle();
    expect(await AiModeStore.read(), AiMode.ownKey);
  });
}
