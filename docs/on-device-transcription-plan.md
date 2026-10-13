# Plan: Circuit transcribes and reviews notes on its own

Status: plan, nothing built yet. Decisions made with the owner (13 Oct 2026):

- **When:** any time the board is idle and has Wi-Fi (not only on USB, not only when the phone is away).
- **What:** the board does both steps, the transcript and the AI review (title, summary, tags, suggested actions, English translation). The app shows the board's results and can redo either one.
- **Default:** off. The person switches it on in the app, knowing that audio goes from Circuit straight to Google and that the key lives on the board.
- **Provider:** Gemini (the app already uses it, so one key and the same prompts).

## What it changes

Today the board never decrypts audio for anyone. With this feature the board decrypts a note **in memory**, sends it over TLS to Gemini, and keeps the answer encrypted on the card. Two things become true that are not true now, and `docs/security/README.md` must say so:

1. Decrypted audio leaves the board (to Google, over TLS, only for notes while the feature is on).
2. The Gemini API key is stored on the board in flash. NVS is not encrypted on this board, so anyone holding the device can read it. Use a restricted key with a low quota; the app offers "forget key".

Nothing is ever written to the card in the clear.

## Design

### Board
- **Key and switch from the app:** a new bonded-BLE command, `@ai-config`, carries the on/off switch, the key and the model name. Stored in NVS next to the Wi-Fi settings. `@ai-forget` wipes it. The key is never logged.
- **Idle scheduler:** a task looks for notes with audio but no transcript, one at a time, oldest first. It runs only when not recording, not playing, no sync session open, Wi-Fi up and internet answering (the board already pings). Failures back off (1, 5, 30 minutes) and stop after a few tries, with a marker so the app can say "Circuit could not transcribe this".
- **Gemini call:** `esp_http_client` over TLS with the certificate bundle. The request body is streamed: JSON prefix, then a 44-byte WAV header and the PCM, base64-encoded 3 KB at a time straight from the decrypted chunks, then the JSON suffix. One-minute parts are about 1.9 MB of audio, so about 2.6 MB on the wire; at roughly 60 KB/s that is about 45 seconds per part. The prompt is the app's prompt, with the part context (the text of the part before) and the Moments times, so a long recording reads as one.
- **Review call:** after the last part of a recording is transcribed, the joined text goes to Gemini with the app's review instructions, as JSON, and the answer is checked (valid JSON, known fields, sane lengths) before it is kept.
- **Storage:** two small sealed files per note, in the existing CNT1 envelope with their own domain flags so a nonce is never reused: `N0000141.TRN` (the transcript, one per part) and `N0000141.REV` (the review, on the first part of the recording). Note-id flags: Moments `0x80000000`, transcript `0x40000000`, review `0x20000000`. Documented in `docs/security/README.md`, with reference code and test vectors in `docs/security/reference/` like Moments.
- **Sync:** `GET /transcript/<id>` and `GET /review/<id>` next to `/moments/<id>`, empty body when there is none. The app asks once per note, stops asking after the first failure so an older board is not given bad attempts.
- **Memory:** internal RAM is tight (the sync server already drops to about 15 to 25 KB free). TLS buffers go to PSRAM (`CONFIG_MBEDTLS_EXTERNAL_MEM_ALLOC` is already on). The transcription task never runs alongside a sync, and is measured with the existing heap log before it is allowed in.
- **Size:** `esp_http_client` plus the certificate bundle and JSON handling should add roughly 0.2 to 0.35 MB; the app is 2.08 MB of a 3.2 MB slot. Measured, not assumed, in the first step.
- **On the board's screen:** nothing new in the first version except a small "transcribing" state on the dev console. A title on the e-paper is a later idea.

### App
- **Settings:** "Transcribe on Circuit" (off by default) with a plain warning about the two points above, the Gemini key sent to Circuit over the bonded link, and "forget key on Circuit".
- **Sync:** fetch `/transcript` and `/review` like Moments; keep as `circuit-transcript-<id>.ctrn` and `circuit-review-<id>.crev`; remove with the note.
- **Using them:** when the board's transcript exists, the app uses it and does not call Gemini itself (status "Transcribed on Circuit"). When the board's review exists, it fills the title, summary, tags, translation and suggested actions the same way the app's own review does. "Transcribe again" and "Run AI review again" in the app still work and replace the board's result.
- **Fallback:** if the board has nothing (feature off, failed, older board), the app behaves exactly as today.

## Steps, in order, each ending with the quick regression and a real-device check

1. **Foundation:** esp_http_client + TLS on the board; `@ai-config` from the app; measure size, internal RAM and one call of Gemini with a small text prompt. No audio yet.
2. **One part, transcript only:** stream a decrypted part to Gemini; dev command `transcribe N`; seal the result as `.TRN`; vectors + reference code; dev command to read it back. Check with the same Hindi note used for the app (Devanagari, Moments markers).
3. **Idle scheduler and retries:** automatic, one note at a time, with back-off and the "could not" marker.
4. **Parts and context:** long recordings, the part before as context, Moments times, joined text.
5. **Review on the board:** second call, validated JSON, sealed `.REV`.
6. **Sync and app:** endpoints, app settings, using the results, tests on both sides.
7. **Security doc, plan status, full regression once.**

## Risks and open points

- **Time and battery:** about 45 s of Wi-Fi per minute of audio, plus the model's time. Acceptable on USB; on battery it needs a measurement (no battery to test with today).
- **Quota and cost:** every note now costs two Gemini calls without the phone being involved. A per-day cap on the board is cheap insurance.
- **Prompts live in two places** (Dart and C++). Keep one source: the app sends the prompt text to the board with `@ai-config` (versioned), so a prompt fix never needs a firmware release.
- **Gemini changes or errors:** the board must treat any bad answer as a failure to retry, never as a transcript.
- **Hindi/Gujarati accuracy** is the model's; the prompt already keeps each language in its own script (fixed 13 Oct 2026).
- **Key exposure** is accepted as described above; a restricted key is the mitigation.

## Not in this plan

Voice questions, spoken answers and briefings on the board; the lower-button agenda screen; OTA updates. They come after this and do not depend on it.
