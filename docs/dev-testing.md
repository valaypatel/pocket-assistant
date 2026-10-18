# Testing without hands

Two scripts let a computer drive the board and the app. The screens are only for looking.

**Board** (`firmware/CircuitBleDisplay/tools/board_dev.py`) needs the development firmware, which has a USB command console. Release firmware has none.

```
board_dev.py build      # development firmware, in build-dev/
board_dev.py flash      # stops the log capture, flashes, restarts it
board_dev.py status | list | rec [S] | rec-pause | rec-stop | play | play-stop
board_dev.py key tap | key hold S      # the real key logic: 1 s pauses, 2 s forces a sync
board_dev.py lower-tap [hold S]        # the lower key: a tap while recording adds a Moment
board_dev.py moments ID                # opens the sealed Moments file of note ID and prints its offsets (ms)
board_dev.py lower                     # lower key (GPIO18) level and the presses seen
board_dev.py rtc | rtc-lose | clock-skew N   # RTC chip against the system clock; wipe the clock and restart; skew it
board_dev.py copy [N] | sync | copy-sync [N] | delete ID
```

`copy` makes N new, unsynced notes from the newest synced ones, so a sync can be repeated without recording. The phone cannot decrypt the copies (the note number is part of the encryption); delete them afterwards.

**App** (`apps/short_circuit/tool/app_dev.py`) works over adb. Switch on **Settings > Testing > Test mode** first; with it off every command is ignored.

```
app_dev.py install      # release build installed over the app, data kept
app_dev.py state | sync | sync-note ID | play | play-stop
app_dev.py rec-start | rec-pause | rec-resume | rec-stop
app_dev.py delete ID... | delete-from N   # N = Circuit note number; test copies have the highest numbers
```

Each command brings the app to the front, which also makes it reconnect to Circuit over Bluetooth. Answers are the app's `CircuitTest:` log lines.

**Typical run:** `board_dev.py copy-sync 3`, then `app_dev.py state`, then `app_dev.py delete-from <first copy number>`.

## Quick regression

`firmware/CircuitBleDisplay/tools/quick_regression.py` is the check to run after any firmware change. It needs
only the board (development firmware on USB, logger running, ESP-IDF python) and takes about 80 seconds:
record, pause, resume and stop; playback; recording over playback; Moments (taps saved, sealed, read back,
none when not recording); the lower key; the RTC chip and its restore after the clock is wiped; no panic;
cleanup of its own notes. Prints PASS/FAIL per check, exit code 1 on any failure.

```
~/.espressif/python_env/idf5.5_py3.9_env/bin/python firmware/CircuitBleDisplay/tools/quick_regression.py
```

Firmware 3 starts standalone (radios off). The quick regression includes a sync-mode section (Q8: a 3 s hold does
nothing, a 5 s hold opens sync mode, `syncmode off` closes it, a tap still records). The full regression syncs with the
phone, so run `board_dev.py connected on` first (the old always-connected behaviour) and `connected off` after.

Use the full regression below only for changes to sync, the app link or the recording join, and before a release.

## Regression test (full)

`firmware/CircuitBleDisplay/tools/regression.py` runs everything above in one go, about 25 minutes: record,
pause, resume and stop; playback; the priority rules (record over playback, a key tap during a sync, a
sync request during playback); a 2-minute recording in three parts that the app must join into one note;
a power cut mid-recording (the saved minute must come back, the phone must reconnect **without
re-pairing**, the app's recording indicator must clear, the SD log must hold the history); and a final
cleanup of the notes it made. It needs the development firmware on the board, the phone on the same Wi-Fi
with Test mode on, adb to the phone and the board logger running. It prints PASS/FAIL for each check.

Run it after any change to the firmware or to how the app talks to the board.

## The log on the SD card

The board copies its log to `/sdcard/LOGS/CIRCUIT0.LOG` (newest) up to `CIRCUIT3.LOG`: four files of up to 2 MB,
each line stamped with the board's UTC time. It is written in the background every 2 seconds, so a power
cut can lose the last 2 seconds. It stops writing if the card has less than 24 MB free. Read the end of it
without taking the card out: `board_dev.py logtail [KB] [file 0-3]`.

It also records, on its own, when the board's saved pairings change (`BOND COUNT CHANGED`), which pairings
it holds on every connection (`BONDS (on connect)`), and any wipe of the saved settings at start-up
(`NVS ERASED`). If a pairing request appears on the phone, these lines say whether the board still held the pairing.

## Does a failed Bluetooth handshake keep the pairing?

`board_dev.py drop-next-link MS` then `board_dev.py drop-now` cuts the next link MS milliseconds after the phone
connects (1 to 40 ms lands inside the security handshake). The board logs "BLE security failed ... reason 0x66"
and then "BONDS (after failed security): 1 stored": the pairing is kept (`firmware/CircuitBleDisplay/idf-patches/`),
the phone reconnects by itself and nothing asks to repair. Without the patch the same cut leaves "0 stored".

