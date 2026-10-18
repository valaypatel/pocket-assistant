# Power modes

Circuit decides how much it does from its battery. The phone can ask it to save more, never less than the battery
allows. The board reports its mode in the third `@sync-status` packet as `pm=<mode>|<choice>`.

| Battery | Mode (`pm=`) | What the board does |
|---|---|---|
| above 35% | **Saver** (`saver`) | Light sleep; Bluetooth connected at a relaxed rhythm; sync, broadcast, updates and playback all work. |
| 35% down to 10% | **Deep** (`deep`) | The radios are used sparingly (stage 3 below). Recording works. |
| 10% or below | **Recording only** (`rec`) | It records and nothing else: no sync, no broadcast, no update, no playback. The app greys those actions out. |

A tier is entered at its threshold and left 5 points higher: Saver to Deep at 35% and back at 40%; Deep to
recording-only at 10% and back to Deep at 15%. The percentage is rounded to steps of 5 and comes from the voltage,
so it wobbles with load; the margin keeps it from flipping. The empty-battery switch-off at about 3.25 V stays as the
last line of defence.

The phone's choice (`@power-mode\n<auto|saver|deep>`) is kept across restarts. "Deep" asks for that tier early;
"Saver" and "Auto" follow the battery. Whichever is chosen, the battery's tier wins when it is higher.

## Stages

1. **Mode logic** (built): the tiers with their margins, the phone's choice, the report to the app, and a line and a
   "Power mode" row in the app.
2. **Recording-only lock** (built): sync, broadcast, update, firmware revert and playback are refused at 10% or below,
   with a message that says why.
3. **Deep sleep** (not built yet): in Deep the board turns its radios off and wakes on a key press or a short timer
   window every 15 minutes, when it advertises for about 10 seconds so the phone can connect and sync; a 2-second
   press does the same on demand. It needs the battery-switch pin held through sleep (or the board switches itself
   off), and a fast-start path so that a key press starts recording in 1 to 2 seconds instead of the 8 seconds a full
   start takes.

Test the tiers without draining the battery with the development console: `tools/board_dev.py battery-set N`
pretends the charge is N% for about a minute and logs the mode it picks.
