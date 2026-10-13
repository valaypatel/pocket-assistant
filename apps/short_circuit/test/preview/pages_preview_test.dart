import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

import 'preview_support.dart';

/// The settings sub-pages in dark mode, to check them without a phone.
void main() {
  setUpAll(loadRoboto);
  final pages = <String, Widget Function()>{
    'gemini': () => const GeminiSettingsPage(),
    'ai_service': () => const AiServiceSettingsPage(),
    'backup': () => BackupPage(onRestored: () async {}),
    'music': () => const MusicSettingsPage(),
  };
  for (final entry in pages.entries) {
    testWidgets('${entry.key} page in dark', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      await renderPreview(
        tester,
        'page_${entry.key}_dark',
        entry.value(),
        theme: buildScDarkTheme(),
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
