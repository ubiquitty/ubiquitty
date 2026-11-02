<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Selection, Clipboard & Search

## Selecting text

- **Drag** to select a range; **double-click** selects a word; **triple-click** selects a line.
- **Smart Double-Click** — Settings ▸ Selection & Clipboard ▸ Smart Double-Click. When on, double-click
  grabs a whole URL or file path token rather than stopping at word boundaries.
- **Select All** — ⌘A.
- **Select Last Command Output** — ⌘⇧A — selects everything the last command printed, when
  [shell integration](shell-integration.md) is active.

Selection is made with the pointer and these two commands; Ubiquitty has no
keyboard-driven selection or copy mode of its own. Inside tmux, tmux's
copy-mode works as usual, and under the [tmux integration](tmux.md) a copy made
in it is also placed on the system clipboard.

## Rectangular (block) selection

Use **Block Selection Modifier** in Settings ▸ Selection & Clipboard ▸ Selection
to choose the modifier for rectangular selection (Option by default).

Mouse-tracking applications receive ordinary drags. Hold the configured **App
Selection Modifier** (Shift by default) to select terminal text instead. Combine it
with the Block Selection Modifier for a rectangular selection over a mouse-tracking app.

## Copy & paste

- **Copy** — ⌘C. **Paste** — ⌘V.
- **Copy on Select** — Settings ▸ Selection & Clipboard (or the Edit menu). When on, selecting text
  copies it to the pasteboard automatically as soon as you finish the drag.

## Clipboard access from programs (OSC 52)

Programs can read and write the system clipboard with the OSC 52 escape sequence (handy
over SSH or inside `tmux`). Ubiquitty gates this for safety, configurable in the `[security]`
section / Settings:

- **Write** (`clipboard_write`) — **Allow** (default) or **Deny**.
- **Read** (`clipboard_read`) — **Prompt** (default — you're asked before a program reads
  your clipboard), **Allow**, or **Deny**.

Hosted programs also require the host's capability permission. When a remote
copy asks for consent, **Allow Once** approves that exact copy; the program does
not need to send it again. Denying the request or losing its connection discards
the pending copy. Selecting **This Computer** as a clipboard source does not
grant a program permission to read or replace it.

## Clipboard tools in hosted sessions

Hosted sessions install private `pbpaste`, `pngpaste`, `wl-paste`, `xclip`, and
`xsel` commands. When the connected client serves its clipboard, these commands
read that client's text, MIME types, or requested image bytes. X11 primary and
secondary selections remain distinct from the clipboard.

`pngpaste -` writes PNG bytes to standard output, `pngpaste image.png` replaces
that file atomically after a successful read, and `pngpaste -b` writes base64
without a newline. JPEG, GIF, and TIFF output conversion is not provided by the
client-backed helper. The command forms follow the [pngpaste implementation](https://github.com/jcsalterego/pngpaste/blob/master/pngpaste.m).

The daemon links these commands into a private directory,
`clipboard-tools/host-<id>.sock/` in its control directory, and starts each shell
with three variables: `UBIQUITTY_CLIPBOARD_SOCKET`, the host socket the
commands ask; `UBIQUITTY_CLIPBOARD_TOOLS`, the directory placed first on
`PATH`; and `UBIQUITTY_CLIPBOARD_NATIVE_PATH`, the `PATH` without it, where the
original tools are found. They are written by the host, not set by hand.

Selecting the host clipboard forwards commands and arguments to the original
native tools. Client-backed clipboard writes through these commands are not
supported and fail explicitly. Programs that call native clipboard APIs directly,
including AppKit, are outside this command integration.

A shell that predates integration, or whose PTY was adopted by the host, can opt
in without modifying startup files:

```sh
eval "$(ubiquitty-host clipboard-env --socket /absolute/path/to/live/host-0123456789abcdef.sock)"
```

Use the socket belonging to that session, rather than the illustrative path
above. The daemon verifies that the setup process belongs to its session before
returning environment assignments. If `UBIQUITTY_CLIPBOARD_SOCKET` is already set,
`clipboard-env` can omit `--socket`. Existing applications must be restarted from
the configured shell to inherit its environment; the terminal session and host
stay running.

## Find

- **Find…** — ⌘F — open the find bar and search the screen and the scrollback, with
  case-sensitive and regular-expression options.
- **Find Next** — ⌘G — **Find Previous** — ⌘⇧G.

## Clearing the screen

Choose whether to erase output or move it into scrollback:

- **Clear Buffer** — ⌘K — screen and scrollback both, keeping the line you are half-way through
  typing. Ctrl-L follows so the shell repaints its prompt at the top.
- **Clear Scrollback** — ⌥⌘K — drop the history the screen is not showing and leave the screen as
  it is.
- **Clear to Previous Mark** — ⌘L — with [shell integration](shell-integration.md), remove the
  most recent command (prompt + output) and slide the current prompt up into its place — press
  again to remove the preceding command; without marks, it clears to the start.
- **Clear Screen** — no shortcut — scroll the current prompt to the top of the window. The rows
  above it move into the scrollback rather than being erased, so scrolling back still reaches
  them. With [shell integration](shell-integration.md) the boundary is the prompt; without it,
  the cursor row.

While a full-screen program is running — tmux, an editor, a pager — the terminal cannot tell which
rows are finished output, and no escape sequence exists to ask a program to repaint. So these
commands do not touch the grid there: they forward Ctrl-L, which such programs read as "redraw",
and let the program clear itself.
