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
