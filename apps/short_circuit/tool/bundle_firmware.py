#!/usr/bin/env python3
"""Copies the firmware this app is built with into assets/firmware/circuit.bin, for "Update Circuit".

  tool/bundle_firmware.py [path/to/circuit_ble_display.bin]

Without a path it uses the release build next to the app (firmware/CircuitBleDisplay/build). Run it before
`flutter build`. The .bin is never committed (it is in .gitignore); CI builds the firmware and runs this too.
The file is checked the way the app and the board check it: an ESP-IDF app image of Circuit, 256 KB to 3.1 MB.
"""
import shutil
import struct
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
DEFAULT = APP.parents[1] / "firmware" / "CircuitBleDisplay" / "build" / "circuit_ble_display.bin"


def main() -> int:
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not source.is_file():
        print(f"No firmware at {source}. Build it first (idf.py build), or pass the path.")
        return 1
    data = source.read_bytes()
    problems = []
    if not 256 * 1024 <= len(data) <= 0x320000 - 0x1000:
        problems.append(f"size {len(data)} bytes is not an app image")
    if data[:1] != b"\xe9":
        problems.append("it does not start with the ESP image marker")
    elif struct.unpack_from("<I", data, 32)[0] != 0xABCD5432:
        problems.append("it has no app description")
    elif data[80:112].split(b"\0")[0] != b"circuit_ble_display":
        problems.append("it is not Circuit firmware")
    if problems:
        print("Not bundled:", "; ".join(problems))
        return 1
    target = APP / "assets" / "firmware" / "circuit.bin"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    version = data[48:80].split(b"\0")[0].decode()
    print(f"Bundled {version} build {data[176:180].hex()} ({len(data) // 1024} KB) -> {target.relative_to(APP)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
