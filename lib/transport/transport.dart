/// Transport abstraction shared by the BLE and USB-C implementations.
///
/// Bruce (the Cardputer firmware) exposes ONE transport-agnostic command
/// dispatcher (`parseSerialCommand` behind the `serialDevice` interface). The
/// same CLI works whether bytes arrive over the native USB-Serial/JTAG CDC-ACM
/// port or over the "BLE API" GATT serial service. So the app models both as a
/// single [BruceTransport]: a bidirectional byte pipe plus discovery + link
/// state. The high-level protocol lives in `protocol/bruce_client.dart` and is
/// written once against this interface.
library;

import 'dart:async';

/// Which physical link a transport uses.
enum TransportKind { ble, usb }

/// Lifecycle of a transport link.
enum BruceLinkState {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

/// A discoverable Bruce endpoint (a BLE peripheral advertising "Bruc", or an
/// attached USB CDC device with VID/PID 303A:1001).
class BruceDevice {
  const BruceDevice({
    required this.id,
    required this.name,
    required this.kind,
    this.rssi,
    this.raw,
  });

  /// Stable identifier: BLE remote id string, or USB device key.
  final String id;

  /// Human-readable label shown in the picker.
  final String name;

  final TransportKind kind;

  /// BLE signal strength if known.
  final int? rssi;

  /// Underlying platform handle (`BluetoothDevice` / `UsbDevice`). Opaque to
  /// callers; the owning transport casts it back.
  final Object? raw;

  @override
  bool operator ==(Object other) =>
      other is BruceDevice && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);
}

/// Bidirectional byte pipe to a Bruce device, plus discovery and link state.
///
/// Implementations MUST:
///  * Emit every discovered [BruceDevice] batch on [discovered] while scanning.
///  * Surface link transitions on [linkState] (also reflected by [state]).
///  * Deliver all received bytes on [incoming] in order, unframed. Framing /
///    line-splitting / response capture is the client's job.
///  * In [write], internally fragment payloads larger than [maxWriteChunk]
///    (BLE ATT MTU minus 3; USB has no practical cap). Callers pass whole
///    commands and do not chunk themselves.
abstract class BruceTransport {
  TransportKind get kind;

  /// Current link state (mirror of the latest [linkState] event).
  BruceLinkState get state;

  /// Link-state transitions.
  Stream<BruceLinkState> get linkState;

  /// Devices found during discovery (cumulative snapshot per emission).
  Stream<List<BruceDevice>> get discovered;

  /// Raw inbound bytes from the device, in arrival order.
  Stream<List<int>> get incoming;

  /// Largest single [write] payload the link accepts before the transport must
  /// fragment. BLE ~= negotiated MTU - 3; USB returns a large sentinel.
  int get maxWriteChunk;

  Future<void> startDiscovery();
  Future<void> stopDiscovery();

  /// Connect to [device], negotiate MTU (BLE), subscribe to notifications, and
  /// leave the link in [BruceLinkState.connected] ready for [write].
  Future<void> connect(BruceDevice device);

  Future<void> disconnect();

  /// Send raw bytes to the device, fragmenting internally as needed.
  Future<void> write(List<int> data);

  /// Release all resources (streams, subscriptions, platform handles).
  Future<void> dispose();
}
