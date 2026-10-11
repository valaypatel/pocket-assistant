# Testing without hands

Two scripts let a computer drive the board and the app. The screens are only for looking.

**Board** (`firmware/CircuitBleDisplay/tools/board_dev.py`) needs the development firmware, which has a USB command console. Release firmware has none.

```
board_dev.py build      # development firmware, in build-dev/
board_dev.py flash      # stops the log capture, flashes, restarts it
board_dev.py status | list | rec [S] | rec-pause | rec-stop | play | play-stop
board_dev.py key tap | key hold S      # the real key logic: 1 s pauses, 2 s forces a sync
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

## Regression test

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
