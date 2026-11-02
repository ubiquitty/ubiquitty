<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Keyboard Shortcuts

Default shortcuts. The menu bar is authoritative — every command shows its shortcut beside
it. **Settings ▸ Keyboard** edits terminal bindings; menu shortcuts take precedence
when the same chord is assigned in both places. Choose an unused chord for a custom binding.

## Windows & tabs

| Shortcut | Command |
|----------|---------|
| ⌘N | New Local Window |
| ⌘T | New Tab |
| ⌘⇧T | Reopen Closed Window — a single-tab local window closed without a confirmation in the last 30 seconds, its processes still running |
| ⌘W | Close the focused pane (the last pane also closes its tab or window) |
| ⌘1 … ⌘9 | Select tab by position (⌘9 = last tab) |
| ⌘⇧I | Rename Tab… |
| ⌘⇧[ / ⌘⇧] | Previous / Next Tab |
| ⌘M | Minimize |
| ⌘↩ | Toggle Full Screen (also ⌃⌘F) |
| ⌘⇧K | Connect… (saved sessions + every connection kind) |

To open another window in a remote workspace, use **File ▸ New Window on [connection]**.
⌘N always opens a local window.

Closing a remote tab ends only that tab's host sessions. The workspace menu's
**Close Window** ends every tab in the chosen host window;
**Detach from Workspace** closes all local views and leaves the host running.
See [remote window actions](tabs-splits-and-windows.md#window-menu).

## Split panes

| Shortcut | Command |
|----------|---------|
| ⌘D | Split Right |
| ⌘⇧D | Split Down |
| ⌘⇧W | Close Pane |
| ⌘⇧↩ | Expand / Collapse Pane |
| ⌘⌥← / → / ↑ / ↓ | Focus pane in that direction |

## Edit, selection & search

| Shortcut | Command |
|----------|---------|
| ⌘C / ⌘V | Copy / Paste |
| ⌃⇧⌘C | Copy Without Background Color |
| ⌥⇧⌘C | Copy Plain Text |
| ⌘⇧V | Paste from Buffer… — an OSC 52 buffer or a recent copy |
| ⌃⌘V | Paste Escaped Text — the clipboard, shell-escaped as one argument |
| ⌃⇧⌘V | Paste Escaped Selection — the selection, shell-escaped as one argument |
| ⌘A | Select All |
| ⌘⇧A | Select Last Command Output *(shell integration)* |
| ⌘F | Find… |
| ⌘G / ⌘⇧G | Find Next / Previous |
| ⌘K | Clear Buffer — screen and scrollback both, keeping a half-typed line |
| ⌥⌘K | Clear Scrollback — drop the history the screen is not showing |
| ⌘L | Clear to Previous Mark *(shell integration)* |

> Hold **Option** while dragging for a rectangular selection.

## Prompt navigation *(shell integration)*

| Shortcut | Command |
|----------|---------|
| ⌘⇧↑ | Jump to Previous Prompt |
| ⌘⇧↓ | Jump to Next Prompt |

## View & font

| Shortcut | Command |
|----------|---------|
| ⌘+ / ⌘- | Zoom font in / out |
| ⌘0 | Actual Size |
| ⌘I | Show Inspector |
| ⌘⇧P | Show Command Palette |
| ⌃⌘H | Hide / Show Title Bar |
| ⌃⌘T | Keep on Top |
| ⌃⌘B | Broadcast Input to All Panes |
| ⌃⇧⌘H | Show / Hide Build Hash |

## Application

| Shortcut | Command |
|----------|---------|
| ⌘, | Settings… |
| ⌘Q | Quit Ubiquitty |
| ⌘/ | Keyboard Shortcuts |
| ⌘? | Ubiquitty Help |

## Diagnostics

| Shortcut | Command |
|----------|---------|
| ⌃⌘Y | Sync Debug |
| ⌃⌘S | Stream Debug |
| ⌃⌘A | Adaptive Drive |

Diagnostic builds also provide ⌃⌘D for Drawing Debug and ⌘⇧H for Paint Heatmap.

## The Option key

Option types what your keyboard layout puts on it, as it does in every other Mac
app. On a German layout ⌥L types @ and ⌥5 and ⌥6 type [ and ]; on a US layout ⌥E
starts an accented letter. ⌥← and ⌥→ move by word and ⌥⌫ deletes the word
before the cursor whatever the setting. ⌥Space types a no-break space, which a
shell does not treat as a word separator.

Choose **Settings ▸ Keyboard ▸ Use Option as Meta** to select Neither Key, Left Option,
Right Option, or Both Keys. The change applies immediately and is saved in your
configuration file. To configure Meta (Alt) directly, so that ⌥B and ⌥F move by word in the shell
and Emacs reads ⌥X as M-x, add this to `~/.config/ubiquitty/config.toml`:

```toml
[keys]
option_as_alt = "both"
```

`left` or `right` makes only that Option key Meta and leaves the other one
typing your layout's characters, which suits a layout that needs Option for
brackets or @. The default is `none`. A ⌘ chord is never Meta, and a `[keys]`
binding on an Option chord takes precedence over this setting.

## Compose and custom layout bindings

If you use both Option keys as Meta, individual bindings can still type layout
characters. For example, `[keys]` can contain `"alt+l" = "send:@"`. A binding takes
precedence over Option-as-Meta.

For a terminal compose key, set `compose_key = "ctrl+space"` under `[keys]`.
Press Control-Space, then two characters: `' e` produces é, `a t` produces @,
`( (` produces [, `) )` produces ], `( -` produces {, `- )` produces },
`/ /` produces \, `! ^` produces |, and `~ Space` produces ~.
This consumes Control-Space before the shell sees it. The `menu` trigger is also
accepted for keyboards whose frontend delivers a Menu key; modifier keys alone,
such as Right Option, are not compose triggers.
