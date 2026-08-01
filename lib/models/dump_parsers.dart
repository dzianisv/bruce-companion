/// Parsers that turn a raw Bruce card-dump payload (text or bytes) into a
/// structured [CardDump], per the [DumpParser] contract declared at the
/// bottom of `card_dump.dart`.
///
/// Every parser here is defensive: malformed, empty, or null input must
/// never throw. Worst case we return a [CardDump] with empty/null fields.
library;

import 'card_dump.dart';

/// Entry point matching the [DumpParser] typedef. Dispatches to a
/// format-specific sub-parser based on [CardFile.format].
CardDump parseDump(CardFile file, {String? text, List<int>? bytes}) {
  return switch (file.format) {
    CardDumpFormat.flipperNfc => _parseFlipperNfc(file, text ?? ''),
    CardDumpFormat.bruceRfid => _parseBruceRfid(file, text ?? ''),
    CardDumpFormat.binary => _parseBinary(file, bytes ?? const <int>[]),
    CardDumpFormat.lf125 ||
    CardDumpFormat.srix ||
    CardDumpFormat.scanLog ||
    CardDumpFormat.unknown =>
      _parseGenericText(file, text ?? ''),
  };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Normalizes a UID/ATQA/SAK-like hex string to space-separated UPPERCASE
/// hex byte pairs.
///
/// Accepts contiguous ("04A23F91"), colon-separated ("04:A2:3F:91"), or
/// already space-separated ("04 A2 3F 91") input: every non-hex-digit
/// character is stripped, then the remaining digits are re-grouped two at a
/// time. Returns an empty string (never throws) when [raw] contains no hex
/// digits at all, e.g. for garbage or empty input.
String _normalizeHexBytes(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (cleaned.isEmpty) return '';
  final buffer = StringBuffer();
  for (var i = 0; i < cleaned.length; i += 2) {
    final end = (i + 2 <= cleaned.length) ? i + 2 : cleaned.length;
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(cleaned.substring(i, end).toUpperCase());
  }
  return buffer.toString();
}

/// Splits [text] into non-empty, trimmed lines. Never throws on null/empty
/// input (callers pass `text ?? ''`, which just yields no lines).
Iterable<String> _lines(String text) =>
    text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);

/// Splits a `Label: value` line on the FIRST ':' only (values may contain
/// further colons, e.g. hex dumps or timestamps). Returns null if there is
/// no ':' or the label side is empty.
(String, String)? _splitKeyValue(String line) {
  final idx = line.indexOf(':');
  if (idx < 0) return null;
  final label = line.substring(0, idx).trim();
  if (label.isEmpty) return null;
  final value = line.substring(idx + 1).trim();
  return (label, value);
}

// ---------------------------------------------------------------------------
// A. Flipper NFC device format (.nfc)
// ---------------------------------------------------------------------------

CardDump _parseFlipperNfc(CardFile file, String text) {
  final fields = <CardField>[];
  String? uid;
  String? deviceType;
  String? classicType;
  String? atqa;
  String? sak;

  for (final line in _lines(text)) {
    final kv = _splitKeyValue(line);
    if (kv == null) continue;
    final (label, value) = kv;
    fields.add(CardField(label, value));

    try {
      switch (label.toLowerCase()) {
        case 'uid':
          uid = _normalizeHexBytes(value);
          break;
        case 'device type':
          deviceType = value;
          break;
        case 'mifare classic type':
          classicType = value;
          break;
        case 'atqa':
          atqa = _normalizeHexBytes(value);
          break;
        case 'sak':
          sak = _normalizeHexBytes(value);
          break;
      }
    } catch (_) {
      // A single malformed line must never abort the whole parse.
    }
  }

  final tagType = (deviceType != null && classicType != null && classicType.isNotEmpty)
      ? '$deviceType $classicType'
      : deviceType;

  return CardDump(
    file: file,
    format: CardDumpFormat.flipperNfc,
    uid: (uid == null || uid.isEmpty) ? null : uid,
    tagType: tagType,
    atqa: (atqa == null || atqa.isEmpty) ? null : atqa,
    sak: (sak == null || sak.isEmpty) ? null : sak,
    fields: fields,
    rawText: text,
  );
}

// ---------------------------------------------------------------------------
// B. Bruce RFID text format (.rfid)
// ---------------------------------------------------------------------------

