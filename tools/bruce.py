#!/usr/bin/env python3
"""Drive Bruce firmware (M5Cardputer) over USB serial. One command per call.

Usage:
    ./bruce.py 'storage list /'
    ./bruce.py 'storage read /BruceRFID/047E8A5A276580.rfid'
    ./bruce.py 'rfid info'
    ./bruce.py help

Safe by design: auto-detects the port, forces DTR=RTS=False (never toggles them,
so it can't reset the ESP32-S3 or drop it to the bootloader), drains Bruce's
boot/config preamble, then sends exactly one command and prints the reply.
"""
import glob
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    sys.exit("pyserial missing: pip install pyserial")

BAUD = 115200


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("No /dev/cu.usbmodem* found — replug the Cardputer.")
    return ports[0]


def read_for(ser, seconds):
    """Read whatever arrives within `seconds`, tolerating a dropped device."""
    end = time.time() + seconds
    buf = bytearray()
    while time.time() < end:
        try:
            n = ser.in_waiting
        except OSError:
            break
        if n:
            try:
                buf += ser.read(n)
            except serial.SerialException:
                break  # device went away mid-read
            end = time.time() + 0.4  # extend while data still flowing
        else:
            time.sleep(0.05)
    return bytes(buf)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = " ".join(sys.argv[1:])
    port = find_port()

    ser = serial.Serial()
    ser.port = port
    ser.baudrate = BAUD
    ser.dtr = False   # set BEFORE open; never change after
    ser.rts = False
    ser.timeout = 0.3
    try:
        ser.open()
    except serial.SerialException as e:
        sys.exit(f"Can't open {port}: {e}\n"
                 f"  - another process may hold it (lsof {port})\n"
                 f"  - or replug the device")

    print(f"=== {port} @ {BAUD} 8N1, dtr=rts=False ===")
    read_for(ser, 1.0)          # drain any boot/config preamble already buffered
    ser.reset_input_buffer()
    ser.write((cmd + "\r\n").encode())
    ser.flush()
    out = read_for(ser, 3.0)
    sys.stdout.write(out.decode(errors="replace"))
    ser.close()


if __name__ == "__main__":
    main()
