/// USB-C (CDC-ACM) transport for Bruce, built on `usb_serial` 0.5.2.
///
/// Android-only: `usb_serial` wraps `android.hardware.usb`, so this
/// implementation is a no-op source of devices on iOS/desktop (the app falls
/// back to [TransportKind.ble] there). The Cardputer's ESP32-S3 exposes its
/// built-in USB-Serial/JTAG controller as a class-compliant CDC-ACM device
/// (VID 0x303A, PID 0x1001) at 115200 8N1.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import 'transport.dart';

/// Bruce/Cardputer USB identity. Used to prefer the right device when
/// several USB-serial adapters are attached.
const int _cardputerVid = 0x303A;
const int _cardputerPid = 0x1001;

class UsbTransport implements BruceTransport {
  UsbTransport();

  @override
  TransportKind get kind => TransportKind.usb;

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

  /// USB has no real MTU; this just bounds internal fragmentation so a
  /// pathologically large payload doesn't go over the platform channel in
  /// one call. Ordinary Bruce CLI commands never get close to this.
  @override
  int get maxWriteChunk => 4096;

  UsbPort? _port;
  UsbDevice? _connectedUsbDevice;
  StreamSubscription<Uint8List>? _inputSub;
  StreamSubscription<UsbEvent>? _usbEventSub;

  // --- discovery -----------------------------------------------------------

  @override
  Future<void> startDiscovery() async {
    _usbEventSub ??= UsbSerial.usbEventStream?.listen(_onUsbEvent);
    await _refreshDevices();
  }

  @override
  Future<void> stopDiscovery() async {
    await _usbEventSub?.cancel();
    _usbEventSub = null;
  }

  void _onUsbEvent(UsbEvent event) {
    if (event.event == UsbEvent.ACTION_USB_DETACHED) {
      final detached = event.device;
      final connected = _connectedUsbDevice;
      if (detached != null &&
          connected != null &&
          detached.deviceName == connected.deviceName) {
        unawaited(_cleanupPort());
        _setState(BruceLinkState.disconnected);
      }
    }
    unawaited(_refreshDevices());
  }

  Future<void> _refreshDevices() async {
    final all = await UsbSerial.listDevices();
    final matching = all
        .where((d) => d.vid == _cardputerVid && d.pid == _cardputerPid)
        .toList();
    // Prefer the known Cardputer VID/PID; if none matched but exactly one
    // CDC-ish device is attached, surface it anyway so a rebranded/DFU-mode
    // cable still shows up in the picker.
    final selected = matching.isNotEmpty
        ? matching
        : (all.length == 1 ? all : const <UsbDevice>[]);
    if (!_discoveredController.isClosed) {
      _discoveredController.add(selected.map(_toBruceDevice).toList());
    }
  }

  BruceDevice _toBruceDevice(UsbDevice device) {
    final vid = device.vid;
    final pid = device.pid;
    final id = (vid != null && pid != null)
        ? 'usb:${vid.toRadixString(16)}:${pid.toRadixString(16)}'
        : 'usb:device:${device.deviceId}';
    final name = (device.productName != null && device.productName!.isNotEmpty)
        ? device.productName!
        : 'Cardputer (USB)';
    return BruceDevice(
      id: id,
      name: name,
      kind: TransportKind.usb,
      raw: device,
    );
  }

  // --- connection ------------------------------------------------------------

  @override
  Future<void> connect(BruceDevice device) async {
    _setState(BruceLinkState.connecting);
    try {
      final raw = device.raw;
      if (raw is! UsbDevice) {
        throw StateError(
            'UsbTransport.connect requires a BruceDevice produced by this '
            'transport\'s discovery (raw must be a UsbDevice)');
      }

      final port = await raw.create();
      if (port == null) {
        throw StateError('Unable to open a UsbPort for ${device.name}');
      }

      final opened = await port.open();
      if (opened != true) {
        throw StateError('Failed to open USB port for ${device.name}');
      }

      await port.setPortParameters(
        115200,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      // CAUTION: the ESP32-S3 USB-Serial/JTAG controller can drop into a
      // reset/bootloader sequence if DTR/RTS are pulsed (that's how esptool
      // triggers a reset). We set them once to a steady "run mode" state
      // (DTR asserted, RTS deasserted) and never toggle them again.
      await port.setDTR(true);
      await port.setRTS(false);

      _port = port;
      _connectedUsbDevice = raw;
      _inputSub = port.inputStream?.listen(
        (data) {
          if (!_incomingController.isClosed) {
            _incomingController.add(data);
          }
        },
        onError: (Object _, StackTrace _) {
          _setState(BruceLinkState.error);
        },
        onDone: () {
          unawaited(_cleanupPort());
          _setState(BruceLinkState.disconnected);
        },
      );

      // The device reboots and dumps a config JSON banner on open; that
      // settling (~1-2s) and banner-swallowing is handled by the client
      // (BruceClient._drain()), not here. We just start streaming bytes.
      _setState(BruceLinkState.connected);
    } catch (_) {
      await _cleanupPort();
      _setState(BruceLinkState.error);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _cleanupPort();
    _setState(BruceLinkState.disconnected);
  }

  Future<void> _cleanupPort() async {
    await _inputSub?.cancel();
    _inputSub = null;
    await _port?.close();
    _port = null;
    _connectedUsbDevice = null;
  }

  // --- write -----------------------------------------------------------------

  @override
  Future<void> write(List<int> data) async {
    final port = _port;
    if (port == null) {
      throw StateError('UsbTransport.write called while disconnected');
    }
    if (data.isEmpty) return;
    // USB has no small MTU, so this loop only ever runs once in practice;
    // it exists purely to honor the BruceTransport fragmentation contract.
    var offset = 0;
    while (offset < data.length) {
      final end = (offset + maxWriteChunk < data.length)
          ? offset + maxWriteChunk
          : data.length;
      await port.write(Uint8List.fromList(data.sublist(offset, end)));
      offset = end;
    }
  }

  // --- lifecycle ---------------------------------------------------------

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await _cleanupPort();
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
