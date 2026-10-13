# Short-Circuit app: redesign plan (every screen)

Status: proposal for approval, no app code changed. Written 13 Oct 2026 from a code audit of `apps/short_circuit`. The owner said "UI needs fix" without a list, so the problems below come from the code, not from screenshots (the phone was locked, so the real screens could not be captured). Section 1 should be checked against what the owner actually sees; anything missing from it should be added before building.

## 1. Audit: what is wrong today

| # | Finding (evidence) | Why it matters |
|---|---|---|
| 1 | No dark mode; no dynamic color (`theme.dart`, light-only `Sc` palette) | Glare at night; ignores a system setting most people use |
| 2 | Tokens cover colors only. About 96 inline `fontSize` values (37 are 12 or smaller, some 11), about 44 inline radii (10 to 20, 99) and about 190 inline spacers | Inconsistent look, small hard-to-read text, every change touches many files |
| 3 | 25 hard-coded colors outside the palette; `Sc.faint` equals `Sc.muted` | Palette cannot be changed or themed safely |
| 4 | No onboarding. Pairing exists only on the Circuit device page | A first-time user has no guided path to the one thing the app is for |
| 5 | Settings stacks 8 sections and mixes everyday items with developer items (test mode, diagnostics, "send a test report") | Hard to find things; developer switches are one tap from a normal user |
| 6 | Hidden features: multi-select by long press, swipe to delete on notes and tasks, hidden Wi-Fi as a separate page | People cannot discover them; swipe delete has no undo cue |
| 7 | Jargon and several names for one idea: Transcribe, AI review, Ask, "Review new notes", "Your providers", "Moments" explained only in a long caption | Users must learn the app's vocabulary |
| 8 | Button styles mixed (`ScButton`, `ScIconButton`, `FilledButton`, `TextButton`, `ScActionBar`) | Primary action is not consistently recognisable |
| 9 | Missing states: Notes empty list, empty search result, Bluetooth and notification permission denied (status text only, no Settings link), AI service unavailable | Dead ends with no next step |
| 10 | Tab content is swapped in place (`switch (_page)`), so scroll position and filters are lost on tab change | Feels like losing your place |
| 11 | Retry actions repeated in the sync banner, the tile and the detail page; destructive device actions (resend, clean SD card) live in dialogs on the Circuit page | Duplicate controls; risky actions are easy to miss or hit |
| 12 | No localization, no RTL check; Hindi and Gujarati notes are the owner's real content | UI cannot follow the owner's language; Devanagari text needs line height checked |
| 13 | Font scaling not handled (nav label shrinks with `FittedBox`) | Large-text users get clipped or tiny labels |
| 14 | No golden or visual tests for any screen | Redesigns cannot be checked for regressions |

Good things to keep: `ScIconButton` already requires a tooltip and enforces a 48 dp target; the microphone permission flow has a Settings link; the sync-failed banner has a retry; the capture entry is always one tap away.

## 2. Users and context

Primary user: the owner and early testers who record short thoughts by voice, often one-handed or while moving, then review, search and act on them later. The app is encrypted and private; losing or exposing a note is the costly mistake. Connectivity varies (Circuit over Bluetooth or Wi-Fi, phone recordings offline, AI needs the internet). Notes are in Hindi, Gujarati and English, often mixed. Emotional state: in a hurry when capturing, calm when reviewing. Success action: capture a note and trust that it arrived. Recovery: a clear retry or fix for every failed step.

## 3. Principles

1. **Capture first.** Starting a recording is one tap from every top-level screen.
2. **Honest status.** Every note shows where it is (on Circuit, syncing, on this phone, transcribed) in plain words, and failures say what to do.
3. **One main action per screen**; the rest goes under "More" or a sheet.
4. **No hidden gestures.** Every swipe or long press also has a visible control, and delete can be undone.
5. **Plain words.** One name per idea; "Moments" stays (it matches the board) with a bookmark icon and a one-line explanation where it first appears.
6. **Tokens for everything:** type, spacing, radius, color with light and dark values.
7. **Everyday settings up front, developer settings out of sight.**

## 4. Information architecture (needs approval, see section 12)

Current tabs: Home, Notes, Tasks, Settings. Proposed tabs: **Notes**, **Tasks**, **Circuit**, **Settings**.

- **Notes** merges Home and Notes: a status strip (Circuit and sync), a "Needs attention" group when something failed, then notes grouped by Today, Yesterday and so on, search at the top, capture button anchored bottom-right.
- **Circuit** becomes a tab instead of being buried: connection, battery when known, pairing, Wi-Fi, sync history, and the risky actions (resend, clean SD card) behind a clear "Device tools" section with confirmation.
- **Settings** keeps: AI (key, service, Use Moments, auto-transcribe, auto-review), Backup, Privacy, You, About. A **Developer** row at the bottom holds test mode and diagnostics.
- Tabs keep their scroll position and filters (an `IndexedStack`-style shell).
- **Onboarding** (new, first run only, skippable): welcome, permissions with reasons (Bluetooth, notifications, microphone), pair Circuit, optional AI key. Each step can be done later from its home screen.

