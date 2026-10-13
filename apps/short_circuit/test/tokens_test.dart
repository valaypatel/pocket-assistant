import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:short_circuit/main.dart';

void main() {
  appearanceTests();
  group('colour contrast', () {
    for (final entry in {
      'light': ScPalette.light,
      'dark': ScPalette.darkMode,
    }.entries) {
      test('${entry.key}: every text pair is at least 4.5:1', () {
        for (final (name, text, behind) in entry.value.textPairs) {
          expect(
            scContrast(text, behind),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key} $name',
          );
        }
      });

      test('${entry.key}: every icon colour is at least 3:1', () {
        for (final (name, icon, behind) in entry.value.graphicPairs) {
          expect(
            scContrast(icon, behind),
            greaterThanOrEqualTo(3),
            reason: '${entry.key} $name',
          );
        }
      });
    }

    test('the contrast function matches known values', () {
      expect(scContrast(Colors.black, Colors.white), closeTo(21, 0.01));
      expect(scContrast(Colors.white, Colors.white), closeTo(1, 0.001));
    });
  });

  group('tokens', () {
    test('the light palette is the colours the app has always had', () {
      expect(ScPalette.light.bg, Sc.bg);
      expect(ScPalette.light.accent, Sc.accent);
      expect(ScPalette.light.muted, Sc.muted);
      expect(ScPalette.light.danger, Sc.danger);
    });

    test('spacing steps rise and sit on the 4-point grid', () {
      for (var i = 0; i < ScSpace.scale.length; i++) {
        expect(ScSpace.scale[i] % 4, 0);
        if (i > 0) expect(ScSpace.scale[i], greaterThan(ScSpace.scale[i - 1]));
      }
    });

    test('type: nothing below 13, essential text 14 or more, body 16', () {
      for (final style in ScType.all) {
        expect(style.fontSize, greaterThanOrEqualTo(13));
        expect(style.height, isNotNull);
      }
      expect(ScType.body.fontSize, 16);
      expect(ScType.label.fontSize, greaterThanOrEqualTo(14));
      expect(ScType.transcript.fontSize, greaterThan(ScType.body.fontSize!));
    });

    testWidgets('a theme carries its palette to context.sc', (tester) async {
      late ScPalette seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildScTheme(),
          darkTheme: buildScDarkTheme(),
          themeMode: ThemeMode.dark,
          home: Builder(
            builder: (context) {
              seen = context.sc;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen.bg, ScPalette.darkMode.bg);
    });

    testWidgets('the light theme page colour is unchanged', (tester) async {
      expect(buildScTheme().scaffoldBackgroundColor, Sc.bg);
      expect(buildScDarkTheme().scaffoldBackgroundColor, ScPalette.darkMode.bg);
    });
  });
}

// Appearance: light, dark or the phone's setting, chosen in Settings.
void appearanceTests() {
  group('appearance', () {
    tearDown(() => appThemeMode.value = ThemeMode.system);

    test('names map to modes, unknown means the phone', () {
      expect(themeModeFromName('light'), ThemeMode.light);
      expect(themeModeFromName('dark'), ThemeMode.dark);
      expect(themeModeFromName('system'), ThemeMode.system);
      expect(themeModeFromName(null), ThemeMode.system);
      expect(themeModeFromName('purple'), ThemeMode.system);
    });

    testWidgets('choosing Dark in Settings switches the app and is kept', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const ShortCircuitApp());
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Settings').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Dark'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(appThemeMode.value, ThemeMode.dark);
      final saved = await SharedPreferences.getInstance();
      expect(saved.getString('theme_mode'), 'dark');
      await tester.tap(find.text('Light'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(appThemeMode.value, ThemeMode.light);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
