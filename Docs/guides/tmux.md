<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# tmux Integration

In the macOS app, Ubiquitty speaks tmux **control mode**
([`tmux -CC`](https://github.com/tmux/tmux/wiki/Control-Mode)). Instead of drawing tmux's own text UI,
Ubiquitty renders each tmux pane as a **native split** — real Metal-rendered panes, native
scrollback and selection, with tmux managing the sessions underneath.

## Attaching

Open **File ▸ Connect… (⌘⇧K)** and choose the local tmux or tmux-over-SSH
connection kind. The local form attaches to your local tmux server; the SSH form
runs tmux control mode on the selected remote host. Both render its panes locally.
The command palette (⌘⇧P) also offers **Attach Local tmux Session…** and
**Attach tmux Session over SSH…**.

For remote terminal definitions, use **File ▸ Set Up Ubiquitty on Remote Host…**.

## What you get

- **Native splits** — tmux's pane layout is mirrored into Ubiquitty's split-pane tree, so a
  tmux split shows up as a real Ubiquitty pane (with its own scrollback and selection). Splits
  you make in Ubiquitty map back to tmux `split-window`.
- **Reattach** — attaching to an already-running session recovers the current screen
  contents (via `capture-pane`), not just new output.
- **A session badge** in the title bar marks tmux-backed windows; tabs of one tmux session
  share a color.
- **Scoped close** — **Close Tab** (or **Close Window** for a standalone window)
  ends only that tmux window and its panes. Closing a pane ends only that pane;
  its last pane also removes its tab. Other windows stay connected.
- **Persistence the tmux way** — **Detach** leaves the whole session running on
  the server. **Kill Session** ends the session and all its windows. These are
  separate choices in the close confirmation.

## tmux vs. Ubiquitty's own session resurrection

These are complementary:

- **tmux** persists *server-side* — the sessions live in the tmux server, independent of
  Ubiquitty, and survive across machines you can reach.
- **[Session Resurrection](session-resurrection.md)** persists *Ubiquitty's own* windows, tabs,
  and panes across an app quit, via the local daemon.

The ⌘⇧K **Sessions picker** is a single switcher that will list both your saved Ubiquitty
workspaces and your tmux sessions as you attach them.

## Layout ownership

tmux owns its pane layout. Split, close, focus, and zoom actions in Ubiquitty
send tmux commands; the resulting layout is then reflected in the window.
Moving panes between different tmux control connections is not supported.
