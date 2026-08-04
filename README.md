# bruce_companion

Phone + CLI companion for an **M5Stack Cardputer** running **[Bruce](https://github.com/pr3y/Bruce)** firmware.

- **Flutter app** (Android/iOS): connect to the Cardputer over **BLE** or **USB-C serial** to control Bruce and browse/read its saved NFC/RFID card dumps.
- **`tools/bruce.py`**: a small, safe serial CLI driver for talking to Bruce from a computer over USB-C.

Both talk to the *same* Bruce command dispatcher (`parseSerialCommand`), so the same commands work over either transport. No firmware changes are needed.

## Hardware

- M5Stack Cardputer ADV (ESP32-S3, native USB-C).
- NFC module: **ST25R3916** (STMicro) on I2C — same chip family as a Flipper Zero. Not a PN532.
- Wire the module to the **side Grove port**: `G1 = SCL`, `G2 = SDA`. Do **not** use the ADV top 14-pin header (it runs on `Wire1`, which Bruce can't use).

## Firmware setup (do this first, or nothing reads)

1. Flash Bruce via the web flasher: <https://bruce.computer/flasher> (Chrome/Edge, over USB-C).
2. On the device: **Main Menu → RFID → Config → RFID Module → "ST25R3916 on I2C"**.
   The default is `M5 RFID2` — the *wrong* chip. Left on default, no card ever reads.
3. To clone: **RFID → Read tag**, tap a card, press **OK** → Clone UID / Write / Emulate / Save file. (There is no "Copy" menu item.)

## `tools/bruce.py` — serial CLI

Drive Bruce from a computer over USB-C. Auto-detects the port, holds DTR/RTS false (won't reset the board), one command per call.

```bash
./tools/bruce.py help
./tools/bruce.py 'i2c'                                 # scan I2C (ST25R3916 answers at 0x50)
./tools/bruce.py 'storage list /BruceRFID'             # list saved card dumps
./tools/bruce.py 'storage read /BruceRFID/<f>.rfid'    # dump a saved card
./tools/bruce.py 'rfid info'                           # last-read tag in memory
```

Requires `pyserial` (`pip install pyserial`). macOS port is `/dev/cu.usbmodem*` (VID/PID `303A:1001`, 115200 8N1).
"device disconnected / multiple access on port" → replug the Cardputer, or `lsof /dev/cu.usbmodem*` and kill the process holding it (only one process can own the port).

## What you can and can't clone

| Card | Clonable with Cardputer + Bruce? |
|---|---|
| 125 kHz fob (EM4100) | No — ST25R3916 is 13.56 MHz only |
| MIFARE Classic 1K, default keys | Yes — full clone to a magic Gen1a card |
| MIFARE Classic 1K, non-default keys | No — Bruce only tries 15 default keys (can't crack) |
| Door checks UID only | Yes — Clone UID, no keys needed |
| MIFARE DESFire / DESFire Light | No — AES-128, not clonable by any device |
| Bank / transit / hotel / WeWork (Kisi) | No — encrypted |

Identify a card first with the **NXP TagInfo** Android app. Phone reads nothing → it's 125 kHz (LF).

## Flutter app layout

```
lib/
  transport/   transport.dart (contract) · ble_transport.dart · usb_transport.dart
  protocol/    bruce_client.dart          command queue + idle-timeout response capture
  models/      card_dump.dart · dump_parsers.dart   (.rfid/.nfc/.bin/.rfidlf/.srix)
  state/       connection_controller.dart
  ui/          home / cards / card detail / console screens
tools/
  bruce.py     serial CLI driver
```

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```
