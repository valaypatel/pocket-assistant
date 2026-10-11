"""Regression test for Circuit and the Short-Circuit app, driven from the Mac.

Needs: the board on USB with the development firmware (tools/board_dev.py build + flash), the phone
on the same Wi-Fi with Test mode on (Settings > Testing), adb to the phone (ANDROID_SERIAL if more than
one) and the board logger running (~/.circuit-logs). Takes about 25 minutes. Keep the phone awake.

It records, plays, syncs, loses power mid-recording and checks the board and the app after each step,
then removes the notes it made. Prints PASS/FAIL per check and a summary; exit code 1 if any failed.
"""
import json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
BOARD = [sys.executable, f"{ROOT}/firmware/CircuitBleDisplay/tools/board_dev.py"]
APP = [sys.executable, f"{ROOT}/apps/short_circuit/tool/app_dev.py"]
LOG = os.path.expanduser("~/.circuit-logs/board-serial.log")
results = []


def run(cmd, timeout=900):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


def b(*a, timeout=900):
    return run(BOARD + list(a), timeout)


def app(*a, timeout=300):
    return run(APP + list(a), timeout)


def pos():
    return os.path.getsize(LOG)


def since(p):
    with open(LOG, errors="replace") as f:
        f.seek(p)
        return f.read()


def status():
    out = b("status", timeout=60)
    heap = re.search(r"dev status\s+free\s+(\d+)\s+largest\s+(\d+)\s+lowest ever\s+(\d+)", out)
    st = re.search(r"waiting=(\d+) recording=(\d+) paused=(\d+) playing=(\d+) sync_open=(\d+)", out)
    lv = re.search(r"highest ever used (\d+) \((\d+)%\)", out)
    d = {}
    if heap:
        d.update(free=int(heap.group(1)), largest=int(heap.group(2)), lowest=int(heap.group(3)))
    if st:
        d.update(waiting=int(st.group(1)), recording=int(st.group(2)), paused=int(st.group(3)),
                 playing=int(st.group(4)), sync_open=int(st.group(5)))
    if lv:
        d.update(lv_used=int(lv.group(1)), lv_pct=int(lv.group(2)))
    return d


def app_state():
    t = app("state", timeout=120)
    i = t.find("{")
    return json.loads(t[i:]) if i >= 0 else None


def note(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + (" -- " + detail if detail else ""), flush=True)


