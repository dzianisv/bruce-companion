/// High-level, transport-agnostic client for Bruce's CLI.
///
/// Works identically over BLE or USB because both are just a byte pipe
/// ([BruceTransport]) into Bruce's `parseSerialCommand` dispatcher. Bruce's CLI
/// has no end-of-response delimiter, so responses are captured by idle timeout:
/// send a command, accumulate bytes, and consider the response complete once no
/// new bytes arrive for [defaultIdle] (bounded by an overall timeout).
///
/// Commands are serialized through a single-slot queue: the BLE serial service
/// exposes one characteristic with a shallow buffer, so overlapping commands
/// would clobber each other.
library;

import 'dart:async';
import 'dart:convert';

import '../models/card_dump.dart';
import '../transport/transport.dart';

/// Centralized CLI strings. Kept in one place so they can be corrected quickly
/// against the live device without touching call sites.
class BruceCommands {
  static const String rfidDir = '/BruceRFID';

  static String ls(String dir) => 'ls $dir';
  static String readFile(String path) => 'read $path';
  static const String info = 'info';

  // RFID replay: load a saved dump, then emulate/write it.
  static String rfidLoad(String path) => 'rfid loadfile $path';
  static const String rfidEmulate = 'rfid emulate t4t';
  static const String rfidWrite = 'rfid write';
  static const String rfidClone = 'rfid clone';
}

class BruceClient {
  BruceClient(this.transport) {
    _incomingSub = transport.incoming.listen(_onBytes);
  }

  final BruceTransport transport;

  static const Duration defaultIdle = Duration(milliseconds: 550);
  static const Duration defaultTimeout = Duration(seconds: 10);

  final StreamController<String> _console = StreamController<String>.broadcast();
  final _decoder = const Utf8Decoder(allowMalformed: true);

  late final StreamSubscription<List<int>> _incomingSub;
  String _lineCarry = '';
  _Capture? _capture;
  Future<void> _queue = Future<void>.value();

  /// Decoded console lines (broadcast). Feeds the raw terminal view.
  Stream<String> get console => _console.stream;

  Stream<BruceLinkState> get linkState => transport.linkState;
  BruceLinkState get state => transport.state;

  // --- connection ---------------------------------------------------------

  /// Connect and swallow the boot/config banner Bruce emits on link-up so the
  /// first real command doesn't capture leftover startup chatter.
  Future<void> connect(BruceDevice device) async {
    await transport.connect(device);
    await _drain();
  }

  Future<void> disconnect() => transport.disconnect();

  /// Wait until the device stops emitting unsolicited bytes (post-connect
  /// banner / config JSON dump), or [window] elapses with nothing arriving.
  Future<void> _drain(
      {Duration idle = const Duration(milliseconds: 700),
      Duration window = const Duration(seconds: 4)}) async {
    final cap = _Capture();
    _capture = cap;
    try {
      await cap.wait(idle, window);
    } finally {
      _capture = null;
    }
  }

  // --- command layer ------------------------------------------------------

