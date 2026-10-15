#!/usr/bin/env python3
"""Drive the Short-Circuit app from the Mac over adb, for tests. The screen is only for looking.

  app_dev.py install            build a release APK and install it over the current app (keeps data)
  app_dev.py state              note list and sync / playback / recording state, as JSON
  app_dev.py sync               ask Circuit to sync all waiting notes
  app_dev.py sync-note ID       sync one note (the app's note id from `state`)
  app_dev.py play               play the latest recording on Circuit
  app_dev.py play-stop          stop playback on Circuit
  app_dev.py rec-start          start a phone recording
  app_dev.py rec-pause | rec-resume | rec-stop
  app_dev.py delete ID [ID...]  delete notes (also removes them from Circuit when connected)
  app_dev.py delete-from N      delete every note that came from Circuit note number N or higher
  app_dev.py add-note "T|text|MIN|TYPE"  add a text note (no audio) with one suggestion due in MIN minutes; TYPE reminder, calendar_event or task
  app_dev.py add-reminder "T|MIN"  a task with a reminder MIN minutes from now (no screen needed)
  app_dev.py delete-tasks TEXT  delete every task whose title contains TEXT
  app_dev.py notes              each note's AI review state, transcript count and suggestions, as JSON
  app_dev.py tasks              the Tasks list with their reminder times, as JSON
  app_dev.py transcribe N       transcribe the note Circuit numbered N now, and report how much of it is Devanagari / Latin
  app_dev.py btlog [N]          the phone's own Bluetooth log: bond changes, drops, Repair pairing taps (last N lines, default 80)
  app_dev.py moments N          the Moments of the note Circuit numbered N, in ms from the start of the note
  app_dev.py play-moment N MS   play that note from MS (a Moment) and report where playback is
                                (test copies made by board_dev.py copy get the highest numbers)

Commands only run when "Test mode" is switched on in the app's Settings; otherwise the app logs
"ignored ... test mode is off". The command brings the app to the front, which also makes the app
reconnect to Circuit over Bluetooth if it had not. Set ANDROID_SERIAL to pick a phone if several are
attached. Answers are the app's "CircuitTest:" log lines.
"""
import os
import subprocess
import sys
import time

PACKAGE = "com.valay.circuit.short_circuit"
HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)


def adb(*args, check=True):
    return subprocess.run(["adb", *args], capture_output=True, text=True, check=check, timeout=60).stdout


def phone_time():
    return adb("shell", "date '+%m-%d %H:%M:%S.000'").strip()


def install():
    code = subprocess.call(["flutter", "build", "apk", "--release"], cwd=APP)
    if code:
        return code
    apk = os.path.join(APP, "build", "app", "outputs", "flutter-apk", "app-release.apk")
    print(adb("install", "-r", apk, check=False).strip())
    print(adb("shell", "dumpsys", "package", PACKAGE).split("versionCode=")[1].split()[0], "installed")
    return 0


def command(cmd, args):
    since = phone_time()
    # One string, so an empty argument list still reaches the phone's shell as ''
    adb("shell", f"am start -n {PACKAGE}/.MainActivity --es test_cmd '{cmd}' --es test_args '{args}'")
    deadline = time.time() + 25
    printed = 0
    while time.time() < deadline:
        lines = [
            l for l in adb("logcat", "-d", "-t", since, "-s", "CircuitTest:I", check=False).splitlines()
            if "CircuitTest" in l and not l.startswith("---")
        ]
        for line in lines[printed:]:
            print(line.split("CircuitTest:", 1)[1].strip())
        if lines:
            return 0
        time.sleep(1)
    print("(no answer: is the app installed with test support, and Test mode on in Settings?)")
    return 1


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        return 1
    if argv[0] == "install":
        return install()
    known = {"state", "sync", "sync-note", "play", "play-stop", "rec-start", "rec-pause", "rec-resume",
             "rec-stop", "delete", "delete-from", "btlog", "moments", "play-moment", "transcribe", "add-note", "tasks", "notes", "add-reminder", "delete-tasks"}
    if argv[0] not in known:
        print(__doc__)
        return 1
    return command(argv[0], " ".join(argv[1:]))


if __name__ == "__main__":
    sys.exit(main())