## 5. Screens, every one

| Screen | Redesign |
|---|---|
| Notes (Home + Notes) | Section 8 wireframe. Empty state teaches the first action; search has its own empty state |
| Note tile | Title, one line of text or status, then time and length (already built) and a source badge; one trailing play button; no inline retry buttons (retry lives in the detail page and the attention group) |
| Note detail | Section 8 wireframe: play bar first, Moments as chips under it, tabs Summary / Transcript / Translation, suggested actions, then "More" (Ask, Transcribe again, AI review, Delete) |
| Recording view and sheet | Large elapsed time, level or state indicator, Pause and Stop as the only two controls, a visible "Moment" button on the phone recorder too, discard behind a confirm |
| Capture sheet | Three big rows with icons and one-line descriptions; remembers the last choice |
| Tasks | Checkbox rows, visible "Add" button, swipe-to-delete plus an overflow "Delete", undo snackbar, empty state |
| Chat (Ask) | Keep structure; larger type, visible suggested questions, consistent error row with retry |
| Song page | Same card and button system; clear "no match" state with "Try again" |
| Groups (sheet, picker, page) | Selection mode entered by a visible "Select" button; groups shown as cards with counts; rename and delete in an overflow menu |
| Circuit tab | Section 4; status card, Pair or Repair as the one primary action, Wi-Fi as a row, tools under a labelled section |
| Wi-Fi setup and hidden Wi-Fi | One flow: scan, choose, enter password; "Hidden network" is a toggle on the same screen |
| Settings, AI service, Gemini, Backup, Music | Same row component, grouped, with plain captions; each opens a detail screen with one primary action |
| Dialogs | One destructive-confirm pattern (title states the consequence, red confirm, cancel); delete note keeps the "phone only / everywhere" choice as a two-option sheet |
| Now-playing bar and status overlay | One status area: transient messages as a snackbar with an action; persistent problems as a banner in the screen they affect; now-playing stays above the nav |
| Onboarding and permission prompts | New, section 4 |

## 6. Design system (new, replaces inline values)

- **Type scale** (all scale with the system font size): display 28/34, title 22/28, subtitle 18/24, body 16/24 (transcripts 17/26 for Devanagari), label 14/20, caption 13/18. Nothing below 12, and nothing essential below 14.
- **Spacing** (4-point scale): 4, 8, 12, 16, 24, 32. **Radius:** 8 (chips), 12 (inputs, rows), 16 (cards), pill. **Elevation:** none, with 1 dp borders; one shadow level for sheets.
- **Color roles** with light and dark values: background, surface, surface-variant, outline, text, text-muted, accent (the existing orange), on-accent, success, warning, danger. Every text and control pair is checked to 4.5:1 (3:1 for large text and icons) when the tokens are written, with a test that fails if a pair drops below.
- **Components:** keep the `Sc*` names, rebuilt on the tokens: `ScButton` (primary, tonal, text, destructive), `ScRow`, `ScTile`, `ScChip`, `ScSheet`, `ScBanner`, `ScEmpty`, `ScSkeleton`. Remove direct use of `FilledButton`, `TextButton` and `Color(0x…)` outside the theme.
- **Dark mode** follows the system. **Strings** move to `gen-l10n` with English as the base so Hindi and Gujarati UI text can be added later (translation reviewed by a native speaker, not machine output).

## 7. States (the ones that change)

| Screen | State | User sees | Recovery |
|---|---|---|---|
| Notes | Empty | "No notes yet. Tap the mic or press Circuit's button." | Capture button |
| Notes | Search, no result | "Nothing matches 'x'." | Clear search |
| Notes | Sync failed | Banner: what failed, last success time | Retry; "Why?" opens the Circuit tab |
| Notes | Circuit not connected | Muted status strip, notes still usable | "Connect" |
| Detail | No audio on phone yet | Play disabled with "Not on this phone yet" | "Sync now" |
| Detail | Transcribe failed | Inline message with the reason | "Try again", "Check AI service" |
| Any | Bluetooth or notifications denied | Explains what stops working | "Open Settings" |
| Any | AI key missing | Row shows "Add a key" | Link to AI settings |
| Loading | List and detail | Skeleton rows, not a spinner on a blank page | none needed |

## 8. Wireframes (standard compact, 390 dp)

