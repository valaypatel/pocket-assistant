import 'package:flutter_test/flutter_test.dart';
import 'package:short_circuit/main.dart';

void main() {
  test('reads the state, network, IP address and MAC address', () {
    final status = parseWifiStatus(
      '@wifi-status\nconnected\nHome Wi-Fi\n10.0.0.179\nmac=70:04:1D:D7:AE:CC',
    )!;
    expect(status.state, 'connected');
    expect(status.ssid, 'Home Wi-Fi');
    expect(status.detail, '10.0.0.179');
    expect(status.mac, '70:04:1D:D7:AE:CC');
  });

  test('older firmware sends no MAC address and the detail is untouched', () {
    final status = parseWifiStatus(
      '@wifi-status\nfailed\nHome\nWrong password',
    )!;
    expect(status.detail, 'Wrong password');
    expect(status.mac, '');
  });

  test('a failure reason that spans lines survives next to the MAC', () {
    final status = parseWifiStatus(
      '@wifi-status\nfailed\nHome\nWrong password\nTry again\nmac=AA:BB:CC:DD:EE:FF',
    )!;
    expect(status.detail, 'Wrong password\nTry again');
    expect(status.mac, 'AA:BB:CC:DD:EE:FF');
  });

  test('an empty status is ignored', () {
    expect(parseWifiStatus('@wifi-status'), isNull);
  });

  test('reads how many networks Circuit remembers', () {
    final status = parseWifiStatus(
      '@wifi-status\nconnected\nHome\n10.0.0.5\nmac=AA:BB:CC:DD:EE:FF\nsaved=3',
    );
    expect(status!.saved, 3);
    expect(status.mac, 'AA:BB:CC:DD:EE:FF');
    expect(status.detail, '10.0.0.5');
    final old = parseWifiStatus('@wifi-status\nconnected\nHome\n10.0.0.5');
    expect(old!.saved, isNull);
  });
}
