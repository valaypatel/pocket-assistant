# Power: standalone and sync mode (firmware 3)

From firmware 3.0.0 Circuit works on its own. Its radios (Bluetooth advertising, Wi-Fi) are off and the chip sleeps
between jobs. The phone is only involved during a **sync mode** that the person starts on the board.

## Standalone (the default)

- Records, plays back and shows its screen by itself. Nothing waits for a phone.
- Bluetooth does not advertise and Wi-Fi is stopped (the network is remembered).
- Notes wait on the card until the next sync. The phone cannot ask the board anything, so the app shows what it last
  knew ("Last seen 2 h ago · 90%") and no count of waiting notes.
- The phone cannot record, play or broadcast on the board in this mode (those commands are refused with a message).

## Sync mode

1. Hold the record key for **5 seconds** while idle. A tap (under 1.2 s) still records; a hold between the two does
   nothing.
2. The board advertises and shows the sync picture with "Sync mode / Open the app".
3. Open the app. It connects (the phone does not look for the board in the background) and the board starts the sync
   by itself. The phone also brings the clock and time zone, the Wi-Fi network, deletes of notes removed on the phone,
   and a firmware update if one is chosen. Wi-Fi is switched on only when a sync or an update needs it.
4. It ends 60 seconds after the last activity (a command, a sync, an update, a key press), after 2 minutes with no
   phone, or when the key is held for 5 seconds again. Radios go down; the app stops chasing the board.

A board that has never been paired stays in sync mode until a phone has paired.

## Battery

- At **10% or below** on battery the hold shows "LOW" and the radios stay off, so the last charge goes to recording.
  With a charger or a computer on the cable the hold works as normal.
- A **firmware update needs 30%** battery.
- Charging: a bolt shows in the battery icon, the charger's push is taken off the reading, and 100 shows once the
  charger has ended its cycle (see `battery_tick` in `main.cpp`).

## What is kept for later

The always-connected behaviour (Saver, Deep and recording-only tiers, the phone's Auto/Saver/Deep choice, Wi-Fi
resting, broadcast, remote record and play) is still in the firmware behind `connected_mode`, a development switch
(`tools/board_dev.py connected on|off`, restarts the board). It is the base for a "stay connected" option later.
The board reports `mode=sync` or `mode=connected` in its status; a board that reports none is firmware 2 and stays
linked, and the app treats it that way.

## Testing

- `tools/board_dev.py syncmode on|off` opens and closes sync mode; `key hold 6` does it with the real key code.
- `tools/quick_regression.py` (board only) checks the 3 s hold, the 5 s hold, closing, and a tap still recording.
- `tools/regression.py` (full, with the phone) syncs over the old connected behaviour: run it after
  `board_dev.py connected on`, then switch back with `connected off`.