  /// Send [cmd] and return everything the device prints back until it goes idle.
  Future<String> sendCommand(
    String cmd, {
    Duration idle = defaultIdle,
    Duration timeout = defaultTimeout,
  }) {
    return _enqueue(() async {
      final cap = _Capture();
      _capture = cap;
      try {
        await transport.write(utf8.encode('$cmd\n'));
        return await cap.wait(idle, timeout);
      } finally {
        _capture = null;
      }
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // --- high-level card ops ------------------------------------------------

  /// List saved dumps under [dir] (defaults to `/BruceRFID`). Best-effort parse
  /// of Bruce's `ls` text output; refine [_parseListing] against the real
  /// device format.
  Future<List<CardFile>> listFiles({String dir = BruceCommands.rfidDir}) async {
    final out = await sendCommand(BruceCommands.ls(dir));
    return _parseListing(out, dir);
  }

  /// Read a dump file's text content (`.rfid`, `.nfc`, etc.).
  Future<String> readFileText(String path) async {
    final out = await sendCommand(BruceCommands.readFile(path),
        timeout: const Duration(seconds: 20));
    return _stripEcho(out, BruceCommands.readFile(path));
  }

  /// Load a saved dump into Bruce, ready to emulate. Returns the device reply.
  Future<String> loadDump(String path) =>
      sendCommand(BruceCommands.rfidLoad(path));

  /// Load then emulate a saved dump (remote "replay this card").
  Future<String> emulateDump(String path) async {
    final loaded = await loadDump(path);
    final emulated = await sendCommand(BruceCommands.rfidEmulate);
    return '$loaded\n$emulated';
  }

  Future<String> deviceInfo() => sendCommand(BruceCommands.info);

  // --- parsing helpers ----------------------------------------------------

  /// Parse Bruce's `ls <dir>` output into [CardFile]s. Bruce prints one entry
  /// per line; directories may be flagged with a trailing `/` or a `<DIR>`
  /// marker, and sizes may follow the name. This is intentionally lenient.
  List<CardFile> _parseListing(String raw, String dir) {
    final files = <CardFile>[];
    final base = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    for (var line in const LineSplitter().convert(raw)) {
      line = line.trim();
      if (line.isEmpty) continue;
      // Skip the command echo and obvious prompts/errors.
      if (line.startsWith('ls ') || line.startsWith('/ #') || line == '>') {
        continue;
      }
      final lower = line.toLowerCase();
      if (lower.startsWith('error') || lower.contains('not found')) continue;

      bool isDir = false;
      var name = line;
      if (name.endsWith('/')) {
        isDir = true;
        name = name.substring(0, name.length - 1);
      }
      // Strip a trailing size token if present ("name.rfid   128").
      final m = RegExp(r'^(.*\S)\s+(\d+)\s*$').firstMatch(name);
      int? size;
      if (m != null) {
        name = m.group(1)!.trim();
        size = int.tryParse(m.group(2)!);
      }
      if (name.contains('<DIR>')) {
        isDir = true;
        name = name.replaceAll('<DIR>', '').trim();
      }
      if (name.isEmpty || name == '.' || name == '..') continue;
      files.add(CardFile(
        name: name,
        path: '$base/$name',
        size: size,
        isDir: isDir,
      ));
    }
    return files;
  }

  /// Remove a leading command echo line from captured output.
  String _stripEcho(String out, String cmd) {
    final lines = const LineSplitter().convert(out);
    if (lines.isNotEmpty && lines.first.trim() == cmd.trim()) {
      return lines.skip(1).join('\n');
    }
    return out;
  }

  // --- byte plumbing ------------------------------------------------------

  void _onBytes(List<int> bytes) {
    final text = _decoder.convert(bytes);
    // Feed active capture (command response / drain).
    _capture?.add(text);
    // Feed console line stream.
    _lineCarry += text;
    int nl;
    while ((nl = _lineCarry.indexOf('\n')) >= 0) {
      final line = _lineCarry.substring(0, nl).replaceAll('\r', '');
      _lineCarry = _lineCarry.substring(nl + 1);
      _console.add(line);
    }
  }

  Future<void> dispose() async {
    await _incomingSub.cancel();
    await _console.close();
    await transport.dispose();
  }
}

/// Accumulates bytes for one command and completes when the stream goes idle
/// for [idle], or after an overall [timeout].
class _Capture {
  final StringBuffer _buf = StringBuffer();
  final Completer<String> _completer = Completer<String>();
  Timer? _idleTimer;
  Timer? _overallTimer;
  Duration _idle = const Duration(milliseconds: 550);

  void add(String text) {
    _buf.write(text);
    _idleTimer?.cancel();
    _idleTimer = Timer(_idle, _finish);
  }

  Future<String> wait(Duration idle, Duration timeout) {
    _idle = idle;
    _idleTimer = Timer(idle, _finish); // completes even if nothing arrives
    _overallTimer = Timer(timeout, _finish);
    return _completer.future;
  }

  void _finish() {
    if (_completer.isCompleted) return;
    _idleTimer?.cancel();
    _overallTimer?.cancel();
    _completer.complete(_buf.toString());
  }
}
