<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Tabs, Splits & Windows

## Tabs

- **New Tab** — ⌘T. Each tab is an independent shell, grouped with native macOS window
  tabbing (drag a tab out to make it its own window).
- **Select a tab** — ⌘1 … ⌘9 (⌘9 = last tab when there are more than nine).
- **Shortcut hints** — Settings ▸ Windows & Tabs ▸ Show Shortcut Hints overlays the ⌘-number on each tab.
- **Rename** — File ▸ Rename Tab… (⌘⇧I) sets a custom title for the window/tab.

## Split panes

Split a tab into multiple shells that share the window:

- **Split Right** — ⌘D (a new pane to the right)
- **Split Down** — ⌘⇧D (a new pane below)
- **Close Pane** — ⌘⇧W
- **Expand / Collapse Pane** — ⌘⇧↩ — zoom the focused pane to fill the tab, then back.
- **Focus a pane** — ⌘⌥← / → / ↑ / ↓ — move keyboard focus by direction.
- **Pane title bars** — View ▸ Show Pane Title Bars, or Settings ▸ Windows & Tabs ▸ Window ▸
  Pane Title Bars — show a small title strip on each pane.

Each pane is a full shell with its own scrollback, selection, and process.

## Moving tabs and panes

Drag a tab using the native macOS tear-off gesture. Its miniature window follows
the pointer, and the remaining tab becomes visible underneath, ready to receive
the drop. Native tab reordering and the expand-to-window animation remain available.

Drag a tab or a pane's title bar onto a terminal. The guides show all four split
directions and a center target for adding a tab, including when the destination
has only one tab. The highlighted half shows where the moved content will land.
Release a native tab over blank content outside those targets to keep it as a
separate window.

In a tab with multiple panes, drop on the outer edge band to split the entire
tab: top and bottom span its full width, and left and right span its full height.
The existing panes stay together. Targets farther inside a pane split that pane
alone. A whole tab keeps its nested splits when moved into either kind of target.

Drag outside the windows to detach into a standalone window. A pane title bar's
context menu also offers **Move Pane to New Window**, **Move Pane to New Tab**,
and destinations in other open windows. Press Escape to cancel a drag.

Moves keep the running sessions. Sync moves update the owning host workspace;
tmux control-mode moves use the server's pane operations. Panes can share a
split when they belong to the same Sync workspace or tmux control connection,
or when both are local sessions.

## Window & tab titles

Ubiquitty composes titles from parts you choose in **Settings ▸ Windows & Tabs** — separately for the
**Window Title** and the **Tab Title**:

- **Working Directory** — the current folder, formatted as **Name** (just the folder, e.g.
  `Projects`) or **Path** (the full tilde path, e.g. `~/Projects`).
- **App-Set Title** — a title the running program set via OSC 0/1/2 (e.g. an editor).
- **Active Process** — the foreground process chain (e.g. `vim`, `ssh host`).
- **Dimensions** — the grid size in columns × rows (on by default for windows, off for tabs).

A custom name from **Rename Tab…** overrides the composed title.

## Profiles

A profile is a named preset of theme + font + font size + line spacing + padding.

- **Use one** — File ▸ New Window with Profile ▸ *(name)* opens a fresh window with that look.
- **Define one** — Settings ▸ Sessions ▸ Profiles, or add a `[[profiles]]` block to `config.toml`.
  Profiles are rebuilt whenever the config reloads, so the File submenu stays in sync.

## Window menu

Closing a remote tab offers **Close Tab**, which ends only that tab's sessions
on the host. Closing its last pane also closes only that tab. Other tabs and
windows stay connected. A standalone window offers **Close Window** for its one tab.

The workspace menu's **Close Window** ends the chosen host window and all its
sessions, including its other tabs. **Detach from Workspace**
closes every local window attached to that workspace and leaves its sessions
running on the host. **Cancel** is the default; neither operation happens before
you choose. A changed connection or workspace layout dismisses a stale question.

**Window ▸ Workspaces ▸ Remote Workspaces** offers the whole-window close and detach actions for every open remote workspace,
even when another window is focused. Each close command identifies its connection
and window; detach applies to the whole workspace, not only the selected tab.

The **Window** menu uses macOS's window list, including native tabs, checkmarks
and minimized windows. Minimize (⌘M) and Zoom are the standard macOS commands.

## Limits

- **Scrollback** — 10,000 lines per session by default. Settings offers 1,000
  to 100,000; `scrollback_lines` in `config.toml` takes up to 1,000,000.
- **Scrollback memory** — a full-width line held as cells costs 32 bytes a
  column, about 25 MiB for 10,000 lines at 80 columns and 63 MiB at 200. Once a
  session's output pauses, its older history is compacted to about 1.4 MiB per
  10,000 lines at 80 columns and 2.6 MiB at 200; the newest two blocks of
  8,192 cells stay as cells. Shorter lines cost their length. Measured on Linux x86-64 with
  `LineStore::arenaBytes` on 10,000 full lines of shell text, with and without
  a coloured prompt every fourth line.
- **Panes** — up to 64 in one tab.
- **Sessions on a host** — one `ubiquitty-host` holds at most 64 sessions and
  serves at most 64 clients at once; see
  [Remote Sessions & Agents](remote-sessions-and-agents.md#what-a-host-is-holding).
- **Images** — 32 images and 128 placements per terminal, within a decoded-pixel
  budget. A placement scrolled more than 32,768 rows above the screen is
  dropped, while its text stays in history; see
  [Inline images](images-links-and-escape-sequences.md#inline-images).
