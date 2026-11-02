<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Session Resurrection

Session restoration is experimental and opt-in. It records the window and tab layout
and can keep whole-window shells running through the local daemon. A local shell’s
handoff carries its complete terminal state, including retained scrollback, or
refuses without truncating it.

## Turning it on

**Settings ▸ Sessions ▸ Session Persistence ▸ "Restore Last Session on Launch."**
Default **off**. Without it, quitting closes local shells and does not restore their
window layout. Daemon-owned remote sessions follow their own retention policy.

(Equivalent config: `[experimental] session_persistence = true`.)

## Across an update

When Ubiquitty quits to install an update and relaunch, it keeps your session
as if Restore Last Session on Launch were on, whether or not it is, and the
updated Ubiquitty opens with every window as it was. Only that launch restores
it: with the setting off, the next time you open Ubiquitty it starts fresh. See
[Application updates](../auto-update.md#your-terminals-across-an-update).

## What it does

- **At quit**, each tab's running shell, and each pane's in a split tab, is handed to the
  local `ubiquitty-host` daemon (the same handoff as
  [Share This Window](remote-sessions-and-agents.md#share-this-window-with-agents)),
  so it keeps running after Ubiquitty exits. Every window is recorded: its frame, whether
  it was in full screen, its place among the other windows, its tabs and the selected one,
  and each tab's split and focused pane.
- **At launch**, Ubiquitty rebuilds every window with all its tabs and splits, and
  re-attaches each session. The screen and retained history carried at handoff return,
  together with output the daemon collected afterward.
- A session that's **gone** (e.g. the machine rebooted) comes back as a **fresh shell** in
  the same tab, so the layout is always preserved.
- With persistence on, the supported whole-window shells are handed to the daemon
  instead of terminated; that handoff does not ask for a running-process warning.
- A lost handoff reply does not count as a refusal. The local terminal stays
  paused until the daemon confirms who owns it. Keep Ubiquitty open while that
  result is unresolved; normal close and quit must not dispose the retained shell.

## Saved layouts (⌘⇧K)

**File ▸ Connect…** (⌘⇧K) opens the Connect window. Choose **Layouts** in the
sidebar to manage saved workspaces: their windows, tabs, and panes, not a single tab.

- **Open** a saved layout — its windows and tabs open **alongside** what you already have.
- **Save Current Layout** — name the current layout so you can reopen it later.

To start a fresh local shell, choose **File ▸ New Local Window**.

The picker is a single switcher for saved workspaces and attached session sources; source
badges distinguish local workspaces from tmux-backed sessions.

## Boundaries

- A local handoff carries the complete terminal and all retained scrollback, or
  refuses without discarding history. The encoded record is limited to 36 MiB,
  with separate component limits. An unfinished control sequence, image transfer
  or history rewrap also prevents capture until it finishes. Sessions already
  owned by a daemon keep the history that daemon retains; closing a client does
  not transfer or discard that host-owned history.

- **A split tab is kept whole or not at all.** When the daemon takes every pane, the split
  comes back with each pane rejoining its shell. When it can't, the split comes back with
  its geometry and a new shell in each pane.
- **Capture happens at quit.** A normal ⌘Q is preserved; a force-quit or crash loses the
  saved *layout* (already-running daemon sessions themselves stay alive).
- **The daemon holds at most 64 sessions**, counting the ones it already runs. Once it
  refuses a shell at quit, because it is full or for any other reason, that tab and every
  local shell captured after it restore as fresh shells in their windows, and the programs
  running in them end with Ubiquitty. If one of them is running a program, the quit asks
  first, unless you've already chosen to quit with programs ending.
- Remote (SSH) sessions restore over the SSH transport; the QUIC fast-path is re-negotiated
  rather than persisted.
