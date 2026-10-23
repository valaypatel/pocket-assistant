"""Quick regression for Circuit: the board only, about 3 minutes, no phone needed.

Run it after a change to the firmware. It does not replace regression.py (sync with the app, the 3-part
recording, the power cut), which takes about 25 minutes and belongs before a release or after a change
to sync, the app link or the recording join.

Needs: the board on USB with the development firmware (tools/board_dev.py build + flash) and the board
logger running (~/.circuit-logs). Use the ESP-IDF python (it has pyserial). Prints PASS/FAIL per check
and a summary; exit code 1 if any failed. The notes it makes are removed at the end.

Checks: the board is idle and reports a version; record, pause, resume and stop lose no audio; playback
starts and stops; recording takes priority over playback; Moments (lower key taps) are saved, sealed and
read back, a tap while not recording adds nothing, a note without taps has none; the RTC chip agrees with
the clock and restores it after the clock is wiped; no panic or stack overflow; only the one restart the
RTC test causes.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BOARD = [sys.executable, os.path.join(HERE, "board_dev.py")]
LOG = os.path.expanduser("~/.circuit-logs/board-serial.log")
results = []


def b(*a, timeout=120):
    return subprocess.run(BOARD + list(a), capture_output=True, text=True, timeout=timeout).stdout


def pos():
    return os.path.getsize(LOG)


def since(p):
    with open(LOG, errors="replace") as f:
        f.seek(p)
        return f.read()


def wait_for(text, p, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if text in since(p):
            return True
        time.sleep(1)
    return False


def status():
    out = b("status", timeout=60)
    d = {}
    m = re.search(r"version=(\S+) waiting=(\d+) recording=(\d+) paused=(\d+) playing=(\d+) sync_open=(\d+)", out)
    if m:
        d.update(version=m.group(1), waiting=int(m.group(2)), recording=int(m.group(3)), paused=int(m.group(4)),
                 playing=int(m.group(5)), sync_open=int(m.group(6)))
    return d


def note(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + (" -- " + detail if detail else ""), flush=True)


def moments_of(note_id):
    out = b("moments", str(note_id), timeout=60)
    m = re.search(r"DEV moments of note \d+: (\d+):([\d ]*)", out)
    if not m:
        return None
    return [int(x) for x in m.group(2).split()]


def saved_id(text):
    m = re.findall(r"Saved recording (\d+) as", text)
    return int(m[-1]) if m else None


boot_p = pos()

print("== Q0 preconditions", flush=True)
for _ in range(30):  # a sync left over from an earlier run must finish first
    s0 = status()
    if s0.get("sync_open") == 0:
        break
    time.sleep(2)
note("Q0 board answers, idle, reports a version", s0.get("recording") == 0 and s0.get("playing") == 0
     and s0.get("sync_open") == 0 and bool(s0.get("version")), str(s0))
note("Q0 firmware is version 3 or later", str(s0.get("version", "")).startswith("3."), str(s0.get("version")))
ids = [int(x) for x in re.findall(r"DEV note (\d+):", b("list", timeout=60))]
start_id = max(ids) if ids else 0

print("== Q1 record, pause, resume, stop", flush=True)
p = pos()
b("rec")
time.sleep(4)
a = status()
b("rec-pause")
time.sleep(2)
pz = status()
b("rec-pause")
time.sleep(2)
b("rec-stop")
ok = wait_for("Saved recording", p, 20)
rs = re.findall(r"RECSTAT audio=(\d+) ms, recording time=(\d+) ms, lost=(-?\d+) ms, paused=(\d+) ms, parts=(\d+)", since(p))
lost = int(rs[-1][2]) if rs else 999
note("Q1 recording starts", a.get("recording") == 1)
note("Q1 pause shows paused", pz.get("paused") == 1)
note("Q1 stop saves one note, nothing lost", ok and bool(rs) and abs(lost) < 400 and rs[-1][4] == "1",
     str(rs[-1]) if rs else "no RECSTAT")
plain_id = saved_id(since(p))

print("== Q2 playback", flush=True)
time.sleep(1)
b("play")
time.sleep(3)
a = status()
b("play-stop")
time.sleep(2)
z = status()
note("Q2 play starts, stop stops", a.get("playing") == 1 and z.get("playing") == 0, f"{a.get('playing')}/{z.get('playing')}")

print("== Q3 record during playback", flush=True)
p = pos()
b("play")
time.sleep(3)
b("rec", "5")
time.sleep(2)
a = status()
wait_for("Saved recording", p, 15)
t = since(p)
note("Q3 recording during playback stops playback and records", "Playback stopped" in t and a.get("recording") == 1 and "Saved recording" in t)

print("== Q4 Moments", flush=True)
p = pos()
b("lower-tap")  # not recording: must add nothing
time.sleep(1)
note("Q4 a lower tap while not recording adds nothing", "Moment requested" not in since(p))
p = pos()
b("rec", "60")
time.sleep(4)
q = pos()
b("lower-tap")
wait_for("cue-after-tap", q, 8)  # the board reads its own screen 1.3 s after the press
cue1 = since(q)
q = pos()
b("lower-tap")
wait_for("cue-after-tap", q, 8)
cue2 = since(q)
time.sleep(4)  # the cue goes away about 3 s after the last tap, while the recording goes on
cue3 = b("cue", timeout=60)
b("rec-stop")
ok = wait_for("Saved recording", p, 20)
note("Q4 the screen cue shows the bookmark with the tap count (1, then 2) and hides after a few seconds",
     "screen=1 icon_hidden=0 number='1'" in cue1 and "screen=1 icon_hidden=0 number='2'" in cue2 and "screen=1 icon_hidden=1" in cue3,
     (cue1.strip()[-70:] + " | " + cue2.strip()[-70:] + " | " + cue3.strip()[-70:]))
mid = saved_id(since(p))
offsets = moments_of(mid) if mid else None
good = bool(offsets) and len(offsets) == 2 and 2000 <= offsets[0] <= 8000 and 1500 <= offsets[1] - offsets[0] <= 9000
note("Q4 two taps give two Moments, in order, a few seconds apart", ok and good, str(offsets))
note("Q4 a note without taps has no Moments file", plain_id is not None and moments_of(plain_id) == [], str(moments_of(plain_id) if plain_id else None))

st = b("moments-selftest", timeout=60)
note("Q4 the Moments file matches the shared test vector", "moments-selftest: PASS" in st, st.strip()[-80:])

print("== Q5 lower key", flush=True)
lw = b("lower")
m = re.search(r"GPIO18 level=(\d) .*presses=(\d+)", lw)
note("Q5 lower key reads as released and the presses were counted", bool(m) and m.group(1) == "1" and int(m.group(2)) >= 3, lw.strip()[-120:])

print("== Q8 standalone and sync mode", flush=True)
p = pos()
b("key", "hold", "3")  # too short for sync mode, too long for a tap: nothing happens
time.sleep(2)
t = since(p)
note("Q8 a 3 s hold does nothing (no sync mode, no recording)",
     "Sync mode: on" not in t and "Recording" not in t and status().get("recording") == 0, "")
p = pos()
b("key", "hold", "6")
ok = wait_for("Sync mode: on", p, 15)
adv = wait_for("Advertising as", p, 10)
note("Q8 a 5 s hold opens sync mode and the board advertises", ok and adv, "")
p = pos()
b("syncmode", "off")
off = wait_for("Sync mode: off", p, 15)
note("Q8 sync mode can be closed (Bluetooth stops, Wi-Fi rests)", off, "")
p = pos()
b("key", "tap")
time.sleep(3)
rec = status().get("recording") == 1
b("rec-stop")
wait_for("Saved recording", p, 20)
note("Q8 a short tap still starts a recording", rec, "")
# a quick tap stops a recording at the first try (the key used to be missed now and then while the chip woke from sleep)
time.sleep(6)  # the previous recording is still being saved
p = pos()
b("rec")
time.sleep(3)
started = status().get("recording") == 1
b("key", "tap")
time.sleep(2)
stopped = status().get("recording") == 0
wait_for("Saved recording", p, 20)
note("Q8 one tap on the key stops a recording", started and stopped, "")
b("wifi-try-fake", timeout=60)  # the radio keeps trying a network that is not there...
time.sleep(8)
scan = b("wifi-scan-test", timeout=90)
m = re.search(r"wifi-scan-test: (\d+) access points", scan)
note("Q8 a Wi-Fi scan works while the board is failing to join a network", bool(m) and int(m.group(1)) > 0, scan.strip()[-60:])

print("== Q6 RTC", flush=True)
m = re.search(r"chip=(\w+) \d+, system=\d+, difference=(-?\d+) s", b("rtc", timeout=60))
note("Q6 RTC chip valid and within 3 s of the clock", bool(m) and m.group(1) == "valid" and abs(int(m.group(2))) <= 3, m.group(0) if m else "no answer")
p = pos()
b("rtc-lose")
restored = wait_for("Clock restored from the RTC chip", p, 40)
time.sleep(4)
m = re.search(r"chip=(\w+) \d+, system=\d+, difference=(-?\d+) s", b("rtc", timeout=60))
note("Q6 after the clock is wiped and the board restarts, the RTC restores it", restored and bool(m) and abs(int(m.group(2))) <= 5, m.group(0) if m else "no answer")

print("== Q7 health and cleanup", flush=True)
t = since(boot_p)
note("Q7 no stack overflow or panic", not re.search(r"stack overflow|Guru Meditation|abort\(\)|panic'ed", t, re.I))
note("Q7 only the one deliberate restart happened", len(re.findall(r"Reset reason:", t)) == 1, "restarts=%d" % len(re.findall(r"Reset reason:", t)))
for nid in sorted({int(x) for x in re.findall(r"DEV note (\d+):", b("list", timeout=60))}):
    if nid > start_id:
        b("delete", str(nid), timeout=60)
left = [int(x) for x in re.findall(r"DEV note (\d+):", b("list", timeout=60)) if int(x) > start_id]
note("Q7 cleanup: test notes removed", left == [], str(left))

failed = [r for r in results if not r[1]]
print("\n==== SUMMARY ====")
print("%d passed, %d failed" % (len(results) - len(failed), len(failed)))
for name, _, detail in failed:
    print("FAILED:", name, detail)
sys.exit(1 if failed else 0)
