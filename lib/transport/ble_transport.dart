/// BLE transport for Bruce, built on `flutter_blue_plus` 2.3.x.
///
/// Bruce (running on the M5Cardputer) advertises as "Bruc" and exposes a
/// single-characteristic GATT "serial" service: one characteristic with
/// WRITE + NOTIFY + READ. WRITE sends a command line to Bruce; NOTIFY
/// carries Bruce's output bytes back on that same characteristic. The
/// on-device characteristic buffer is shallow, so writes are fragmented to
/// the negotiated ATT MTU and paced with a small inter-chunk delay.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'transport.dart';

/// Bruce's BLE "serial" GATT service/characteristic. The characteristic is
/// commented "Battery Level" in some firmware sources; that's a copy-paste
/// artifact and can be ignored — it's the command/response channel.
final Guid _bruceServiceUuid = Guid('4371ec0b-3d43-49f9-b731-7c72a4a7bb91');
final Guid _bruceCharacteristicUuid =
    Guid('d555ed97-bf2a-4f46-b3eb-d1fcdd7325e9');

/// Prefix Bruce advertises under (the GATT device name is the longer
/// "Bruce"; the BLE advertisement/platform name is the truncated "Bruc").
const String _bruceNamePrefix = 'bruc';

/// BLE ATT default MTU (23) minus the 3-byte ATT write-request header, used
/// before MTU negotiation completes (or if it never does, e.g. on iOS).
const int _defaultMaxWriteChunk = 20;

class BleTransport implements BruceTransport {
  BleTransport();

  @override
  TransportKind get kind => TransportKind.ble;

  BruceLinkState _state = BruceLinkState.disconnected;
  @override
  BruceLinkState get state => _state;

  final StreamController<BruceLinkState> _linkStateController =
      StreamController<BruceLinkState>.broadcast();
  @override
  Stream<BruceLinkState> get linkState => _linkStateController.stream;

  final StreamController<List<BruceDevice>> _discoveredController =
      StreamController<List<BruceDevice>>.broadcast();
  @override
  Stream<List<BruceDevice>> get discovered => _discoveredController.stream;

  final StreamController<List<int>> _incomingController =
      StreamController<List<int>>.broadcast();
  @override
  Stream<List<int>> get incoming => _incomingController.stream;

  int _maxWriteChunk = _defaultMaxWriteChunk;
  @override
  int get maxWriteChunk => _maxWriteChunk;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  bool _writeWithoutResponse = false;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<int>? _mtuSub;

  // --- permissions -----------------------------------------------------------

