<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# ubiquitty_sync for Neovim

A **Neovim client for the Ubiquitty terminal**. It attaches to a running
`ubiquitty-host` daemon through its attach bridge and paints the terminal grid
into a Neovim terminal buffer. Keys
typed in that buffer reach the session; the session's screen reaches the buffer.

The terminal Core (VT parser, screen model, scrollback) runs in the daemon, not
in Neovim. A session can outlive Neovim while the host keeps running, and
multiple clients can attach to it. See [Limitations](#limitations) for image,
history, and reconnect behavior.

## Requirements

- Neovim 0.10 or later (`vim.uv`, `vim.system`, `nvim_open_term`).
- The `ubiquitty-host` daemon binary of the same version as the client.
  An app installed in `/Applications` includes it at
  `/Applications/Ubiquitty.app/Contents/Helpers/ubiquitty-host`, and each
  release publishes it for Linux and Mac servers
  ([Hosting](../../../Docs/auto-update.md#hosting)).

To build and locate the daemon from the repository root instead:

```sh
./Scripts/build-host.sh
ubq_build_root=$(python3 Scripts/build_root.py .)
printf '%s\n' "$ubq_build_root/host/ubiquitty-host"
```

The plugin never opens the daemon's socket itself. The daemon admits a
tokenless local peer only when the peer's kernel-verified executable is one of
its own binaries, so a connection from `nvim` is refused with `AUTH_DENIED`.
Instead the plugin runs `ubiquitty-host --ensure-daemon` (a no-op when a daemon
is live) and then `ubiquitty-host --attach`, speaking frames over the bridge's
stdin and stdout. The bridge's stderr is read apart from the frame stream, and
its last line is what a disconnect reports.

## Install

### lazy.nvim

```lua
{
    dir = "/path/to/ubiquitty/Source/Platform/Neovim",
    name = "ubiquitty_sync",
    cmd = "UbiquittySync",
    opts = {
        -- Only needed when the daemon is not on PATH:
        host_program = "/Applications/Ubiquitty.app/Contents/Helpers/ubiquitty-host",
    },
    config = function(_, opts)
        require("ubiquitty_sync").setup(opts)
    end,
}
```

### Manual

```lua
vim.opt.runtimepath:append("/path/to/ubiquitty/Source/Platform/Neovim")
require("ubiquitty_sync").setup({
    host_program = "/absolute/path/to/ubiquitty-host",
})
```

## Usage

```
:UbiquittySync
```

Starts the daemon on demand, opens a terminal buffer in the current window and
attaches a fresh session to it. The window's text area becomes the terminal
size; resizing the window resizes the session. The buffer is named
`ubiquitty://<title>` and follows the session's title.

```
:UbiquittySync detach
```

Ends this buffer's attach and leaves the session running; `:UbiquittySync`
again opens a new one. Wiping the buffer detaches the same way.

## Keys

The buffer is a Neovim terminal buffer, so terminal mode is Neovim's own.

| Key                     | Mode             | Action                                        |
|-------------------------|------------------|-----------------------------------------------|
| `<C-\><C-n>`            | terminal         | Leave terminal mode (Neovim's own binding)    |
| `i`, `a`                | normal           | Return to terminal mode                       |
| `<C-\><C-q>`            | terminal, normal | Detach; the session keeps running             |

Everything else typed in terminal mode goes to the session: `<C-c>` sends the
interrupt, `<Esc>` reaches a program running inside. Arrow and keypad keys are
encoded the way the session's program asked for, because the plugin mirrors the
host's cursor-key, keypad and bracketed-paste modes into the buffer's terminal.
With `'mouse'` set, clicks, drags and the wheel are forwarded when the program
has mouse tracking on; otherwise they act on the window.

## Configuration

```lua
require("ubiquitty_sync").setup({
    host_program = "ubiquitty-host",  -- name on PATH or absolute path of the daemon binary
    socket = nil,                     -- daemon socket leaf (host-<hash>.sock) handed to --socket
    auto_start = true,                -- run --ensure-daemon before attaching
    end_when_detached = false,        -- set true to end the session when this client detaches
    state_directory = nil,            -- where the client instance and resume record live
})
```

| Key                 | Default            | Meaning                                                                                  |
|---------------------|--------------------|------------------------------------------------------------------------------------------|
| `host_program`      | `"ubiquitty-host"` | Resolved with `exepath()`, so a bare name is looked up on `PATH`.                         |
| `socket`            | `nil`              | Passed as `--socket`; `nil` lets the host derive its socket from its own binary identity. |
| `auto_start`        | `true`             | Run `--ensure-daemon` first (a no-op when a daemon is already live).                      |
| `end_when_detached` | `false`            | Create the session with the ends-when-detached flag, so `detach` ends it too.             |
| `state_directory`   | `nil`              | Where the client instance and resume record are kept; `nil` is `ubiquitty_sync` under `stdpath("data")`. |

### Restarting Neovim

The client keeps its client instance and a resume record in the state
directory, which only its owner can open. When Neovim exits without
detaching, the record holds the attachment and the screen the buffer showed.
`:UbiquittySync` after a restart draws that screen before the bridge
delivers anything, greets the host as the same client, and continues the
attachment: the host sends what changed rather than a whole screen. The host
program reads and writes the record (`ubiquitty-host resume-record`); the
record format and its rules are Core's (Docs/sync.md §6.9). Detaching, or
the session ending, removes it. The record is not encrypted: it holds what
the local daemon's own screen holds, under the same account.

## What crosses the wire

- The greeting uses the version in the generated `wire.lua` table as both its
  current and minimum version. It states the session-lifetime flag and
  requests the pane's echo context. Refusals display the host's reason.
- Typed input goes on the pane's handle as numbered events. The
  embedded terminal has already encoded keys and mouse reports, so they go as
  `Raw`; a bracketed paste is taken out of its brackets and goes as `Paste`
  pieces of at most 8 KiB, no further ahead of the host's `PasteReceipt` than
  the window its `Welcome` states. An interrupt typed during an unfinished
  paste sends `PasteAbort` first; which key that is comes from the pane's
  echo context. `InputDiscarded` is counted and ends any paste it names.
- The window's size and focus travel in a `Facts` of the plugin's own, and
  the buffer's focus in a `Focus`.
- A checkpoint, carried across bulk chunks, replaces both screens the plugin
  holds and is painted whole: cursor position, the pen as SGR (256-colour
  indexes and direct RGB for foreground and background; bold, dim, italic,
  underline, inverse, strike), then the cell text. An update paints only the
  rows it names on the shown screen. Applied state is acknowledged;
  an update onto a generation the plugin does not hold, or one that fails to
  decode, asks for a fresh checkpoint with `Resync`.
- The modes block's mouse, keypad, cursor-key and bracketed-paste flags are
  mirrored into the embedded terminal, so the keys and mouse reports it
  encodes are the ones the host's program asked for.
- Default foreground and background are the buffer's `Normal` colours, so a
  session looks like any other Neovim terminal.

## Limitations

- No inline images, and no mirroring of the host's scrollback — the buffer
  keeps what scrolls off its own top.
- The checkpoint's SHA-256 and the screen state's digest are not recomputed.
  The decoder checks field bounds, but does not verify those content digests.
- No consent flow and no remote (QUIC) transport: the bridge attaches to the
  daemon on this machine.
- Keys and mouse events are bytes by the time the plugin sees them, so they
  are never sent as `Keys` or `Pointer`: the host does not encode them under
  its live modes, and the embedded terminal's mirror of those modes decides.
- Reconnecting does not resume the previous attachment or resend input that
  was in flight when the bridge closed. No echo is predicted.

## Tests

`./Libraries/ubiquitty-core/Scripts/run-tests.sh neovim_sync_decode` builds the fixture that records
the host's attach and update stream, and feeds it
to the plugin headlessly (`Tests/Platform/neovim_sync_decode_test.lua`). The
test also records everything the plugin sends, which the fixture reads back
with the host's own decoders and compares, as a transcript, against
`Tests/Platform/neovim_sync_upstream.expected`.
`Tests/Platform/neovim_live_check.lua` attaches to a live daemon, reports
whether a checkpoint was applied, typed input, a paste and a new size came
back, and the host counted every event written, and ends the session it
created:

```sh
nvim --headless -l Tests/Platform/neovim_live_check.lua \
    /Applications/Ubiquitty.app/Contents/Helpers/ubiquitty-host
```

## License

This interoperability example is [Apache-2.0](LICENSE), as is the Ubiquitty
host it attaches to; see the [licensing guide](../../../Docs/licensing.md).
