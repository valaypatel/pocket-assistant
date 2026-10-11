---
version: alpha
name: Short-Circuit
description: A quiet pocket notebook for captured thoughts and their next steps.
colors:
  background: '#fffdf9'
  ink: '#15171b'
  muted: '#71675e'
  primary: '#f05b3d'
  accent-ink: '#a93c27'
  hero: '#f4e8d9'
  surface: '#f2f0eb'
  line: '#ebe5de'
  circuit: '#e8f0e9'
  danger: '#b34732'
typography:
  sans:
    fontFamily: 'Roboto, system-ui, sans-serif'
rounded:
  DEFAULT: '12px'
  panel: '16px'
spacing:
  page: '24px'
  section: '24px'
components:
  button:
    backgroundColor: '{colors.primary}'
    textColor: '{colors.ink}'
  panel:
    backgroundColor: '{colors.hero}'
    textColor: '{colors.ink}'
  navigation:
    backgroundColor: '{colors.background}'
    textColor: '{colors.accent-ink}'
  muted-label:
    textColor: '{colors.muted}'
  divider:
    backgroundColor: '{colors.line}'
  device-panel:
    backgroundColor: '{colors.circuit}'
  danger-action:
    textColor: '{colors.danger}'
  list-row:
    backgroundColor: '{colors.background}'
    textColor: '{colors.ink}'
---

# Short-Circuit design

## Overview

The approved full-app concept is a pocket notebook, with the voice recorder as its signature tool. The Android companion is used to capture a thought quickly, review a recording and its transcript, organize related notes, and approve useful actions. English UI; original and translated note text retain their scripts through Flutter's system font fallbacks. No Japan-market assumptions. Source: README.md, apps/short_circuit/lib and the user-approved complete redesign.

Runtime ownership: `apps/short_circuit/lib/ui/theme.dart` owns the palette (`Sc`), typography, `ScPanel`, buttons, rows, fields and navigation. This document mirrors accepted values; it does not generate code. Screens consume shared components. Functional state and consequences come from the existing recording, sync, groups, secure notes and backup modules.

## Colors

Preserve the cream, coral, charcoal and sage brand. Coral identifies capture; charcoal emphasizes a safe next action. Use dark ink on coral and dark coral on cream for readable controls. Sage identifies Circuit and positive connection state, accompanied by text. Muted text uses a darker warm gray for legibility. Do not use purple action links or introduce new decorative hues.

## Typography

System typography, with fallback for recorded languages. Titles: 34 logical pixels, weight 600, 1.08 line height, -1.4 tracking. Main reading text: 16 with generous leading. List titles: 14–16, weight 600. Supporting text: 12–14. Timers use tabular figures. Respect system text scaling; wrap headings, action bars and button labels instead of hiding controls.

## Layout

24-pixel page padding and section spacing. Main shell content has a 640-pixel reading limit on larger displays. Four persistent destinations: Home, Notes, Tasks, Settings. Capture is accessible above navigation in the three everyday destinations; choose Phone, Circuit or Identify song explicitly. Recording controls and playback remain available while browsing. Each page owns one scrollable body; forms and sheets account for the keyboard and safe areas.

## Elevation & Depth

Tonal summary panels, quiet divided list rows, no repeated floating cards. Reserve peach for the main summary and sage for device state. Native Material overlays own elevation and focus. Persistent chrome uses a subtle divider rather than a floating shadow.

## Shapes

Controls use 12-pixel radii; panels use 16. Round play controls and the physical device mark are intentional exceptions. Thin warm dividers organize content.

## Components

`ScIconButton` provides accessible names, tooltips, disabled/busy state and a minimum 48-pixel target. Expanded actions include visible text. `scDialogActions` uses Cancel plus the explicit outcome, with a danger tone for destructive actions. `ScActionBar` wraps on small displays. `ScSecretField` masks passphrases and provides a named reveal control. Material buttons, text fields, segmented controls, dialogs and sheets preserve native focus and keyboard behavior. Use `ScTile` for navigable note/provider rows, `ScRow` for settings, and `ScPanel` only for meaningful bounded context.

Notes search is local and immediate, with an explicit clear action. Source filters do not change stored data. Transcript, summary and translation are separate reading modes. Suggestions require deliberate approval. Chat is scoped to a note, group or all-notes context; no invented citations or live transcript. Loading uses a progress indicator; recovery preserves the original recording.

Lucide icons and existing brand/device painters remain canonical. Motion is restrained: Material press feedback and the existing recording morph. Honor system reduced-motion for any new transition. Do not loop decorative animation.

## Do's and Don'ts

- Keep source, processing state and consequences explicit.
- Preserve Android system permission and external calendar/provider handoffs.
- Keep all existing device, encryption, recording and backup behavior connected.
- Do not substitute sample content, fake waveforms or pretend playback for real data.
- Do not import the prototype's outdated deletion or automatic-sync copy: current app behavior wins.