CardDump _parseBruceRfid(CardFile file, String text) {
  final fields = <CardField>[];
  String? uid;
  String? tagType;
  String? atqa;
  String? sak;

  for (final line in _lines(text)) {
    final kv = _splitKeyValue(line);
    if (kv == null) continue;
    final (label, value) = kv;
    fields.add(CardField(label, value));

    try {
      switch (label.toLowerCase()) {
        case 'uid':
          uid ??= _normalizeHexBytes(value);
          break;
        case 'sak':
          sak ??= _normalizeHexBytes(value);
          break;
        case 'atqa':
          atqa ??= _normalizeHexBytes(value);
          break;
        case 'device type':
        case 'picc type':
        case 'tag type':
          // First match wins, whichever of the three synonymous keys shows
          // up first in the file.
          tagType ??= value;
          break;
      }
    } catch (_) {
      // A single malformed line must never abort the whole parse.
    }
  }

  return CardDump(
    file: file,
    format: CardDumpFormat.bruceRfid,
    uid: (uid == null || uid.isEmpty) ? null : uid,
    tagType: tagType,
    atqa: (atqa == null || atqa.isEmpty) ? null : atqa,
    sak: (sak == null || sak.isEmpty) ? null : sak,
    fields: fields,
    rawText: text,
  );
}

// ---------------------------------------------------------------------------
// C. Raw binary dump (.bin) — MIFARE Classic/Ultralight/Amiibo
// ---------------------------------------------------------------------------

/// Dump sizes (in bytes) that plausibly belong to an Ultralight/NTAG-family
/// tag rather than a MIFARE Classic sector dump. This is a heuristic, not a
/// real format detector: those chips don't have one fixed dump size across
/// tools, so we only recognize the sizes Bruce/Flipper commonly produce
/// (NTAG213 ≈512B user dumps, plain Ultralight 540B raw page dumps,
/// NTAG215 572B, NTAG216-ish 924B). Anything else falls back to treating
/// the first 4 bytes as a MIFARE Classic block-0 UID.
const _ultralightLikeSizes = {512, 540, 572, 924};

String _binaryTagType(int length) {
  switch (length) {
    case 320:
      return 'MIFARE Mini';
    case 1024:
      return 'MIFARE Classic 1K';
    case 2048:
      return 'MIFARE Classic 2K';
    case 4096:
      return 'MIFARE Classic 4K';
    case 540:
      return 'MIFARE Ultralight/NTAG';
    case 572:
      return 'NTAG215';
    default:
      return 'Raw dump ($length bytes)';
  }
}

String _hexPreview(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final n = bytes.length < 32 ? bytes.length : 32;
  return bytes
      .sublist(0, n)
      .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

/// Best-effort UID extraction from a raw dump. Never throws: any indexing
/// problem just results in a null UID.
String? _binaryUid(List<int> bytes) {
  try {
    if (_ultralightLikeSizes.contains(bytes.length) && bytes.length >= 8) {
      // Ultralight/NTAG 7-byte UID layout: bytes 0-2 are UID0-2, byte 3 is
      // the BCC0 check byte (skipped), bytes 4-6 are UID3-5, byte 7 is the
      // internal/BCC1 byte historically also treated as UID6 by many
      // readers. We surface bytes 0-2 + 4-7 (7 bytes total) as the "first 7
      // significant UID bytes", matching how Flipper/Bruce display it.
      final uidBytes = [
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
      ];
      return uidBytes
          .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
    }
    if (bytes.length >= 4) {
      // MIFARE Classic block 0 starts with the 4-byte UID.
      return bytes
          .sublist(0, 4)
          .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
    }
  } catch (_) {
    // Fall through to null below.
  }
  return null;
}

CardDump _parseBinary(CardFile file, List<int> bytes) {
  final fields = <CardField>[
    CardField('size', '${bytes.length}'),
  ];
  final preview = _hexPreview(bytes);
  if (preview.isNotEmpty) {
    fields.add(CardField('preview', preview));
  }

  return CardDump(
    file: file,
    format: CardDumpFormat.binary,
    uid: _binaryUid(bytes),
    tagType: _binaryTagType(bytes.length),
    // Binary dumps don't carry ATQA/SAK directly (those are protocol-layer
    // values from the anticollision exchange, not part of the memory dump).
    atqa: null,
    sak: null,
    fields: fields,
    rawBytes: bytes,
  );
}

// ---------------------------------------------------------------------------
// D. Generic lenient text parse — lf125 (.rfidlf), srix (.srix),
//    scanLog (.rfidscan), and unknown formats.
// ---------------------------------------------------------------------------

CardDump _parseGenericText(CardFile file, String text) {
  final fields = <CardField>[];
  String? uid;

  for (final line in _lines(text)) {
    final kv = _splitKeyValue(line);
    if (kv == null) continue;
    final (label, value) = kv;
    fields.add(CardField(label, value));

    if (uid != null) continue;
    final lower = label.toLowerCase();
    if (lower.contains('uid') || lower.contains('id') || lower.contains('tag')) {
      try {
        final normalized = _normalizeHexBytes(value);
        if (normalized.isNotEmpty) {
          uid = normalized;
        }
      } catch (_) {
        // Ignore and keep scanning other lines.
      }
    }
  }

  return CardDump(
    file: file,
    format: file.format,
    uid: uid,
    fields: fields,
    rawText: text,
  );
}
