#!/usr/bin/env python3
"""Development helper for the Circuit board: test sync without recording by hand.

  board_dev.py build [--sleep]  build the development firmware (--sleep: light sleep on from the start; the USB console then drops out while it sleeps) (adds a USB command console); each build gets the next number, 2.0.0-dev.N
  board_dev.py flash            stop the logger, flash the development firmware, restart the logger
  board_dev.py copy [N]         copy the N newest synced notes (default 3) as new, unsynced notes
  board_dev.py sync             offer a Wi-Fi sync to the phone now and wait for it to end
  board_dev.py drop-next-link [MS]  cut the next Bluetooth link MS ms after it connects (tests that the pairing survives)
  board_dev.py drop-now         cut the current Bluetooth link at once (the phone reconnects by itself)
  board_dev.py copy-sync [N]    both: copy N notes, then sync them
  board_dev.py speak-open       open a broadcast session and print its address, port, token and fingerprint
  board_dev.py firmware-open    open an update session and print its address, port, token and fingerprint (then PUT the .bin to /firmware)
  board_dev.py sleep on|off     turn light sleep on or off now (the USB port drops out while it is on and the chip sleeps)
  board_dev.py pm               log the power manager's table: time at each speed and asleep, and what holds the chip awake
  board_dev.py update-screen [N]  show the firmware-update screen at N% for a minute (no update happens)
  board_dev.py battery-set N    pretend the charge is N% for about a minute (checks the LOW header and the phone's alert)
  board_dev.py battery          the battery voltage and a rough percentage (read from the board's sense line)
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


BUILD_NUMBER_FILE = os.path.join(PROJECT, ".build-number")  # not committed: it counts builds on this machine
VERSION_BASE = "2.0.0-dev"


def next_version():
    """2.0.0-dev.N, with N one higher than the last development build, so a newer build is always a bigger number."""
    try:
        with open(BUILD_NUMBER_FILE) as f:
            number = int(f.read().strip()) + 1
    except (OSError, ValueError):
        number = 2  # the first numbered build; the old unnumbered ones were "2.0.0-dev1"
    with open(BUILD_NUMBER_FILE, "w") as f:
        f.write(str(number))
    return f"{VERSION_BASE}.{number}"


def build(sleep=False):
    version = next_version()
    print(f"Building firmware {version}" + (" (light sleep on from the start)" if sleep else ""))
    flag = " -DCIRCUIT_LIGHT_SLEEP=1" if sleep else " -DCIRCUIT_LIGHT_SLEEP="
    return idf_shell(f'idf.py -B "{BUILD_DIR}" -DCIRCUIT_DEV_CONSOLE=1 -DCIRCUIT_VERSION={version}{flag} build', PROJECT)


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
    # Opening the port must not reset the board. On macOS, forcing DTR and RTS low *before* opening does reset it
    # (USB_UART_CHIP_RESET), and a program that reopens the port in a loop then restarts the board in a loop.
    # Open the quiet way, then lower RTS first and DTR second: no reset.
    link.dtr = True
    link.rts = True
    link.open()
    link.rts = False
    link.dtr = False
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
        return build(sleep="--sleep" in args)
    if cmd == "flash":
        return flash()
    if cmd == "copy":
        return send(f"copy {n}", "DEV copy done", 60)
    if cmd == "sync":
        return send("sync", ("SYNCSTAT", "no new notes", "Nothing to sync", "0 file(s)"), 600)
    if cmd == "drop-next-link":
        return send("drop-next-link " + (n if len(args) > 1 else "100"), "DEV drop-next-link armed", 15)
    if cmd == "drop-now":
        return send("drop-now", "DEV drop-now", 15)
    if cmd == "bonds":
        return send("status", "DEV status", 10)
    if cmd == "copy-sync":
        return send(f"copy-sync {n}", ("SYNCSTAT", "0 file(s)"), 600)
    if cmd == "sleep" and len(args) > 1:
        return send("sleep " + args[1], "DEV sleep", 15)
    if cmd == "pm":
        return send("pm", "DEV pm", 15)
    if cmd == "update-screen":
        return send("update-screen" + (" " + args[1] if len(args) > 1 else ""), "DEV update-screen", 15)
    if cmd == "firmware-open":
        return send("firmware-open", ("DEV firmware-open", "Update failed", "Update needs"), 15)
    if cmd == "speak-open":
        return send("speak-open", ("DEV speak-open", "Broadcast failed", "Broadcast needs"), 15)
    if cmd == "battery-set" and len(args) > 1:
        return send("battery-set " + args[1], "DEV battery-set", 15)
    if cmd == "battery":
        return send("battery", "DEV battery", 25)
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
    if cmd == "lower-tap":
        what = " ".join(args[1:]) if len(args) > 1 else ""
        return send(("lower-tap " + what).strip(), "DEV lower key pressed", 15)
    if cmd == "copy-last":
        return send("copy-last", "DEV copy-last done", 60)
    if cmd == "cue":
        return send("cue", "DEV cue:", 10)
    if cmd == "moments-selftest":
        return send("moments-selftest", "DEV moments-selftest", 10)
    if cmd == "moments" and len(args) > 1:
        return send("moments " + args[1], "DEV moments of note", 10)
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