  /// Requests the runtime permissions BLE scanning needs.
  ///   - Android 12+ (API 31+): `bluetoothScan` + `bluetoothConnect`.
  ///   - Older Android: `location`.
  /// `permission_handler` auto-resolves whichever pair doesn't apply to the
  /// running OS version to "granted" (gated by the manifest's
  /// `maxSdkVersion` on the legacy permissions), so requesting all three
  /// unconditionally is safe on every Android version. iOS handles its own
  /// consent prompt via CoreBluetooth using the Info.plist usage string.
  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    try {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
      return statuses.values.every((s) => s.isGranted);
    } catch (_) {
      return false;
    }
  }

  // --- discovery ---------------------------------------------------------

  @override
  Future<void> startDiscovery() async {
    if (!await _ensurePermissions()) {
      _setState(BruceLinkState.error);
      return;
    }

    await _scanSub?.cancel();
    _setState(BruceLinkState.scanning);

    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) {
        final matches = <BruceDevice>[];
        for (final r in results) {
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          if (!name.toLowerCase().startsWith(_bruceNamePrefix)) continue;
          matches.add(BruceDevice(
            id: r.device.remoteId.str,
            name: name,
            kind: TransportKind.ble,
            rssi: r.rssi,
            raw: r.device,
          ));
        }
        if (!_discoveredController.isClosed) {
          _discoveredController.add(matches);
        }
      },
      onError: (Object _, StackTrace _) {
        _setState(BruceLinkState.error);
      },
    );

    try {
      await FlutterBluePlus.startScan(androidUsesFineLocation: false);
    } catch (_) {
      await stopDiscovery();
      _setState(BruceLinkState.error);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {
      // best-effort
    }
    if (_state == BruceLinkState.scanning) {
      _setState(BruceLinkState.disconnected);
    }
  }

  // --- connection ----------------------------------------------------------

  @override
  Future<void> connect(BruceDevice device) async {
    final raw = device.raw;
    if (raw is! BluetoothDevice) {
      throw StateError(
          'BleTransport.connect requires a BruceDevice produced by this '
          'transport\'s discovery (raw must be a BluetoothDevice)');
    }

    await stopDiscovery();
    _setState(BruceLinkState.connecting);
    _maxWriteChunk = _defaultMaxWriteChunk;

    try {
      if (raw.isDisconnected) {
        // mtu:null so we control MTU negotiation ourselves below, at a size
        // (247) chosen for Bruce's shallow characteristic buffer rather than
        // the library's default request (512).
        await raw.connect(license: License.nonprofit, mtu: null);
      }
      _device = raw;

      await _connSub?.cancel();
      _connSub = raw.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _setState(BruceLinkState.disconnected);
        }
      });

      await _mtuSub?.cancel();
      _mtuSub = raw.mtu.listen((mtu) {
        final chunk = mtu - 3;
        _maxWriteChunk = chunk > 0 ? chunk : _defaultMaxWriteChunk;
      });

      if (Platform.isAndroid) {
        try {
          await raw.requestMtu(247);
        } catch (_) {
          // Ignore MTU negotiation failures; keep the default chunk size.
        }
      }

      final services = await raw.discoverServices();
      BluetoothService? service;
      for (final s in services) {
        if (s.uuid == _bruceServiceUuid) {
          service = s;
          break;
        }
      }
      if (service == null) {
        throw StateError(
            'Bruce BLE serial service not found on ${device.name}');
      }

      BluetoothCharacteristic? characteristic;
      for (final c in service.characteristics) {
        if (c.uuid == _bruceCharacteristicUuid) {
          characteristic = c;
          break;
        }
      }
      if (characteristic == null) {
        throw StateError(
            'Bruce BLE serial characteristic not found on ${device.name}');
      }
      _characteristic = characteristic;
      _writeWithoutResponse = characteristic.properties.writeWithoutResponse;

      await _notifySub?.cancel();
      _notifySub = characteristic.onValueReceived.listen(
        (bytes) {
          if (!_incomingController.isClosed) {
            _incomingController.add(bytes);
          }
        },
        onError: (Object _, StackTrace _) {
          _setState(BruceLinkState.error);
        },
      );
      await characteristic.setNotifyValue(true);

      _setState(BruceLinkState.connected);
    } catch (_) {
      await _cleanupConnection();
      _setState(BruceLinkState.error);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _cleanupConnection();
    _setState(BruceLinkState.disconnected);
  }

  Future<void> _cleanupConnection() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _mtuSub?.cancel();
    _mtuSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _characteristic = null;
    _writeWithoutResponse = false;
    _maxWriteChunk = _defaultMaxWriteChunk;
    final device = _device;
    _device = null;
    if (device != null && device.isConnected) {
      try {
        await device.disconnect();
      } catch (_) {
        // best-effort
      }
    }
  }

  // --- write -----------------------------------------------------------------

  @override
  Future<void> write(List<int> data) async {
    final characteristic = _characteristic;
    if (characteristic == null) {
      throw StateError('BleTransport.write called while disconnected');
    }
    if (data.isEmpty) return;

    final chunkSize =
        _maxWriteChunk > 0 ? _maxWriteChunk : _defaultMaxWriteChunk;
    var offset = 0;
    while (offset < data.length) {
      final end = (offset + chunkSize < data.length)
          ? offset + chunkSize
          : data.length;
      await characteristic.write(
        data.sublist(offset, end),
        withoutResponse: _writeWithoutResponse,
      );
      offset = end;
      // Small inter-chunk pacing delay: Bruce's characteristic buffer is
      // shallow, so back-to-back writes without a breather can overrun it.
      if (offset < data.length) {
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    }
  }

  // --- lifecycle ---------------------------------------------------------

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await _cleanupConnection();
    _setState(BruceLinkState.disconnected);
    await _linkStateController.close();
    await _discoveredController.close();
    await _incomingController.close();
  }

  void _setState(BruceLinkState next) {
    _state = next;
    if (!_linkStateController.isClosed) {
      _linkStateController.add(next);
    }
  }
}
