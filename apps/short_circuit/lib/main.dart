import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _circuitName = 'Circuit';
final _textServiceId = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
final _textCharacteristicId = Guid('0000fff1-0000-1000-8000-00805f9b34fb');
final _relayCharacteristicId = Guid('0000fff2-0000-1000-8000-00805f9b34fb');
const _relayChannel = MethodChannel('circuit/relay');
const _savedCircuitIdKey = 'saved_circuit_id';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const ShortCircuitApp());
}

class ShortCircuitApp extends StatelessWidget {
  const ShortCircuitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Short-Circuit',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff263238)),
        useMaterial3: true,
      ),
      home: const CircuitHomePage(),
    );
  }
}

class CircuitHomePage extends StatefulWidget {
  const CircuitHomePage({super.key});

  @override
  State<CircuitHomePage> createState() => _CircuitHomePageState();
}

class _CircuitHomePageState extends State<CircuitHomePage> {
  final _messageController = TextEditingController(text: 'Hello from Short-Circuit');
  final _wifiSsidController = TextEditingController();
  final _wifiPasswordController = TextEditingController();
  final Map<String, ScanResult> _circuits = {};

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _relaySubscription;
  Timer? _relayStatusTimer;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _textCharacteristic;
  BluetoothCharacteristic? _relayCharacteristic;
  bool _scanning = false;
  bool _connecting = false;
  bool _sending = false;
  bool _provisioningWifi = false;
  bool _scanningWifi = false;
  bool _hiddenWifi = false;
  bool _startingRelay = false;
  bool _audioBusy = false;
  bool _recordingAudio = false;
  bool _relayActive = false;
  List<String> _wifiNetworks = [];
  String? _savedCircuitId;
  String _status = 'Tap Scan to find your Circuit.';

