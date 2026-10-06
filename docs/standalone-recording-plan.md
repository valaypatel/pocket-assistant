# Standalone phone, watch, and widget recording

Draft for discussion — 6 October 2026. Confirmed choices are recorded below; remaining architecture and delivery details are proposals. This document plans work; it does not change application behavior.

## Outcome

People can install the phone app and record useful voice notes without owning Circuit. Android, iPhone, Wear OS, and Apple Watch feed the same notes experience. Circuit remains an optional capture device.

## Confirmed product decisions

- Release Android phone recording and the Android widget first; other platforms follow.
- Local-only storage; no cloud account or cloud note sync. Sending audio to the user's configured AI provider remains part of transcription.
- Watches record offline and sync to their paired phone later; no independent watch AI upload.
- Users supply their own AI API keys.
- Widget recording should start without opening the app, following initial permission setup. This is the preferred experience, not a requirement. If a platform makes it blocked or too hard, the agreed fallback is a widget that opens the recorder and starts recording there. Decided 6 October 2026.
- Watch scope is recording and sync status, without note browsing, playback, or transcript viewing.
- Recording controls include Record, Stop, Save, Discard, and Pause/Resume.
- No fixed recording duration limit. A long recording is stored and sent as an ordered series of one-minute parts that belong to one recording (see "Long recordings as one-minute parts"). Storage space, battery, and OS lifecycle still apply.

