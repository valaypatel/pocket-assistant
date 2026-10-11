# Note encryption

New notes recorded on Circuit are encrypted on the board as they are recorded.
The sync sends the encrypted file as it is, the phone keeps it encrypted, and the
app opens it only when you play, transcribe or identify it.

## The one rule

**Nothing here ever deletes a note or a key.** A pairing change adds a key; it does
not remove one. A note stays readable by the board for as long as it exists, and by
a phone that has its key. A newly paired phone is given only the current key, so it
cannot read notes sealed with an older one, and they are not erased either.

## How it works

1. **The key.** The first time Circuit is paired it makes a random 256-bit key and
   keeps it in its flash. A board that was already paired makes it on first start.
   A board with no key records nothing, because no phone could read the note.
2. **Handing it to the phone.** The app sends `@sec-hello` and Circuit answers
   `@sec-key` with the key. Both characteristics require an encrypted, bonded
   Bluetooth link, so the key never crosses the air in the clear. The phone stores
   it in Android's Keystore-backed secure storage, under the key's id.
3. **Recording.** Audio is sealed in 4 KB chunks with AES-256-GCM as it is recorded
   (`firmware/CircuitBleDisplay/main/circuit_crypto.h`). The SD card only ever holds
   ciphertext.
4. **Sync.** Wi-Fi (HTTPS, pinned certificate, token) and the Bluetooth fallback both
   send the file as stored. The board never decrypts a note for the phone.
5. **On the phone.** The file is kept as received (`.cnote`). The app opens it in
   memory (`lib/secure_notes.dart`); an encrypted note is played from memory, so no
   plain audio file is written. The notes list, tasks and chats are stored sealed
   with a separate key in secure storage, and Android backup of app data is off.

Older notes are untouched. A plain `.wav` from before this change stays on the card
and on the phone exactly as it was, and still syncs and plays.

## File format (CNT1)

All integers are little-endian.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `CNT1` |
| 4 | 1 | version (1) |
| 5 | 1 | reserved (0) |
| 6 | 2 | header length (28) |
| 8 | 4 | key id |
| 12 | 4 | note id |
| 16 | 4 | sample rate |
| 20 | 2 | channels |
| 22 | 2 | bits per sample |
| 24 | 4 | chunk size (4096 on the board) |

Then chunks of `chunk size` bytes of audio, each followed by a 16-byte tag; the last
may be shorter. The cipher is AES-256-GCM with the notes key:

- **nonce** = note id (4 bytes) then chunk number (8 bytes). Note numbers only grow
  and are never reused, so a nonce is never used twice under one key.
- **AAD** = the 28-byte header then the chunk number (8 bytes), so a header cannot be
  changed and chunks cannot be reordered or moved between notes.

The audio is mono 16-bit PCM; the app rebuilds a WAV around it. The reference
implementation is `docs/security/reference/note_format.py`, which also writes
`test-vectors.json`. The board checks itself against those vectors at every start
(and refuses to record if that fails), and the app's tests open the same files, so
the two implementations are held to the same bytes.

## Moments (`.MOM`)

A tap on the lower key during a recording adds a Moment, a bookmark. Each one-minute part
that has any gets a small file next to it on the SD card, `N0000141.MOM`, holding the
Moments' offsets in milliseconds from the start of that part (pauses are not counted).
It is an ordinary CNT1 file sealed with the notes key, so the card still holds only
ciphertext. Differences from an audio note:

- the **note id in the header is the part's note number OR `0x80000000`**. The nonce is the
  note id plus the chunk number, so without the flag the file's first chunk would reuse the
  audio's nonce under the same key. Note numbers stay far below 2^31, so a flagged number
  can never meet a real note. A reader must check that the header names the note the file
  belongs to, so a Moments file moved to another note does not open.
- sample rate, channels and bits are all 0.
- the payload is a `u32` count (at most 120) then that many `u32` offsets, in recording order.

The firmware writes and reads it in `circuit_moments.h`, and removes it with its note. The
sync does not send it yet, and the app does not show Moments yet. The reference
implementation and test vector for this file follow with the app side.

## Recordings made on the phone

A voice note recorded on the phone itself uses the same format and the same rules, with
its own key and its own note numbers, so it never shares a key with Circuit and the
"one note number per key" rule above holds. The key is made on first use and kept in the
same secure storage as Circuit's keys (under `note_key_<id>`), so backup and restore treat
it like any other.

A long recording is stored as parts of about a minute, each an ordinary note file with the
next note number (`phone-note-<n>.cnote`, `<n>+1`, ...). A new recording starts at the
larger of "last number used + 1" and the seconds since 1 January 2026, and a recording of
N parts takes at least 60 x N seconds, so numbers are not reused even if the saved counter
is lost. Audio is sealed as it arrives, so a crash keeps every finished part and all but
the last fraction of a second of the one in progress. The Kotlin writer
(`NoteSealer.kt`) is checked against the same test vectors as the board and the app.

## The home-screen widget

The widget starts a phone recording with the app closed, so the recorder needs the phone's
recording key without the app. The app hands it over when it opens, and the recorder keeps its
own copy sealed with an AES-256-GCM key that lives in the Android Keystore and never leaves it
(`PhoneKeyStore.kt`), the same protection the app's own copy has. It is not readable without
the Keystore, and backup and restore still carry the key as before. The recorder also picks
note numbers itself with the same rule as the app (`PhoneNumbering`), so a recording made with
the app closed can never reuse a number.

## What this protects against

- **A lost, stolen or read SD card.** It holds only ciphertext.
- **Someone taking files off the phone, or a backup of the app.** The notes and
  recordings are ciphertext, and the key stays in the Keystore.
- **Eavesdropping on sync.** The files are encrypted, and travel inside an encrypted
  link as well.
- **Tampering.** A changed, swapped or wrong-key chunk is rejected, not played.

## What it does not protect against

- **Someone holding the whole board who can read its flash.** The key is in the
  board's flash, which is not encrypted. Closing that needs ESP32 flash encryption,
  which burns eFuses permanently and can brick the board if set up wrongly.
- **A rooted or compromised phone.**
- **Plaintext that leaves on purpose.** Audio goes to Gemini when you transcribe, and
  song clips go to the music service, both over HTTPS.
- **The end of a note.** There is no end marker, so cutting a note short cannot be
  detected (a recording cut off by power loss is played up to where it stopped).
- **Notes recorded before this change.** They stay plain, by design.
- **Metadata.** Note numbers, times and sizes are visible in file names.
- **Pairing.** The Bluetooth passkey is still fixed for each start, so someone in
  range could try to guess it. Hardening that is a separate change.
- **Losing the key.** If the board's flash is erased, notes sealed with its key can
  only be opened by a phone that already holds that key.
