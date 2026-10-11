import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool connected = false,
  RelayLink link = RelayLink.off,
  String wifi = 'none',
  bool stay = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: CircuitChip(
        connected: connected,
        link: link,
        wifiState: wifi,
        stayConnected: stay,
        onTap: () {},
      ),
    ),
  ),
);

Color _dot(WidgetTester t) =>
    ((t.widget<Container>(find.byKey(const ValueKey('circuit-dot'))).decoration)
            as BoxDecoration)
        .color!;
Color _icon(WidgetTester t, String key) =>
    t.widget<Icon>(find.byKey(ValueKey(key))).color!;

void main() {
  group('what the background service says', () {
    test('only a real link counts as connected', () {
      expect(relayLinkFromStatus('Connected to Circuit'), RelayLink.connected);
      // Bluetooth is up; only the phone's internet is missing.
      expect(
        relayLinkFromStatus('Phone internet unavailable'),
        RelayLink.connected,
      );
    });

    test('still trying is not connected', () {
      for (final status in [
        'Connecting to Circuit…',
        'Securing the connection…',
        'Circuit reconnecting in 8s…',
        'Bluetooth is off',
      ]) {
        expect(relayLinkFromStatus(status), RelayLink.trying, reason: status);
      }
    });

    test('stopped, missing and needing repair', () {
      expect(relayLinkFromStatus('Stopped'), RelayLink.off);
      expect(relayLinkFromStatus(null), RelayLink.off);
      expect(
        relayLinkFromStatus('Circuit needs repair in Short-Circuit'),
        RelayLink.needsRepair,
      );
    });
  });

  group('the indicators', () {
    testWidgets('a service that is only trying does not look connected', (
      tester,
    ) async {
      await _pump(
        tester,
        link: RelayLink.trying,
        wifi: 'connected', // an old report from the board
        stay: true,
      );
      expect(_dot(tester), Sc.orange);
      expect(
        _icon(tester, 'circuit-wifi'),
        CircuitChip.grey,
      ); // not trusted: old
      expect(_icon(tester, 'circuit-stay'), Sc.orange);
      expect(
        find.bySemanticsLabel(RegExp('Circuit, connecting')),
        findsOneWidget,
      );
    });

    testWidgets('connected shows green and the board Wi-Fi', (tester) async {
      await _pump(
        tester,
        connected: true,
        link: RelayLink.connected,
        wifi: 'connected',
        stay: true,
      );
      expect(_dot(tester), const Color(0xff3b9a68));
      expect(_icon(tester, 'circuit-wifi'), Sc.green);
      expect(_icon(tester, 'circuit-stay'), Sc.green);
      expect(
        find.bySemanticsLabel(
          'Circuit, connected. Wi-Fi connected. Stay connected on',
        ),
        findsOneWidget,
      );
    });

    testWidgets('nothing running is all grey and says not connected', (
      tester,
    ) async {
      await _pump(tester);
      expect(_dot(tester), CircuitChip.grey);
      expect(_icon(tester, 'circuit-wifi'), CircuitChip.grey);
      expect(_icon(tester, 'circuit-stay'), CircuitChip.grey);
      expect(
        find.bySemanticsLabel('Circuit, not connected. Stay connected off'),
        findsOneWidget,
      );
    });

    testWidgets('a lost pairing is named, not shown as connecting', (
      tester,
    ) async {
      await _pump(tester, link: RelayLink.needsRepair);
      expect(
        find.bySemanticsLabel(RegExp('Circuit, needs pairing again')),
        findsOneWidget,
      );
    });

    testWidgets('connected with Wi-Fi failed shows the crossed-out icon', (
      tester,
    ) async {
      await _pump(
        tester,
        connected: true,
        link: RelayLink.connected,
        wifi: 'failed',
      );
      expect(_icon(tester, 'circuit-wifi'), CircuitChip.grey);
      expect(
        find.bySemanticsLabel(RegExp('Wi-Fi not connected')),
        findsOneWidget,
      );
    });
  });
}
