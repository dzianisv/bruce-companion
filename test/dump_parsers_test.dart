import 'package:flutter_test/flutter_test.dart';

import 'package:bruce_companion/models/card_dump.dart';
import 'package:bruce_companion/models/dump_parsers.dart';

/// True if [fields] contains an entry with the given [label] (case-sensitive)
/// and, when [value] is provided, that exact value too.
bool _hasField(List<CardField> fields, String label, [String? value]) {
  return fields.any(
    (f) => f.label == label && (value == null || f.value == value),
  );
}

void main() {
  group('parseDump — flipperNfc (.nfc)', () {
    const sample = '''
Filetype: Flipper NFC device
Version: 4
Device type: Mifare Classic
UID: 04 A2 3F 91 22 5C 80
ATQA: 00 44
SAK: 00
Mifare Classic type: 1K
Block 0: 04 A2 3F 91 22 5C 80 88 04 00 00 00 00 00 00 00
Block 1: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
''';

    test('parses UID/tagType/ATQA/SAK and keeps fields + rawText', () {
      final file = CardFile(name: 'card.nfc', path: '/BruceRFID/card.nfc');
      final dump = parseDump(file, text: sample);

      expect(dump.format, CardDumpFormat.flipperNfc);
      expect(dump.uid, '04 A2 3F 91 22 5C 80');
      expect(dump.tagType, 'Mifare Classic 1K');
      expect(dump.atqa, '00 44');
      expect(dump.sak, '00');
      expect(dump.fields, isNotEmpty);
      expect(_hasField(dump.fields, 'Filetype', 'Flipper NFC device'), isTrue);
      expect(_hasField(dump.fields, 'UID', '04 A2 3F 91 22 5C 80'), isTrue);
      expect(_hasField(dump.fields, 'Block 0'), isTrue);
      expect(dump.rawText, sample);
      expect(dump.rawBytes, isNull);
      expect(dump.file, file);
    });

    test('falls back to bare device type when no classic-type line', () {
      const noClassicType = '''
Filetype: Flipper NFC device
Device type: NTAG215
UID: 04:11:22:33:44:55:66
ATQA: 00:44
SAK: 00
''';
      final file = CardFile(name: 'ntag.nfc', path: '/BruceRFID/ntag.nfc');
      final dump = parseDump(file, text: noClassicType);

      expect(dump.tagType, 'NTAG215');
      expect(dump.uid, '04 11 22 33 44 55 66');
      expect(dump.atqa, '00 44');
    });
  });

  group('parseDump — bruceRfid (.rfid)', () {
    test('parses standard Device type/UID/SAK/ATQA block', () {
      const sample = '''
Device type: Mifare Classic 1K
UID: 3F 91 22 5C
SAK: 08
ATQA: 00 04
Data: 3F 91 22 5C 88 04 00 00 00 00 00 00 00 00 00 00
''';
      final file = CardFile(name: 'dump.rfid', path: '/BruceRFID/dump.rfid');
      final dump = parseDump(file, text: sample);

      expect(dump.format, CardDumpFormat.bruceRfid);
      expect(dump.uid, '3F 91 22 5C');
      expect(dump.tagType, 'Mifare Classic 1K');
      expect(dump.sak, '08');
      expect(dump.atqa, '00 04');
      expect(_hasField(dump.fields, 'Data'), isTrue);
      expect(dump.rawText, sample);
    });

    test('is lenient about key casing/spelling and contiguous hex', () {
      const sample = '''
PICC type: NTAG213
uid: 3f91225c
sak: 08
atqa: 0004
Bytes: 16
''';
      final file = CardFile(name: 'dump2.rfid', path: '/BruceRFID/dump2.rfid');
      final dump = parseDump(file, text: sample);

      expect(dump.uid, '3F 91 22 5C');
      expect(dump.tagType, 'NTAG213');
      expect(dump.sak, '08');
      expect(dump.atqa, '00 04');
      expect(_hasField(dump.fields, 'Bytes', '16'), isTrue);
    });
  });

  group('parseDump — binary (.bin)', () {
    test('MIFARE Classic 1K sized dump (1024 bytes)', () {
      final bytes = List<int>.generate(1024, (i) => i % 256);
      final file = CardFile(name: 'classic1k.bin', path: '/BruceRFID/classic1k.bin');
      final dump = parseDump(file, bytes: bytes);

      expect(dump.format, CardDumpFormat.binary);
      expect(dump.tagType, 'MIFARE Classic 1K');
      // Block-0 UID is the first 4 bytes: 0x00 0x01 0x02 0x03.
      expect(dump.uid, '00 01 02 03');
      expect(dump.atqa, isNull);
      expect(dump.sak, isNull);
      expect(_hasField(dump.fields, 'size', '1024'), isTrue);
      expect(
        dump.fields.firstWhere((f) => f.label == 'preview').value.split(' '),
        hasLength(32),
      );
      expect(dump.rawBytes, bytes);
      expect(dump.rawText, isNull);
    });

    test('Ultralight/NTAG sized dump (540 bytes) uses 7-byte UID layout', () {
      final bytes = List<int>.generate(540, (i) => i % 256);
      final file = CardFile(name: 'ultralight.bin', path: '/BruceRFID/ultralight.bin');
      final dump = parseDump(file, bytes: bytes);

      expect(dump.tagType, 'MIFARE Ultralight/NTAG');
      // bytes 0-2 + bytes 4-7 (byte 3 is the BCC and is skipped).
      expect(dump.uid, '00 01 02 04 05 06 07');
      expect(_hasField(dump.fields, 'size', '540'), isTrue);
    });

    test('NTAG215 sized dump (572 bytes) reports NTAG215 tag type', () {
      final bytes = List<int>.generate(572, (i) => (i * 3) % 256);
      final file = CardFile(name: 'ntag215.bin', path: '/BruceRFID/ntag215.bin');
      final dump = parseDump(file, bytes: bytes);

      expect(dump.tagType, 'NTAG215');
      expect(dump.uid, isNotNull);
      expect(dump.uid!.split(' '), hasLength(7));
    });

    test('unrecognized size falls back to "Raw dump (n bytes)"', () {
      final bytes = List<int>.generate(100, (i) => i);
      final file = CardFile(name: 'weird.bin', path: '/BruceRFID/weird.bin');
      final dump = parseDump(file, bytes: bytes);

      expect(dump.tagType, 'Raw dump (100 bytes)');
      expect(dump.uid, '00 01 02 03');
    });
  });

  group('parseDump — generic lenient text (lf125/srix/scanLog/unknown)', () {
    test('lf125 (.rfidlf) pulls an id-looking field opportunistically', () {
      const sample = '''
Card type: EM4100
Tag ID: 1A2B3C4D5E
Frequency: 125kHz
''';
      final file = CardFile(name: 'lf.rfidlf', path: '/BruceRFID/lf.rfidlf');
      final dump = parseDump(file, text: sample);

      expect(dump.format, CardDumpFormat.lf125);
      expect(dump.uid, '1A 2B 3C 4D 5E');
      expect(_hasField(dump.fields, 'Card type', 'EM4100'), isTrue);
      expect(_hasField(dump.fields, 'Frequency', '125kHz'), isTrue);
      expect(dump.rawText, sample);
    });

    test('srix (.srix) generic parse', () {
      const sample = '''
Chip: SRIX4K
UID: E0 04 01 02 03 04 05 06
Memory: 128 blocks
''';
      final file = CardFile(name: 'card.srix', path: '/BruceRFID/SRIX/card.srix');
      final dump = parseDump(file, text: sample);

      expect(dump.format, CardDumpFormat.srix);
      expect(dump.uid, 'E0 04 01 02 03 04 05 06');
      expect(_hasField(dump.fields, 'Chip', 'SRIX4K'), isTrue);
    });

    test('scanLog (.rfidscan) generic parse', () {
      const sample = '''
Scan #1: Mifare Classic
Tag UID: AABBCCDD
Result: OK
''';
      final file = CardFile(name: 'log.rfidscan', path: '/BruceRFID/Scans/log.rfidscan');
      final dump = parseDump(file, text: sample);

      expect(dump.format, CardDumpFormat.scanLog);
      expect(dump.uid, 'AA BB CC DD');
      expect(_hasField(dump.fields, 'Result', 'OK'), isTrue);
    });

    test('unknown extension still parses generically without throwing', () {
      const sample = '''
Note: some custom exporter
Identifier: 1122334455
''';
      final file = CardFile(name: 'mystery.xyz', path: '/BruceRFID/mystery.xyz');
      final dump = parseDump(file, text: sample);

      expect(dump.format, CardDumpFormat.unknown);
      expect(dump.uid, '11 22 33 44 55');
      expect(_hasField(dump.fields, 'Note', 'some custom exporter'), isTrue);
    });
  });

  group('parseDump — malformed / missing input never throws', () {
    test('empty text (bruceRfid) yields empty fields and null attributes', () {
      final file = CardFile(name: 'empty.rfid', path: '/BruceRFID/empty.rfid');
      final dump = parseDump(file, text: '');

      expect(() => dump, returnsNormally);
      expect(dump.uid, isNull);
      expect(dump.tagType, isNull);
      expect(dump.atqa, isNull);
      expect(dump.sak, isNull);
      expect(dump.fields, isEmpty);
      expect(dump.rawText, '');
    });

    test('null text (flipperNfc, text omitted) treated as empty string', () {
      final file = CardFile(name: 'no_text.nfc', path: '/BruceRFID/no_text.nfc');
      final dump = parseDump(file);

      expect(dump.format, CardDumpFormat.flipperNfc);
      expect(dump.uid, isNull);
      expect(dump.fields, isEmpty);
      expect(dump.rawText, '');
    });

    test('garbage lines with no colons produce no fields but do not throw', () {
      const garbage = 'asdkjasdlkj\nfoobar whatever\n---not-a-kv-line---';
      final file = CardFile(name: 'garbage.rfidlf', path: '/BruceRFID/garbage.rfidlf');
      late CardDump dump;
      expect(() => dump = parseDump(file, text: garbage), returnsNormally);

      expect(dump.fields, isEmpty);
      expect(dump.uid, isNull);
      expect(dump.rawText, garbage);
    });

    test('empty bytes list (binary) yields zero-size dump, no crash', () {
      final file = CardFile(name: 'empty.bin', path: '/BruceRFID/empty.bin');
      final dump = parseDump(file, bytes: const <int>[]);

      expect(dump.format, CardDumpFormat.binary);
      expect(dump.uid, isNull);
      expect(dump.tagType, 'Raw dump (0 bytes)');
      expect(_hasField(dump.fields, 'size', '0'), isTrue);
      expect(dump.rawBytes, isEmpty);
    });

    test('null bytes (binary, bytes omitted) treated as empty list', () {
      final file = CardFile(name: 'no_bytes.bin', path: '/BruceRFID/no_bytes.bin');
      final dump = parseDump(file);

      expect(dump.format, CardDumpFormat.binary);
      expect(dump.rawBytes, isEmpty);
      expect(dump.uid, isNull);
    });

    test('bytes shorter than 4 do not crash and yield null UID', () {
      final file = CardFile(name: 'short.bin', path: '/BruceRFID/short.bin');
      final dump = parseDump(file, bytes: const [0x01, 0x02]);

      expect(dump.uid, isNull);
      expect(dump.tagType, 'Raw dump (2 bytes)');
      expect(_hasField(dump.fields, 'size', '2'), isTrue);
      expect(dump.rawBytes, const [0x01, 0x02]);
    });
  });
}
