/// Domain models for Bruce's saved card dumps ("card backups").
///
/// Bruce stores everything it reads/clones under `/BruceRFID` on the SD card or
/// LittleFS. File extensions determine the format:
///   .rfid    text UID/ATQA/SAK/hex dump   (PN532, RC522/RFID2)
///   .bin     raw MIFARE Classic/Ultralight/Amiibo dump (PN532BLE)
///   .nfc     Flipper-format text          (ST25R3916 module only)
///   .rfidlf  125 kHz low-frequency dump
///   .srix    SRIX / ST25TB                (in /BruceRFID/SRIX/)
///   .rfidscan  TagOMatic scan log         (in /BruceRFID/Scans/)
///
/// Only `.nfc` (ST25R3916) is byte-for-byte Flipper Zero compatible.
library;

import 'package:flutter/foundation.dart';

/// On-disk format of a dump, inferred from its extension.
enum CardDumpFormat {
  bruceRfid, // .rfid  (Bruce text format)
  flipperNfc, // .nfc  (Flipper NFC device format)
  binary, // .bin  (raw)
  lf125, // .rfidlf
  srix, // .srix
  scanLog, // .rfidscan
  unknown;

  static CardDumpFormat fromPath(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'rfid':
        return CardDumpFormat.bruceRfid;
      case 'nfc':
        return CardDumpFormat.flipperNfc;
      case 'bin':
        return CardDumpFormat.binary;
      case 'rfidlf':
        return CardDumpFormat.lf125;
      case 'srix':
        return CardDumpFormat.srix;
      case 'rfidscan':
        return CardDumpFormat.scanLog;
      default:
        return CardDumpFormat.unknown;
    }
  }

  /// True when the payload is binary rather than UTF-8 text.
  bool get isBinary => this == CardDumpFormat.binary;

  /// Whether Bruce can replay/emulate this format via the RFID CLI.
  bool get isReplayable =>
      this == CardDumpFormat.bruceRfid ||
      this == CardDumpFormat.flipperNfc ||
      this == CardDumpFormat.binary ||
      this == CardDumpFormat.srix;

  String get label => switch (this) {
        CardDumpFormat.bruceRfid => 'Bruce RFID',
        CardDumpFormat.flipperNfc => 'Flipper NFC',
        CardDumpFormat.binary => 'Raw dump',
        CardDumpFormat.lf125 => '125 kHz LF',
        CardDumpFormat.srix => 'SRIX',
        CardDumpFormat.scanLog => 'Scan log',
        CardDumpFormat.unknown => 'File',
      };
}

/// A directory entry returned by `ls /BruceRFID` (a saved card, subdir, or file).
@immutable
class CardFile {
  const CardFile({
    required this.name,
    required this.path,
    this.size,
    this.isDir = false,
  });

  final String name;
  final String path;
  final int? size;
  final bool isDir;

  CardDumpFormat get format => CardDumpFormat.fromPath(name);

  @override
  bool operator ==(Object other) => other is CardFile && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A single parsed key/value shown in the dump detail view.
@immutable
class CardField {
  const CardField(this.label, this.value);
  final String label;
  final String value;
}

/// The parsed contents of one dump file.
@immutable
class CardDump {
  const CardDump({
    required this.file,
    required this.format,
    this.uid,
    this.tagType,
    this.atqa,
    this.sak,
    this.fields = const [],
    this.rawText,
    this.rawBytes,
  });

  final CardFile file;
  final CardDumpFormat format;

  /// Tag UID, normalized as space-separated uppercase hex (e.g. "04 A2 3F 91").
  final String? uid;

  /// Human tag type if derivable (e.g. "MIFARE Classic 1K", "NTAG215").
  final String? tagType;
  final String? atqa;
  final String? sak;

  /// All parsed attributes, for the detail table.
  final List<CardField> fields;

  /// Original text (for text formats) shown in a "raw" tab.
  final String? rawText;

  /// Original bytes (for `.bin`).
  final List<int>? rawBytes;

  String get title => tagType ?? file.name;
}

/// Contract the parser layer (`models/dump_parsers.dart`) must satisfy:
///
///   CardDump parseDump(CardFile file, {String? text, List<int>? bytes});
///
/// It receives the dump's content (text for text formats, bytes for `.bin`)
/// already fetched over the transport, and returns a populated [CardDump].
typedef DumpParser = CardDump Function(CardFile file,
    {String? text, List<int>? bytes});