```text
NOTES                               NOTE DETAIL
┌──────────────────────────┐        ┌──────────────────────────┐
│ Notes            [search]│ P0     │ ‹ Back             [more]│ P0
├──────────────────────────┤        ├──────────────────────────┤
│ Circuit connected · synced│ P0    │ Title (2 lines max)      │ P0
│ 2 need attention  [View] │ P1     │ Today · 16:40 · 0:49     │ P1
├──────────────────────────┤        ├──────────────────────────┤
│ TODAY                    │        │ ▶ 0:00 ───────────── 0:49│ P0 [sticky]
│ ▢ Title        ▶         │ P0     │ ◆0:09 ◆0:23 ◆0:42        │ P1 Moments
│   16:40 · 0:49 · Circuit │        ├──────────────────────────┤
│ ▢ Title        ▶         │        │ Summary | Transcript | ...│ P0
│ YESTERDAY                │        │ text (scroll)            │
│ ▢ ...                    │ [scroll]│ Suggested actions        │ P1
├──────────────────────────┤        │ [Approve] [Dismiss]      │
│ Notes Tasks Circuit More │ [sticky]│ More ▾ Ask · Redo · Delete│ P3
│                    (🎙)  │ capture └──────────────────────────┘
└──────────────────────────┘
```

Small compact (320 dp): status strip collapses to an icon and one line; Moments chips scroll horizontally; capture button stays reachable. Large text: rows grow in height, nothing truncates a title (two lines then ellipsis), the capture button never overlaps the last row (list gets bottom padding).

## 9. Interaction contracts (8)

1. **Capture:** tap mic, bottom sheet if more than one source, else start. Feedback: recording view opens within 300 ms; announces "Recording started". Must not lose audio if the app is backgrounded.
2. **Open note:** tap row; detail opens with play bar ready; announces title and length.
3. **Play from a Moment:** tap chip; playback starts at that time across parts; announces "Playing from 0:23".
4. **Retry sync:** tap Retry; button shows progress; success removes the banner, failure keeps it and adds the reason. Must not start a second sync while one runs.
5. **Delete note:** overflow, then a sheet with "This phone only / Phone and Circuit"; after delete an undo snackbar for 6 seconds. Must not delete from Circuit without the second choice.
6. **Select and group:** "Select" button, checkboxes, "Group" action bar; Back exits selection.
7. **Device tools (resend, clean SD card):** confirm sheet states the effect and count; destructive button is red; cancel is the default focus.
8. **Permission denied:** inline explainer with "Open Settings"; returns and rechecks when the app resumes.

## 10. Accessibility contract

- Every control MUST have a semantic label naming its outcome; icon-only buttons MUST have tooltips (already enforced for `ScIconButton`).
- Targets MUST be at least 48 dp with spacing; swipe actions MUST have a visible alternative.
- Status MUST NOT rely on color alone (icon plus text for synced, failed, offline).
- Text MUST scale to 200% without clipping a title or hiding the capture button.
- Focus MUST move to a sheet or dialog when it opens and back to the trigger when it closes.
- Motion MUST be reducible: no required animation; the recording indicator has a static state.
- Contrast MUST pass 4.5:1 for text, with a test.

## 11. Delivery, verification and risks

Build in this order; each step is its own PR, merged when checks pass:

1. **Tokens and theme:** type, spacing, radius, color roles, dark theme; no visible change except where values are corrected. Adds the contrast test.
2. **Components** rebuilt on tokens; remove direct `FilledButton`, `TextButton` and raw colors.
3. **Notes** (merged Home + Notes), tile, empty and search states, attention group, preserved tab state.
4. **Note detail** and Moments chips; **recording view** and capture sheet.
5. **Circuit tab** and Wi-Fi flow; **Settings** and the Developer split.
6. **Tasks, Chat, Song, Groups,** dialogs and status area; **onboarding** and permission states.
7. **Strings to gen-l10n** (English), then optional Hindi and Gujarati.

Verification per step: `flutter analyze`, `flutter test`, new **golden tests** of each redesigned screen at 320, 390 and 430 dp, at 100% and 200% text, light and dark, which I can render and inspect without the phone; then a real-phone check once the phone is unlocked. Unverified until then: real-device look, TalkBack behaviour, and contrast of the existing orange and green on the chosen surfaces (computed in step 1, not assumed).

Risks: the navigation change touches `main.dart` (3,300 lines) and every test that assumes the current tabs; the plan keeps each step shippable so the app never sits half-redesigned for long. Moving 190 spacers and 96 font sizes onto tokens is mechanical but wide.

## 12. Decisions needed before building

1. Navigation: merge Home into Notes and make Circuit a tab (recommended), or keep the four current tabs.
2. Add dark mode following the system (recommended), or stay light only.
3. UI language: English with strings extracted now (recommended), or also build Hindi and Gujarati UI text in this round.
4. Anything the owner sees on the real screens that is not in section 1.
