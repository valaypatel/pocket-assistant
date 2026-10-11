#!/usr/bin/env python3
"""Development helper for the Circuit board: test sync without recording by hand.

  board_dev.py build            build the development firmware (adds a USB command console)
  board_dev.py flash            stop the logger, flash the development firmware, restart the logger
  board_dev.py copy [N]         copy the N newest synced notes (default 3) as new, unsynced notes
  board_dev.py sync             offer a Wi-Fi sync to the phone now and wait for it to end
  board_dev.py copy-sync [N]    both: copy N notes, then sync them
  board_dev.py status           internal RAM, notes waiting, and whether it is recording / playing / syncing
  board_dev.py rec [SECONDS]    start recording (default: until rec-stop)
  board_dev.py rec-pause        pause or resume the recording
  board_dev.py rec-stop         stop and save the recording
  board_dev.py play             play the latest recording
  board_dev.py play-stop        stop playback
  board_dev.py key tap          press the board's real key briefly (its own rules apply)
  board_dev.py key hold [S]     hold the real key for S seconds (1 s pauses, 2 s forces a sync)
  board_dev.py list             the newest notes on the card and whether each is waiting or synced
  board_dev.py delete ID        delete one note from the card (only while idle)
  board_dev.py resend           mark every note unsynced and sync them all again (what "Send old notes again" does)
  board_dev.py logtail [KB] [FILE]  print the end of the log kept on the SD card (default 8 KB of file 0, the newest; 1-3 are older)
  board_dev.py crash            restart the board at once, like a power cut (nothing gets to finish)

The console only exists in the development build; release firmware ignores these commands.
Commands go to the board over USB serial without resetting it. Answers are read from the board
logger's file (~/.circuit-logs/board-serial.log), so the logger keeps the port to itself.
The phone must be on the board's Wi-Fi and connected over Bluetooth for a sync.

The copies are byte-for-byte the same data under new note numbers, so the phone receives them as
new notes it cannot decrypt: delete them in the app afterwards (that also removes them from the board).
"""
import glob
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
BUILD_DIR = os.path.join(PROJECT, "build-dev")
LOG = os.path.expanduser("~/.circuit-logs/board-serial.log")
LOGGER_DIR = os.path.expanduser("~/.circuit-logs")
IDF_ENV = os.path.expanduser("~/.espressif/python_env/idf5.5_py3.9_env")
IDF_EXPORT = os.path.join(os.path.dirname(os.path.dirname(PROJECT)), "vendor", "esp-idf-5.5.3", "export.sh")


def port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("No board found on USB (/dev/cu.usbmodem*).")
    return ports[0]


def idf_shell(command, cwd):
    script = f'export IDF_PYTHON_ENV_PATH="{IDF_ENV}" PATH="{IDF_ENV}/bin:$PATH"; source "{IDF_EXPORT}" >/dev/null 2>&1; {command}'
    return subprocess.call(["bash", "-c", script], cwd=cwd)


def build():
    return idf_shell(f'idf.py -B "{BUILD_DIR}" -DCIRCUIT_DEV_CONSOLE=1 build', PROJECT)


def logger_pid_file():
    return os.path.join(LOGGER_DIR, "logger.pid")


def stop_logger():
    try:
        with open(logger_pid_file()) as f:
            os.kill(int(f.read().strip()), 15)
        time.sleep(2)
    except (OSError, ValueError):
        pass


def start_logger():
    python = os.path.join(IDF_ENV, "bin", "python")
    proc = subprocess.Popen(
        [python, os.path.join(LOGGER_DIR, "board_logger.py")],
        stdout=subprocess.DEVNULL, stderr=open(os.path.join(LOGGER_DIR, "logger.err"), "w"),
        start_new_session=True,
    )
    with open(logger_pid_file(), "w") as f:
        f.write(str(proc.pid))


def flash():
    if not os.path.exists(os.path.join(BUILD_DIR, "flash_args")):
        sys.exit("Build first: board_dev.py build")
    stop_logger()
    try:
        code = idf_shell(f'python -m esptool --chip esp32s3 -p {port()} -b 460800 write_flash "@flash_args"', BUILD_DIR)
    finally:
        start_logger()
    return code


def log_size():
    return os.path.getsize(LOG) if os.path.exists(LOG) else 0


def send(command, wait_for, timeout):
    """Writes a command to the board and prints its DEV lines until one containing wait_for appears."""
    import serial  # pyserial comes with the ESP-IDF python environment

    start = log_size()
    link = serial.Serial()
    link.port = port()
    link.baudrate = 115200
    link.dtr = False  # opening the port must not reset the board
    link.rts = False
    link.open()
    link.write((command + "\n").encode())
    link.flush()
    link.close()
    deadline = time.time() + timeout
    seen = 0
    while time.time() < deadline:
        with open(LOG, errors="replace") as f:
            f.seek(start)
            lines = [l.rstrip() for l in f.read().splitlines() if "DEV" in l or "CircuitHeap" in l or "SYNCSTAT" in l or "Sync requested" in l or "SDLOG|" in l]
        for line in lines[seen:]:
            print(line)
            if wait_for and any(w in line for w in ([wait_for] if isinstance(wait_for, str) else wait_for)):
                return 0
        seen = len(lines)
        time.sleep(1)
    print("(no answer: is the development firmware flashed and the logger running?)")
    return 1


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    cmd = args[0]
    n = args[1] if len(args) > 1 else "3"
    if cmd == "build":
        return build()
    if cmd == "flash":
        return flash()
    if cmd == "copy":
        return send(f"copy {n}", "DEV copy done", 60)
    if cmd == "sync":
        return send("sync", ("SYNCSTAT", "no new notes", "Nothing to sync", "0 file(s)"), 600)
    if cmd == "copy-sync":
        return send(f"copy-sync {n}", ("SYNCSTAT", "0 file(s)"), 600)
    if cmd == "status":
        return send("status", "DEV status", 10)
    if cmd == "rec":
        return send("rec" + ("" if len(args) < 2 else " " + args[1]), "DEV record requested", 10)
    if cmd == "rec-pause":
        return send("rec-pause", "DEV pause toggled", 10)
    if cmd == "rec-stop":
        return send("rec-stop", "DEV stop requested", 10)
    if cmd == "play":
        return send("play", "DEV play requested", 10)
    if cmd == "play-stop":
        return send("play-stop", "DEV play-stop requested", 10)
    if cmd == "key":
        what = " ".join(args[1:]) if len(args) > 1 else "tap"
        return send("key " + what, "DEV key pressed", 15)
    if cmd == "rtc":
        return send("rtc", "DEV rtc:", 10)
    if cmd == "clock-skew" and len(args) > 1:
        return send("clock-skew " + args[1], "DEV clock-skew", 10)
    if cmd == "rtc-lose":
        return send("rtc-lose", "DEV rtc-lose", 10)
    if cmd == "lower":
        return send("lower", "DEV lower:", 10)
    if cmd == "resend":
        return send("resend", ("SYNCSTAT", "0 file(s)"), 900)
    if cmd == "logtail":
        return send("logtail " + " ".join(args[1:]) if len(args) > 1 else "logtail", ("SDLOG| end", "no log file"), 60)
    if cmd == "crash":
        return send("crash", "DEV crash requested", 10)
    if cmd == "list":
        return send("list", "DEV list done", 10)
    if cmd == "delete" and len(args) > 1:
        return send("delete " + args[1], "DEV delete", 10)
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
