# Short-Circuit UI contract

## Sources

- `README.md`: companion-app purpose and platform.
- `docs/security/README.md`, `apps/short_circuit/lib/secure_notes.dart`: encrypted note lifecycle.
- `apps/short_circuit/lib/main.dart`, `board_parts.dart`, `phone_recording.dart`: current sync, pairing, audio and parts behavior.
- `apps/short_circuit/lib/groups.dart`: organization and group-context limits.
- `apps/short_circuit/lib/backup.dart`: archive format, passphrase validation and additive restore.
- `apps/short_circuit/lib/ui/detail_pages.dart`: suggestion approval and calendar handoff.

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
| --- | --- | --- | --- | --- |
| Navigation | `_ScPages._buildShell`, `ScNavBar` | Existing page enum and back handling | Home/Notes/Tasks/Settings; device and group children | Widget and group tests |
| Selection | Groups selection state | `groups.dart` | Explicit selected-note IDs | groups_test.dart |
| Select/Listbox | Material popup/segmented controls | Flutter and feature state | Group menu, backup mode | Widget tests |
| Date | Existing calendar handoff | Reminder extraction and confirmation | Suggested event or task fallback | note_page_test.dart |
| Form | Material TextField, ScSecretField | Feature validation | Settings, edit, backup, network | Backup and note tests |
| Scrollbar | Flutter ScrollBehavior | One body scroll owner | Main shell, detail, keyboard-aware sheets | Narrow layout tests |
| Toast | ScaffoldMessenger | Existing feature outcome | Success/error | Existing tests |
| CRUD | Feature callbacks and persistence | Existing modules listed above | Notes, groups, tasks | Regression suite |

## Workflow and state

Capture opens an explicit source chooser. Phone recording works without Circuit. Device capture requires a connected Circuit. Existing microphone permissions, pause/resume, interruption, discard confirmation and part assembly remain intact. Active recording and playback provide controls while navigating.

Notes retain local query and source filters while the widget remains alive. Clear search updates immediately. Bulk grouping acts only on selected IDs. Deleting a group keeps its notes; removing a note from a group does not delete it. Note deletion follows current implementation and confirmation copy, not the older prototype's device-deletion assumption.

A note opens with summary when present, otherwise transcript. Reading modes do not alter the saved text. Editing calls the existing save callback. Suggestion approval names the task or event consequence. Failed transcription/review remains retryable; unavailable actions explain their prerequisite. Chat preserves the question on failure and exposes retry.

Backup and restore have separate modes. Busy operations cannot be submitted twice. Passphrases stay masked by default. Archive creation excludes API keys. Restore adds missing content and skips duplicates; it never replaces existing data. Inline feedback remains readable after an operation.

Success feedback names the action. Cancel/back returns to the originating context. Destructive actions use app-owned confirmation; external calendar and music-provider actions preserve platform handoff. No new backend, security, retention or permission behavior is introduced by this redesign.

## Accessibility and layout

Use semantic Flutter controls, visible labels for consequential actions, 48-pixel touch targets and system text scaling. Wrap long actions rather than overflow. Narrow screens and keyboard-open forms must retain reachable controls. English interface; user content supports system script fallback. Existing device status and recording-state colors always have an accompanying label or accessible name. Screens must not claim unsupported dark mode or hardware verification.