  @override
  void initState() {
    super.initState();
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      _onScanResults,
      onError: (Object error) => _setStatus('Scan failed: $error'),
    );
    _restoreLastCircuit();
    _refreshRelayStatus();
    _relayStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshRelayStatus());
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _relaySubscription?.cancel();
    _relayStatusTimer?.cancel();
    _messageController.dispose();
    _wifiSsidController.dispose();
    _wifiPasswordController.dispose();
    super.dispose();
  }

  Future<void> _refreshRelayStatus() async {
    try {
      final status = await _relayChannel.invokeMethod<String>('status');
      final audioStatus = await _relayChannel.invokeMethod<String>('audioStatus');
      if (!mounted || status == null) return;
      final active = status != 'Stopped';
      if (active || _relayActive) {
        setState(() {
          _relayActive = active;
          if (active) _status = audioStatus ?? status;
        });
      }
    } on PlatformException {
      // The app can still be used normally if the native relay is unavailable.
    }
  }

  void _onScanResults(List<ScanResult> results) {
    var changed = false;
    for (final result in results) {
      final name = result.advertisementData.advName;
      if (name == _circuitName || result.device.platformName == _circuitName) {
        _circuits[result.device.remoteId.str] = result;
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {});
    }
  }

  Future<void> _restoreLastCircuit() async {
    final preferences = await SharedPreferences.getInstance();
    final deviceId = preferences.getString(_savedCircuitIdKey);
    if (deviceId == null || !mounted) return;
    final relayStatus = await _relayChannel.invokeMethod<String>('status');
    if (relayStatus != null && relayStatus != 'Stopped') {
      setState(() {
        _savedCircuitId = deviceId;
        _relayActive = true;
        _status = relayStatus;
      });
      return;
    }
    setState(() {
      _savedCircuitId = deviceId;
      _status = 'Reconnecting to your saved Circuit…';
    });
    await _connect(BluetoothDevice.fromId(deviceId), savedReconnect: true);
  }

  Future<void> _scan() async {
    final permissionGranted = await _requestBluetoothPermissions();
    if (!permissionGranted) {
      _setStatus('Nearby Devices permission is needed to scan for Circuit.');
      return;
    }
    // adapterStateNow begins as `unknown` until FlutterBluePlus has queried
    // Android. Await the stream's first value so an already-on adapter is not
    // incorrectly shown as off on the first scan attempt.
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _setStatus('Turn on Bluetooth, then try again.');
      return;
    }
    setState(() {
      _circuits.clear();
      _scanning = true;
      _status = 'Scanning for Circuit…';
    });
    try {
      await FlutterBluePlus.startScan(
        withNames: const [_circuitName],
        timeout: const Duration(seconds: 10),
      );
    } catch (error) {
      _setStatus('Scan failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          if (_circuits.isEmpty && _status == 'Scanning for Circuit…') {
            _status = 'No Circuit found. Keep it powered and nearby, then scan again.';
          }
        });
      }
    }
  }

  Future<bool> _requestBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    await Permission.notification.request();
    return statuses.values.every((status) => status.isGranted);
  }

  Future<void> _connect(BluetoothDevice device, {bool savedReconnect = false}) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting to Circuit…';
    });
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _device = null;
            _textCharacteristic = null;
            _relayCharacteristic = null;
            _status = 'Circuit disconnected.';
          });
        }
      });

      final services = await device.discoverServices();
      final service = services.where((item) => item.uuid == _textServiceId).firstOrNull;
      final characteristic = service?.characteristics
          .where((item) => item.uuid == _textCharacteristicId)
          .firstOrNull;
      if (characteristic == null) {
        await device.disconnect();
        throw StateError('Circuit text service was not found.');
      }
      await device.requestMtu(185);
      final relay = service?.characteristics
          .where((item) => item.uuid == _relayCharacteristicId)
          .firstOrNull;
      if (relay != null) {
        await relay.setNotifyValue(true);
        _relaySubscription?.cancel();
        _relaySubscription = relay.lastValueStream.listen(_onRelayMessage);
      }
      if (!mounted) return;
      setState(() {
        _device = device;
        _textCharacteristic = characteristic;
        _relayCharacteristic = relay;
        _status = 'Connected. Send text to the e-ink screen.';
      });
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_savedCircuitIdKey, device.remoteId.str);
      _savedCircuitId = device.remoteId.str;
    } catch (error) {
      _setStatus(savedReconnect
          ? 'Your saved Circuit is not nearby. Tap Scan only if you need to find it again.'
          : 'Connection failed: $error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _sendText() async {
    final text = _messageController.text.trim();
    final characteristic = _textCharacteristic;
    if (characteristic == null || text.isEmpty) return;
    final bytes = utf8.encode(text);
    if (bytes.length > 160) {
      _setStatus('Keep messages to 160 bytes or less for this first firmware.');
      return;
    }
    setState(() => _sending = true);
    try {
      await _writeCircuit(text);
      _setStatus('Sent to Circuit.');
    } catch (error) {
      _setStatus('Send failed: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _provisionWifi() async {
    final characteristic = _textCharacteristic;
    final ssid = _wifiSsidController.text.trim();
    final password = _wifiPasswordController.text;
    if ((characteristic == null && !_relayActive) || ssid.isEmpty) {
      _setStatus('Connect to Circuit and enter a Wi-Fi name first.');
      return;
    }
    if (ssid.contains('\n') || password.contains('\n')) {
      _setStatus('Wi-Fi name and password cannot contain a new line.');
      return;
    }
    final command = '@wifi\n$ssid\n$password';
    if (utf8.encode(command).length > 160) {
      _setStatus('Wi-Fi details are too long for Circuit.');
      return;
    }
    setState(() => _provisioningWifi = true);
    try {
      await _writeCircuit(command);
      _wifiPasswordController.clear();
      _setStatus('Wi-Fi details sent. Circuit is checking its internet connection.');
    } catch (error) {
      _setStatus('Wi-Fi setup failed: $error');
    } finally {
      if (mounted) setState(() => _provisioningWifi = false);
    }
  }

  Future<void> _scanWifi() async {
    final characteristic = _textCharacteristic;
    if ((characteristic == null && !_relayActive) || (_relayCharacteristic == null && !_relayActive)) {
      _setStatus('Update Circuit first, then reconnect to scan Wi-Fi.');
      return;
    }
    setState(() {
      _scanningWifi = true;
      _wifiNetworks = [];
      _status = 'Circuit is scanning nearby Wi-Fi…';
    });
    try {
      await _writeCircuit('@wifi-scan');
      if (_relayActive) {
        await Future<void>.delayed(const Duration(seconds: 3));
        final rawNetworks = await _relayChannel.invokeMethod<List<dynamic>>('wifiNetworks') ?? [];
        _setWifiNetworks(rawNetworks.whereType<String>().toList());
      }
    } catch (error) {
      _setStatus('Wi-Fi scan failed: $error');
      if (mounted) setState(() => _scanningWifi = false);
    }
  }

  void _onRelayMessage(List<int> value) {
    final message = utf8.decode(value, allowMalformed: true);
    if (message.startsWith('@audio-status\n')) {
      final status = message.substring('@audio-status\n'.length);
      setState(() {
        _status = status;
        if (status.startsWith('Recording saved') || status.startsWith('Recording stopped') || status.startsWith('Recording failed')) {
          _recordingAudio = false;
        }
      });
      return;
    }
    if (!message.startsWith('@wifi-list')) return;
    final networks = message
        .split('\n')
        .skip(1)
        .map((ssid) => ssid.trim())
        .where((ssid) => ssid.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    _setWifiNetworks(networks);
  }

  void _setWifiNetworks(List<String> networks) {
    if (!mounted) return;
    setState(() {
      _wifiNetworks = networks;
      _scanningWifi = false;
      _status = networks.isEmpty ? 'No visible Wi-Fi networks found. Use Hidden network for a manual SSID.' : 'Choose a Wi-Fi network and enter its password.';
    });
  }

  Future<void> _writeCircuit(String value) async {
    final characteristic = _textCharacteristic;
    if (characteristic != null) {
      await characteristic.write(utf8.encode(value), withoutResponse: false);
      return;
    }
    if (_relayActive) {
      final sent = await _relayChannel.invokeMethod<bool>('write', {'value': value});
      if (sent == true) return;
    }
    throw StateError('Circuit is not connected.');
  }

  Future<void> _startPhoneRelay() async {
    final device = _device;
    if (device == null) return;
    setState(() => _startingRelay = true);
    try {
      await _relayChannel.invokeMethod<void>('requestBatteryExemption');
      await device.disconnect();
      await _relayChannel.invokeMethod<void>('start', {'address': device.remoteId.str});
      if (!mounted) return;
      setState(() {
        _device = null;
        _textCharacteristic = null;
        _relayCharacteristic = null;
        _circuits.clear();
        _relayActive = true;
        _status = 'Starting phone relay…';
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshRelayStatus();
    } catch (error) {
      _setStatus('Could not start phone relay: $error');
    } finally {
      if (mounted) setState(() => _startingRelay = false);
    }
  }

  Future<void> _stopPhoneRelay() async {
    await _relayChannel.invokeMethod<void>('stop');
    if (mounted) {
      setState(() {
        _relayActive = false;
        _status = 'Phone relay stopped.';
      });
    }
  }

  Future<void> _recordAudio() async {
    if (_audioBusy) return;
    setState(() {
      _audioBusy = true;
      _recordingAudio = true;
    });
    try {
      await _writeCircuit('@audio-record\n30');
      _setStatus('Starting recording on Circuit…');
    } catch (error) {
      _setStatus('Could not start recording: $error');
      if (mounted) setState(() => _recordingAudio = false);
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _stopRecording() async {
    if (!_recordingAudio) return;
    setState(() => _audioBusy = true);
    try {
      await _writeCircuit('@audio-stop');
      _setStatus('Stopping recording…');
    } catch (error) {
      _setStatus('Could not stop recording: $error');
    } finally {
      if (mounted) {
        setState(() {
          _audioBusy = false;
          _recordingAudio = false;
        });
      }
    }
  }

  Future<void> _playAudio() async {
    if (_audioBusy) return;
    setState(() => _audioBusy = true);
    try {
      await _writeCircuit('@audio-play');
      _setStatus('Circuit is playing its latest recording.');
      await Future<void>.delayed(const Duration(seconds: 6));
    } catch (error) {
      _setStatus('Could not play recording: $error');
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final connected = _textCharacteristic != null;
    final relayActive = _relayActive;
    final circuitAvailable = connected || relayActive;
    return Scaffold(
      appBar: AppBar(title: const Text('Short-Circuit')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Circuit companion', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(_status),
            const SizedBox(height: 24),
            if (!relayActive) FilledButton.icon(
              onPressed: _scanning || _connecting || connected ? null : _scan,
              icon: _scanning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bluetooth_searching),
              label: Text(_scanning ? 'Scanning…' : 'Scan for Circuit'),
            ),
            if (_savedCircuitId != null && !connected && !relayActive) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _connecting ? null : () => _connect(BluetoothDevice.fromId(_savedCircuitId!), savedReconnect: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Reconnect saved Circuit'),
              ),
            ],
            if (relayActive) ...[
              const SizedBox(height: 24),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.phonelink_ring),
                  title: const Text('Phone relay'),
                  subtitle: Text(_status),
                  trailing: TextButton(onPressed: _stopPhoneRelay, child: const Text('Stop')),
                ),
              ),
            ],
            if (_circuits.isNotEmpty && !relayActive) ...[
              const SizedBox(height: 24),
              Text('Nearby Circuit devices', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ..._circuits.values.map(
                (result) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.developer_board),
                    title: const Text(_circuitName),
                    subtitle: Text('${result.device.remoteId.str} • ${result.rssi} dBm'),
                    trailing: FilledButton(
                      onPressed: _connecting ? null : () => _connect(result.device),
                      child: const Text('Connect'),
                    ),
                  ),
                ),
              ),
            ],
            if (circuitAvailable) ...[
              const SizedBox(height: 32),
              Text('Wi-Fi setup', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _scanningWifi ? null : _scanWifi,
                icon: _scanningWifi
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find),
                label: Text(_scanningWifi ? 'Scanning Wi-Fi…' : 'Scan Wi-Fi'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Hidden network'),
                subtitle: const Text('Enter the Wi-Fi name manually'),
                value: _hiddenWifi,
                onChanged: (value) => setState(() => _hiddenWifi = value),
              ),
              if (!_hiddenWifi && _wifiNetworks.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(_wifiSsidController.text),
                  initialValue: _wifiNetworks.contains(_wifiSsidController.text) ? _wifiSsidController.text : null,
                  decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Nearby Wi-Fi'),
                  items: _wifiNetworks.map((ssid) => DropdownMenuItem(value: ssid, child: Text(ssid))).toList(),
                  onChanged: (ssid) => setState(() => _wifiSsidController.text = ssid ?? ''),
                ),
                const SizedBox(height: 8),
              ],
              if (_hiddenWifi || _wifiNetworks.isEmpty)
                TextField(
                  controller: _wifiSsidController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Wi-Fi name (SSID)'),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _wifiPasswordController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Wi-Fi password',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _provisioningWifi ? null : _provisionWifi,
                icon: _provisioningWifi
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi),
                label: Text(_provisioningWifi ? 'Sending Wi-Fi…' : 'Set up Wi-Fi'),
              ),
              const SizedBox(height: 12),
              if (connected) OutlinedButton.icon(
                onPressed: _startingRelay ? null : _startPhoneRelay,
                icon: _startingRelay
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.phonelink_ring),
                label: Text(_startingRelay ? 'Starting phone relay…' : 'Enable phone relay'),
              ),
              const SizedBox(height: 32),
              Text('Audio recording', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('Record a voice note to Circuit’s microSD card, then stop or play it.'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _audioBusy || _recordingAudio ? null : _recordAudio,
                      icon: const Icon(Icons.mic),
                      label: const Text('Record'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _audioBusy || !_recordingAudio ? null : _stopRecording,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _audioBusy || _recordingAudio ? null : _playAudio,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Text('E-ink message', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _messageController,
                maxLength: 160,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Type what Circuit should show',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _sending ? null : _sendText,
                icon: _sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                label: Text(_sending ? 'Sending…' : 'Send to Circuit'),
              ),
              if (connected) TextButton(onPressed: () => _device?.disconnect(), child: const Text('Disconnect')),
            ],
          ],
        ),
      ),
    );
  }
}