def wait_for(text, p, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if text in since(p):
            return True
        time.sleep(2)
    return False


def wait_synced(p, timeout=420):
    return wait_for("SYNCSTAT", p, timeout)


def syncstat(p):
    m = re.findall(r"SYNCSTAT served=(\d+) bytes, session (\d+) ms.*?\((\d+) KB/s\)", since(p))
    return m[-1] if m else None


start_id = None

# ---- T0: preconditions
print("== T0 preconditions", flush=True)
app("state")
time.sleep(6)
s0 = status()
note("T0 board answers and is idle", s0.get("recording") == 0 and s0.get("playing") == 0, str(s0))
st = app_state()
note("T0 phone app reachable (test mode on)", st is not None, "notes=%s" % (len(st["notes"]) if st else "?"))
lst = b("list", timeout=60)
ids = [int(x) for x in re.findall(r"DEV note (\d+):", lst)]
start_id = max(ids) if ids else 0
print("highest note id on the card at start:", start_id, flush=True)
boot_p = pos()

# ---- T1 record / pause / resume / stop
print("== T1 record, pause, resume, stop", flush=True)
p = pos()
b("rec", timeout=60)
time.sleep(5)
a = status()
b("rec-pause", timeout=60)
time.sleep(3)
pz = status()
b("rec-pause", timeout=60)
time.sleep(3)
b("rec-stop", timeout=60)
ok = wait_for("Saved recording", p, 30)
rs = re.findall(r"RECSTAT audio=(\d+) ms, recording time=(\d+) ms, lost=(-?\d+) ms, paused=(\d+) ms, parts=(\d+)", since(p))
lost = int(rs[-1][2]) if rs else 999
note("T1 recording starts", a.get("recording") == 1)
note("T1 pause shows paused", pz.get("paused") == 1)
note("T1 stop saves one note, nothing lost", ok and rs and abs(lost) < 400 and rs[-1][4] == "1", str(rs[-1]) if rs else "no RECSTAT")

# ---- T2 playback
print("== T2 playback", flush=True)
time.sleep(2)
b("play", timeout=60)
time.sleep(3)
a = status()
b("play-stop", timeout=60)
time.sleep(2)
z = status()
note("T2 play starts, stop stops", a.get("playing") == 1 and z.get("playing") == 0, f"{a.get('playing')}/{z.get('playing')}")

# ---- T3 priority: record during playback
print("== T3 priority: record during playback", flush=True)
p = pos()
b("play", timeout=60)
time.sleep(3)
b("rec", "5", timeout=60)
time.sleep(2)
a = status()
time.sleep(8)
t = since(p)
note("T3 recording during playback stops playback and records", "Playback stopped" in t and a.get("recording") == 1 and "Saved recording" in t)

# ---- T4 priority: key tap during sync is refused
print("== T4 priority: key tap during sync", flush=True)
b("copy", "2", timeout=120)
p = pos()
subprocess.Popen(BOARD + ["sync"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(12)
b("key", "tap", timeout=60)
time.sleep(3)
a = status()
note("T4 key tap during sync does not record", a.get("sync_open") == 1 and a.get("recording") == 0, str(a))
ok = wait_synced(p)
ss = syncstat(p)
note("T4 sync finishes and moves data", ok and ss is not None and int(ss[0]) > 0, f"bytes/ms/KBs={ss}")
sync_lowest = None
t = since(p)
lows = [int(x) for x in re.findall(r"CircuitHeap: sync: transferring .*?lowest ever\s+(\d+)", t)]
if lows:
    sync_lowest = min(lows)
note("T4 memory during sync: lowest free internal RAM (was 1-3 KB before the graphics pool change)", sync_lowest is None or sync_lowest > 3000, f"lowest={sync_lowest}")
time.sleep(5)

# ---- T5 priority: sync request during playback
print("== T5 priority: app sync during playback", flush=True)
b("copy", "1", timeout=120)
p = pos()
b("play", timeout=60)
time.sleep(3)
app("sync")
time.sleep(10)
t = since(p)
note("T5 sync request during playback stops playback and syncs", "Playback stopped" in t and "Sync requested (app)" in t)
ok5 = wait_synced(p)
ss5 = syncstat(p)
note("T5 that sync moves data", ok5 and ss5 is not None and int(ss5[0]) > 0, f"bytes/ms/KBs={ss5}")
time.sleep(5)

# ---- T6 long recording in parts, synced and joined by the app
print("== T6 long recording (3 parts) joined in the app", flush=True)
before = {n["boardId"] for n in app_state()["notes"] if n["boardId"]}
p = pos()
b("rec", "125", timeout=60)
ok = wait_for("Saved recording", p, 170)
rs = re.findall(r"RECSTAT audio=(\d+) ms, recording time=(\d+) ms, lost=(-?\d+) ms, paused=(\d+) ms, parts=(\d+), longest join=(\d+) ms", since(p))
note("T6 long recording saves as 3 parts, no gap", ok and rs and rs[-1][4] == "3" and abs(int(rs[-1][2])) < 400 and int(rs[-1][5]) < 300, str(rs[-1]) if rs else "none")
time.sleep(3)
p = pos()
app("sync")
wait_synced(p, 480)
time.sleep(8)
st = app_state()
new_multi = [n for n in st["notes"] if n["boardId"] and n["boardId"] not in before and n["parts"] == 3]
note("T6 app joined the 3 parts into one note", len(new_multi) == 1, "multi-part notes: %d" % len(new_multi))
note("T6 nothing left waiting on the board", st["boardWaiting"] == 0, "boardWaiting=%s" % st["boardWaiting"])

# ---- T7 power loss + pairing persistence + SD log
print("== T7 power loss mid-recording, pairing persistence, SD log", flush=True)
b("rec", "120", timeout=60)
time.sleep(70)
before_crash = app_state()
note("T7 the app shows the board recording before the cut", bool(before_crash and before_crash.get("circuitRecording")))
p = pos()
b("crash", timeout=60)
time.sleep(45)
t = since(p)
note("T7 board restarts after the cut", "Reset reason" in t)
note("T7 no data wipe at start-up", "NVS ERASED" not in t)
note("T7 SD card mounts after the cut", "MicroSD mounted and read/write test passed" in t)
m = re.search(r"Notes on card: (\d+) unsynced", t)
note("T7 the saved minute is on the card", bool(m) and int(m.group(1)) >= 1, m.group(0) if m else "no line")
app("state")
time.sleep(25)
t = since(p)
connected = re.search(r"Short-Circuit connected: .*?, (\d+) bonded phone", t)
secured = "BLE link secured" in t
note("T7 phone reconnects after a restart WITHOUT re-pairing", secured and "A phone is pairing" not in t and "BLE security failed" not in t,
     (connected.group(0) if connected else "no connect") )
after = app_state()
note("T7 the recording indicator is cleared after the board restarted", bool(after) and after.get("circuitRecording") is False, "circuitRecording=%s" % (after.get("circuitRecording") if after else "?"))
p2 = pos()
app("sync")
wait_synced(p2, 240)
time.sleep(6)
st = app_state()
rec_notes = [n for n in st["notes"] if n["boardId"] and n["boardId"] > start_id]
note("T7 the recovered recording reached the app as a finished note", any(n["parts"] <= 1 and n["audio"] for n in rec_notes))
lt = b("logtail", "64", timeout=90)
# The log is written every 2 s, so the last 2 s before the cut can be missing; everything earlier must be there.
note("T7 SD log survived the power cut (history from before it, and the boot after it)",
     "DEV record requested (120 s)" in lt and "log opened" in lt and "Reset reason: 3" in lt)

# ---- T8 final state
print("== T8 final checks", flush=True)
fin = status()
note("T8 graphics pool peak below 80% of its 32 KB", fin.get("lv_pct", 100) < 80, str(fin.get("lv_used")) + " bytes, %s%%" % fin.get("lv_pct"))
whole = since(boot_p)
resets = len([l for l in whole.splitlines() if "Reset reason" in l and "SDLOG|" not in l])
note("T8 only the one deliberate restart happened", resets == 1, "restarts=%d" % resets)
note("T8 no stack overflow or panic", "stack overflow" not in whole and "Guru Meditation" not in whole)
st = app_state()
cleanup = app("delete-from", str(start_id + 1), timeout=300)
time.sleep(40)
lst = b("list", timeout=60)
left = [int(x) for x in re.findall(r"DEV note (\d+):", lst) if int(x) > start_id]
note("T8 cleanup: test notes removed from the board", not left, str(left))
st = app_state()
note("T8 cleanup: app has no test notes", all((n["boardId"] or 0) <= start_id for n in st["notes"]))

print("\n==== SUMMARY ====")
bad = [r for r in results if not r[1]]
print(f"{len(results) - len(bad)} passed, {len(bad)} failed")
for r in bad:
    print("FAILED:", r[0], r[2])
sys.exit(1 if bad else 0)
