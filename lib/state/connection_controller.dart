/// App-wide connection state for the Bruce Companion UI.
///
/// Owns the active [BruceTransport] + [BruceClient] pair (both null until a
/// device is connected), drives discovery/connect/disconnect, mirrors the
/// device console into a capped rolling log, and exposes the card-backup
/// list + read/replay operations used by the UI layer.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/card_dump.dart';
import '../models/dump_parsers.dart';
import '../protocol/bruce_client.dart';
import '../transport/ble_transport.dart';
import '../transport/transport.dart';
import '../transport/usb_transport.dart';

class ConnectionController extends ChangeNotifier {
  static const int _consoleCap = 500;

  BruceTransport? _transport;
  BruceClient? _client;

  /// Last transport kind the user picked, so the UI can restore the toggle.
  TransportKind? lastKind;

  BruceLinkState _linkState = BruceLinkState.disconnected;
  BruceLinkState get linkState => _linkState;

  List<BruceDevice> _discovered = const [];
  List<BruceDevice> get discovered => _discovered;

  BruceDevice? current;

  final List<String> _consoleLog = [];
  List<String> get consoleLog => List.unmodifiable(_consoleLog);

  List<CardFile> _cards = const [];
  List<CardFile> get cards => _cards;

  bool busy = false;
  String? error;

  bool get isConnected =>
      _client != null && _linkState == BruceLinkState.connected;

  StreamSubscription<List<BruceDevice>>? _discoveredSub;
  StreamSubscription<BruceLinkState>? _linkSub;
  StreamSubscription<String>? _consoleSub;

  // --- discovery -----------------------------------------------------------

  /// Tear down any existing link, spin up a fresh transport of [kind], and
  /// start scanning for nearby/attached Bruce devices.
  Future<void> startScan(TransportKind kind) async {
    await _teardown();

    lastKind = kind;
    error = null;
    _discovered = const [];
    busy = true;
    notifyListeners();

    final transport = kind == TransportKind.ble ? BleTransport() : UsbTransport();
    _transport = transport;

    _linkSub = transport.linkState.listen(
      (s) {
        _linkState = s;
        notifyListeners();
      },
      onError: (Object e) {
        error = e.toString();
        _linkState = BruceLinkState.error;
        notifyListeners();
      },
    );

    _discoveredSub = transport.discovered.listen((devices) {
      _discovered = devices;
      notifyListeners();
    });

    try {
      await transport.startDiscovery();
    } catch (e) {
      error = e.toString();
      _linkState = BruceLinkState.error;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    try {
      await _transport?.stopDiscovery();
    } catch (_) {
      // Best-effort; nothing the UI needs to react to.
    }
  }

  // --- connection ------------------------------------------------------------

  Future<void> connect(BruceDevice device) async {
    final transport = _transport;
    if (transport == null) {
      error = 'No transport active — scan first';
      notifyListeners();
      return;
    }

    busy = true;
    error = null;
    notifyListeners();

    try {
      await transport.stopDiscovery();
    } catch (_) {
      // Ignore: some transports no-op or throw if not currently scanning.
    }

    try {
      final client = BruceClient(transport);
      await client.connect(device);
      _client = client;
      current = device;
      _consoleSub = client.console.listen(_onConsoleLine);
    } catch (e) {
      error = e.toString();
      _linkState = BruceLinkState.error;
      _client = null;
      current = null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    current = null;
    _cards = const [];
    _linkState = BruceLinkState.disconnected;
    notifyListeners();
  }

  Future<void> _teardown() async {
    await _consoleSub?.cancel();
    _consoleSub = null;
    await _discoveredSub?.cancel();
    _discoveredSub = null;
    await _linkSub?.cancel();
    _linkSub = null;

    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.dispose();
      } catch (_) {
        // Transport is going away regardless.
      }
    }

    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.dispose();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  void _onConsoleLine(String line) {
    _consoleLog.add(line);
    if (_consoleLog.length > _consoleCap) {
      _consoleLog.removeRange(0, _consoleLog.length - _consoleCap);
    }
    notifyListeners();
  }

  // --- card backups ----------------------------------------------------------

  /// Refresh the top-level `/BruceRFID` listing into [cards].
  Future<void> refreshCards({String dir = BruceCommands.rfidDir}) async {
    final client = _client;
    if (client == null) {
      error = 'Not connected';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      _cards = await client.listFiles(dir: dir);
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// List an arbitrary directory without touching the cached top-level
  /// [cards] snapshot. Used when the user drills into a subdirectory.
  Future<List<CardFile>> listDir(String dir) {
    final client = _client;
    if (client == null) {
      throw StateError('Not connected');
    }
    return client.listFiles(dir: dir);
  }

  /// Fetch and parse a dump. Bruce's CLI only exposes text reads
  /// ([BruceClient.readFileText]) — there is no raw-byte read command, so
  /// binary (`.bin`) dumps are parsed from the same best-effort text capture
  /// rather than exact bytes.
  Future<CardDump?> readDump(CardFile file) async {
    final client = _client;
    if (client == null) {
      error = 'Not connected';
      notifyListeners();
      return null;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final text = await client.readFileText(file.path);
      return parseDump(file, text: text);
    } catch (e) {
      error = e.toString();
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Load then emulate/transmit a saved dump. Returns the device's reply.
  Future<String?> replay(CardFile file) async {
    final client = _client;
    if (client == null) {
      error = 'Not connected';
      notifyListeners();
      return null;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      return await client.emulateDump(file.path);
    } catch (e) {
      error = e.toString();
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Send a raw CLI command (from the console screen).
  Future<String?> sendRaw(String cmd) async {
    final client = _client;
    if (client == null) {
      error = 'Not connected';
      notifyListeners();
      return null;
    }
    try {
      return await client.sendCommand(cmd);
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return null;
    }
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