- Keep Android 9 / API 28 as the minimum supported version.
- Distribute through the existing Firebase App Distribution workflow.
- Available physical test devices: Android phone and iPad; no watches. Exact models remain to be inventoried.
- Test coverage across Android versions: use Firebase Test Lab (real devices in Google's data centers) for "installs, starts, recording service runs, permission screens work" on Android 9 and the newest version, plus automated tests across versions. Use the owner's phone for the widget tap and for real audio quality, because Test Lab cannot speak into a phone and its standard scan does not tap home-screen widgets. Board Bluetooth and Wi-Fi checks stay on the real phone and board. Check Test Lab's current free allowance before relying on it. Release notes state which behavior was proven on which version.
- Defer iPhone/iPad implementation to a later stage; eventually support both form factors. Watch delivery is also outside the first Android release.
- Encrypted backup/restore exists (PR #15, `lib/backup.dart`: passphrase-protected `CBK1` archive of notes, tasks, groups, chats, note keys and recordings). It is release-blocking in the sense that it must cover every new recording type, key and the parts model before each beta ships; with local-only storage it is the only protection on uninstall or a phone change.
- Explicit note deletion removes the phone copy and queues deletion of the source-device copy when it reconnects.
- Voice notes only; typed notes are out of scope.

## Remaining implementation checks

No further product questions block planning the first Android release. Inventory the Android test device and validate API 28 plus newer Android behavior. Backup/restore now exists; extending it for new recording types is part of each beta.

Later-stage decisions: Apple minimum OS versions, Circuit support at Apple launch, physical watch/iPhone test access, and watch-copy retention after successful sync. Until retention is chosen, do not automatically delete synced watch recordings.

## Current repository findings

- Flutter app currently has an Android platform project; iPhone and watch targets must be added.
- `lib/main.dart` owns much of note persistence, processing, Circuit state, and UI orchestration.
- `CircuitNote` already has an optional board ID, but lacks explicit recording source and originating device identity.
- `circuit/relay` method calls also cover playback and audio storage operations. These need separation or platform adapters.
- Android's manifest has Circuit relay permissions but no microphone recording permission or microphone foreground service.
- Existing encrypted Circuit audio uses CNT1 with board-controlled note numbers and keys. Phone/watch producers must not reuse its nonce scheme with potentially colliding IDs.
- Backup/restore was added after this plan was first drafted (PR #15). It loads each recording fully into memory, which will not scale to long recordings (Beta 2), and it does not yet know about phone-recorded notes, their separate key, or recording parts. `android:allowBackup` stays `false`; this in-app backup is the mechanism.
- Existing AI configuration uses user-provided provider credentials. Cloud accounts, cross-device backup, and managed billing are additional scope.
- The roadmap says iOS was deferred; update that direction after the launch scope is agreed.

## Long recordings as one-minute parts

Applies to every source (Circuit, phone, later watch). One recording is stored as an ordered list of parts of about one minute each. The person sees and plays one note.

- **Circuit:** while recording, the board closes the current encrypted file at each minute and carries on into the next, without losing audio at the join. Each part is an ordinary note file in the existing format. A small marker ties the parts to one recording (recording ID, part number, and whether recording has finished). Stop, or running out of card space, ends the last part early. The 600-second limit is removed; the card's free space becomes the limit.
- **Sync:** parts are sent one at a time, so a failed transfer repeats one minute, not the whole note, and each file is small enough for the board's memory.
- **Phone:** receives parts in any order and shows the note as "still arriving" until the board says the recording is finished and every part is present. It then joins the audio in order and plays it as one recording. Transcription also works part by part and joins the text, so the transcription split and the storage split are the same split.
- **Transcription method:** parts are transcribed in order, like a conversation. The AI provider's call has no memory between requests, so the app builds the conversation: each request carries the text already produced for the earlier parts (the most recent turns, as text, not audio) plus the next part's audio. The app saves each part's text as it finishes, so a failure repeats one part and a restart carries on from the last saved part. When all parts are done, the joined text goes through the existing review step once, on the whole note. Parallel transcription is a possible later speed-up, not part of the first release.
- **Board playback and delete:** playing a recording plays its parts in order; deleting it deletes all its parts.
- **Compatibility:** the encrypted file format and key handling do not change. Old single-file notes keep working as one-part recordings. Phone and watch recordings use the same parts model, so their code is shared.
- **Risks to test:** a gap or click at the join (the next file must be ready before the current one closes); losing power mid-recording (every finished part must survive); sync of a recording with a missing part (show it as incomplete, never silently shorter); a phone on an old firmware (it must still show single-file notes).

## Proposed architecture

Keep Flutter for Android/iPhone screens, note models, organization, and processing orchestration. Use native capture and lifecycle adapters where required. Use Kotlin/Compose for the small Wear OS app and Swift/SwiftUI for Apple Watch. Native home-screen widgets launch or control each platform's capture integration.

All capture sources feed one durable import path:

`phone / watch / Circuit → encrypted local audio → note repository → processing queue → transcript and enrichment → notes UI`

Introduce source-independent note IDs, source type, originating device ID, source recording ID, codec/duration metadata, encryption format/key reference, and independent capture/transfer/processing statuses. Preserve existing IDs, board IDs, audio, keys, chats, tasks, and timestamps during migration.

Use a versioned repository with atomic persistence and a durable job queue. Decide whether a transactional database is needed after inspecting the current persistence boundaries; do not rewrite unrelated app features. Native background receivers should save into a durable inbox that Flutter can reconcile without requiring a running Flutter screen.

Watch transfer protocol: stable recording ID, versioned metadata, file size/hash, encrypted payload, and acknowledgement only after the phone has durably stored and validated it. Retries must be idempotent. Keep the watch copy until acknowledgement, then apply an explicitly chosen retention policy. Do not claim immediate delivery: OS background scheduling controls timing.

Decided: phone and watch recordings use their own encryption key, separate from the one Circuit uses, and their own recording ID range that can never overlap the board's. Each producer (this phone, a later watch) has its own key and IDs. The same key is never used with the same ID twice, which is the rule that keeps this kind of encryption safe. The board's format, key, and old notes are untouched. A key is created on first use and kept in the phone's secure storage; the backup includes it, so a restored phone can still open its recordings.

Use platform secure key storage and per-producer key namespaces with collision-safe encryption. Preserve Circuit format compatibility. Prototype streaming encryption and interruption recovery before picking recording libraries; avoid silently introducing persistent plaintext recordings. Define trusted watch–phone key exchange and re-pairing behavior. Cloud sync is out of scope. Explicit deletions create durable tombstones keyed by source device/recording ID; retry until acknowledged and suppress re-import of deleted recordings. Delete only the requested recording, never shared encryption keys.

## Delivery phases and acceptance gates

### 0. Confirm scope and prove risky platform behavior

Check Android toolchains, signing, the existing Firebase distribution workflow, physical device availability, and candidate plugins compatible with API 28. Prototype direct widget recording without launching an activity after initial permission setup, screen-lock recording, pause/resume, and interrupted encrypted file recovery. Check long-recording memory usage and provider upload limits. Defer watch and Apple spikes to their respective stages. Estimate delivery after these spikes rather than promising dates now.

Do the widget test first, before any other work. Build a throwaway app with one widget button that starts a microphone recording service while the app is closed and the screen is locked. Run it on every Android version we can reach and record the result in a table (version, worked or blocked, reason). Android 12 and newer limit starting a microphone service from the background, so do not assume it works. If a version blocks it, or the workaround is too complex, use the agreed fallback for that version: the widget opens the recorder, which starts recording straight away. Note the result in the table; no further approval is needed.

Gate: a tested platform capability matrix and confirmed release boundaries.

### 1. Separate the note pipeline from Circuit

Extract note repository, capture interface, processing queue, and audio playback/storage adapters. Add source identity and migration. Make Circuit setup optional and request Bluetooth permissions only when a user connects hardware. Keep existing Circuit pairing, sync, playback, and AI behavior working.

Gate: a synthetic local recording imports and processes without pairing; old notes and encrypted files still load; duplicate imports create one note.

### 2. Android phone recording

Add microphone permission and a dedicated microphone foreground service, separate from the BLE relay. Add Record/Stop/Save/Discard/Pause/Resume and a visible recording notification with stop and pause/resume actions. Impose no application duration cap. Stream encrypted audio with bounded memory, preserve recoverable segments, and detect low storage before writes fail. Split long transcription jobs into provider-compatible segments with ordered transcript assembly and resumable retries. Store audio before scheduling AI. Restore pending work after app restart. Handle denied permission, calls/audio interruptions, storage exhaustion, repeated taps, and process termination with honest recovery status.

Gate: a fresh installation records and plays a note in airplane mode without Circuit or an API key; processing succeeds later when configured and online. No claim that force-stop permits continued recording.

### 3. Android widget

Add a compact Record note widget routed through the same recording coordinator. Preferred experience: after initial app setup grants microphone access, tapping the widget starts the recording service without opening the app. If permission is missing or revoked, direct the user through permission setup; do not silently fail or imply recording has begun. Validate background-start and microphone permission rules on each supported version. If a platform prevents this flow or it is too hard, use the agreed fallback: tapping the widget opens the recorder and starts recording immediately. Say in the release notes which versions use which behavior. Prevent duplicate sessions from repeated widget taps; keep displayed state consistent after save/stop.

Gate: cold-start, warm-start, permission denial, lock/unlock, and already-recording flows pass on physical devices.

### Later stage A. iPhone/iPad app and widget

Add iOS target, signing/configuration, native recording and playback adapters, protected storage, audio-session handling, and lifecycle-safe processing. Audit every Android method-channel call. Add WidgetKit quick capture, and evaluate AudioRecordingIntent plus the required recording Live Activity on supported OS versions. Validate direct recording; the open-recorder fallback is acceptable if direct recording is blocked. Circuit-on-iPhone support follows the agreed scope; do not promise Android relay parity.

Gate: standalone recording, offline save, playback, interruption handling, widget launch, and later AI processing pass on a real iPhone.

### Later stage B. Wear OS app

Create a focused native watch app: microphone onboarding, large Record/Stop and Pause/Resume controls, elapsed time, saved confirmation, pending/synced status, and retry. Add a Tile or complication shortcut. Persist encrypted recordings and transfer via Wear OS Data Layer using a file-capable mechanism. Keep AI credentials on the phone for the paired-phone design.

Gate: record with phone unavailable, restart the watch app, reconnect, and receive exactly one playable phone note. Test partial transfer and lost acknowledgement.

### Later stage C. Apple Watch app

Create a SwiftUI watch target with the same core capture and transfer states. Implement audio-session handling, local protected encrypted storage, and queued WatchConnectivity file transfer to iPhone. Add a complication/Smart Stack entry where supported. Use application-level durable receipt acknowledgements, not reachability alone.

Gate: disconnected recording and subsequent transfer succeed on a physical paired Apple Watch/iPhone, including retries and app restarts. Simulator tests alone cannot validate WatchConnectivity file transfers.

### 4. First Android release hardening (before later stages)

Run migration and Circuit regression suites. Test permission changes, low storage, no network, missing AI keys, API failures, audio interruption, clock changes, duplicate delivery, tampered files, and wrong keys. Check accessibility, battery use, startup latency, and privacy of widget text. Add diagnostics without recording contents or credentials. Verify the existing encrypted export/restore round-trips old Circuit notes, new phone recordings, metadata, groups, chats, and needed keys, including onto a fresh install. Test queued source deletion without resurrecting deleted notes. Prepare microphone/privacy disclosures, signed beta builds, and use the existing Firebase App Distribution workflow. Repeat relevant hardening for later platforms when implemented.

Gate: API 28 compatibility plus newer-version checks pass; Android recording, pause/resume, direct widget start, offline playback, later AI processing, backup/restore, and Circuit regression flows pass. Long recordings have bounded memory use and recoverable progress. Remaining OS limitations are documented. Apple and watch completion do not block this Android release.

## Explicitly out of scope for the first release

Cloud accounts/sync, managed AI billing, independent watch uploads, typed notes, iPhone/iPad implementation, and watch implementation. Long recordings are in scope. Flutter remains the shared phone-app foundation; later native watch apps pair Wear OS with Android and Apple Watch with iPhone.

## Release stages

Decided: ship in small betas through the existing Firebase App Distribution workflow, so each can be tested before the next starts.

1. **Beta 1: phone recording and backup.** Separate the note pipeline from Circuit (slice 2), record on the phone with Record/Stop/Save/Discard/Pause/Resume, save offline, play back, and transcribe with the existing flow. Includes extending the existing encrypted backup/restore to cover phone recordings and their key, because it is release-blocking for a local-only product. Phone recordings are capped at 10 minutes in this beta, to match Circuit today; the cap is lifted in Beta 2.
2. **Beta 2: long recordings.** One-minute parts on the phone, ordered conversation-style transcription, resumable retries, no fixed cap.
3. **Beta 3: Android widget.** Direct start if the widget test allows it, otherwise the open-recorder fallback.
4. **Beta 4: Circuit one-minute parts.** Firmware change, app joins the parts. Flash with the three-file method.

Later stages (iPhone/iPad, Wear OS, Apple Watch) follow after these. Each beta's backup must include every recording type added so far. The order of Betas 2 to 4 is a proposal and can change after Beta 1.

## Suggested implementation slices

1. Verify direct widget recording on supported Android versions.
2. Extract source-independent repository/capture interfaces and migrate existing notes safely.
3. Deliver encrypted Android recording with pause/resume, recovery, and bounded-memory storage.
4. Add the one-minute-parts model to the phone's note storage and transcription, with provider-aware retries and existing enrichment.
4b. Circuit firmware: record in one-minute parts, remove the 10-minute limit, and teach the app to join the parts. Flash with the three-file method so saved pairing and keys survive.
5. Deliver direct widget controls and permission/restart handling.
6. Extend the existing encrypted export/restore (`lib/backup.dart`) for phone recordings, their key and parts, with bounded memory, and implement source-aware deletion/tombstones. Backup must cover every note type added in earlier slices.
7. Complete physical-device and API-level regression checks; prepare Firebase beta.

Each slice should leave the app usable and retain existing Circuit functionality. Firmware changes are expected for long recordings on Circuit only (one-minute parts); the other slices need none. Protocol inspection may show more are needed for reliable deletion or sync acknowledgements.

## Official references

- [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)
- [Android foreground service restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Wear OS Data Layer](https://developer.android.com/training/wearables/data/overview)
- [Wear OS binary data transfer](https://developer.android.com/training/wearables/data/sync)
- [Apple watchOS apps](https://developer.apple.com/documentation/watchos-apps/)
- [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity)
- [Apple queued file transfer](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
- [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)

These references support platform constraints; architecture and phase ordering above are project proposals.
