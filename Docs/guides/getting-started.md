<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Getting Started

## Windows and tabs

- **New Local Window** — ⌘N — opens a shell on this computer, even when a remote workspace is active.
- **New Window on [connection]** — File menu — opens another window in the active remote workspace.
- **New Tab** — ⌘T
- **New Window with Profile** — File ▸ New Window with Profile ▸ *(name)* — opens a window
  with a saved theme/font/spacing preset (see [Tabs, Splits & Windows](tabs-splits-and-windows.md#profiles)).
- **Close** — ⌘W — closes a split pane first. For local sessions, it then closes the
  tab or window, asking before ending a running process. For a remote tab's last
  pane, it offers **Close Window** (all tabs and sessions in that host window),
  **Detach from Workspace**, or **Cancel**. See [remote window actions](tabs-splits-and-windows.md#window-menu).
- **Select a tab** — ⌘1 … ⌘9 (⌘9 jumps to the last tab when there are more than nine).
- **Full Screen** — ⌘↩ (or ⌃⌘F).

Each tab is an independent shell. Tabs use native macOS window tabbing, so you can also
tear a tab out into its own window by dragging it.

## The Settings window

Open **Settings** with ⌘,. The sidebar contains these categories; use search to find a control by name.

<!-- settings-sidebar:start -->
| Category | What you can change |
|---|---|
| **Appearance** | Background, theme mode, color space, opacity, command palette |
| **Fonts** | Family, size, weight, spacing; Font Features, Fallback Fonts, Text & Graphics |
| **Cursor** | Shape, blinking, opacity, movement |
| **Windows & Tabs** | Window behavior, pane title bars, content insets, title composition |
| **Selection & Clipboard** | Selection modifiers, copying, paste confirmation |
| **Mouse & Trackpad** | Pointer, scrolling, links |
| **Keyboard** | Key bindings, option-key behavior, macros |
| **Sessions** | Session persistence, profiles, tags |
| **Terminal** | Scrollback, encoding, terminal identity, vector graphics, platform overrides |
| **Notifications** | Bell and program notifications |
| **Accessibility** | Visual accessibility adjustments |
| **Privacy & Security** | Secure Keyboard Entry, clipboard access, agents |
| **Software Update** | Whether Ubiquitty checks for new versions once a day |
<!-- settings-sidebar:end -->

Themes is a detail page under Appearance; Profiles is under Sessions. Experimental
session restoration is in Sessions ▸ Session Persistence.


Use Settings search to jump to a control, including font specifications, fallback
ranges, and import actions. A result opens folded controls and highlights its target.

A section with customized scalar settings has a **Reset Settings** menu. Reset one
setting or the section to preview the change, then confirm. Reset removes the override
from the file; platform settings and named profiles retain their own values.

## The config file

Everything lives in `~/.config/ubiquitty/config.toml`. Settings writes to it; you can also
edit it by hand via **Edit Settings File…** (it opens in your `$EDITOR` / default app).
Ubiquitty watches the file and **live-reloads on save** — no restart needed.

The file uses TOML sections like `[appearance]`, `[font]`, `[security]`, `[experimental]`,
plus repeatable `[[themes]]` and `[[profiles]]` blocks. Because Settings and the file are
two views of the same store, you can mix and match freely.

## Inspector

**Show Inspector** (⌘I) opens a panel with live details about the focused session —
timing, cursor state, working directory, and the foreground process chain.

## Where to go next

- Make it look right: **[Appearance & Fonts](appearance-and-fonts.md)**.
- Work with multiple shells at once: **[Tabs, Splits & Windows](tabs-splits-and-windows.md)**.
- Get prompt-aware navigation and command-output selection: **[Shell Integration](shell-integration.md)**.

The Profiles page can filter by name or displayed settings. Click a profile to
edit it; its action menu contains Duplicate, Export, and Delete. Deleting asks
first and is unavailable while a child profile, exact profile tag rule, open
terminal window, or saved workspace refers to it. Update those references first.
