<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Images, Links & Escape Sequences

This guide describes graphics and escape-sequence support in the macOS app.

## Inline images

The macOS app decodes encoded images through ImageIO and composites them with
Metal. It accepts three inline-image protocols:

- **OSC 1337** — `ESC ] 1337 ; File=...:<base64> ST`. The common case; tools like
  `imgcat` use it.
  ([spec](https://iterm2.com/documentation-escape-codes.html))
- **Sixel** — `DCS ... ST`. Classic bitmap graphics (gnuplot, `lsix`, etc.).
  ([DEC manuals](https://vt100.net/docs/))
- **Kitty graphics protocol** — `ESC _ G ... ST`. Chunked upload + placement, de-duplicated
  by image id. ([spec](https://sw.kovidgoyal.net/kitty/graphics-protocol/))

Each protocol can be turned off in `[security]` of `config.toml`:
`osc_deny = "1337"`, `dcs_deny = "sixel"` and `apc_deny = "G"` (kitty graphics
is the APC whose first byte is `G`). A denied sequence is read to its end and
dropped without a reply, so a chunked kitty transfer never opens.

Image support differs in other clients. The [Emacs client](../../Source/Platform/Emacs/README.md)
requires a graphical frame and has placement limitations; the
[Neovim client](../../Source/Platform/Neovim/README.md) does not render inline images.

Each terminal stores up to **32 images and 128 placements**, with a **256 MiB**
combined decoded-pixel budget and a **64 MiB** per-image decoded limit. Large
images and animation frames consume this budget quickly.

At slot capacity, older images entirely above or below the live screen can be
evicted, including images in scrollback; scrolling back may therefore show text
without those images. Images intersecting the live screen are retained under
slot pressure. Virtual placements are conservatively retained. If every slot is protected, Kitty reports `ENOSPC`;
sixel and iTerm2 image output can be dropped. Byte-budget pressure prefers
images outside the live screen but can also evict displayed images. Clearing
images or letting old placements leave history releases capacity.

A placement's anchor reaches at most 32,768 rows above the screen. With a
scrollback longer than that, a placement scrolled further up is dropped while
its text stays in history, so scrolling back that far shows the text without
the image.

## Hyperlinks (OSC 8)

Programs can wrap text in a clickable hyperlink with `OSC 8 ; ; <uri> ST … OSC 8 ; ; ST`
([spec](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda)).
Ubiquitty:

- underlines link text (style configurable — see [Appearance & Fonts](appearance-and-fonts.md#underline-tuning-settings--fonts--text--graphics--underline)),
- optionally forces links to the system blue (Settings ▸ Mouse & Trackpad ▸ Links ▸
  **Force Link Color**),
- opens a link the program declared on a plain click (Settings ▸ Mouse &
  Trackpad ▸ Links ▸ **Open Links with a Click**, `[selection]
  osc8_click_opens`), and a URL or path it only recognised in the text on
  **⌘-click** (**Ctrl**-click on Linux), with copy/open actions in the
  right-click menu,
- shows, at the bottom left of the window, what a click would open.

An `ssh:`, `sftp:`, `ftp:` or `ftps:` link opens only with **⌘** held (**Ctrl**
on Linux, either one in a browser), even when the program declared it: each
connects to a host the program named, through Terminal, an SSH or FTP client,
or Finder. On iPhone and iPad a tap never opens one: touch and hold the link
and choose **Open Link**, or **⌘**-click it with a keyboard and pointer.

A program chooses both a link's text and its target, so a click hands the
system opener only what it can merely display. A link to a local file opens
when it is text or source, an image or video, a PDF, a folder Finder opens, or
a file such as `README`, `Makefile` or `.gitignore`. Applications, scripts,
executables, aliases, HTML, XML and types not on that list are shown selected
in Finder (the file manager on Linux) instead, where opening one is your
decision. So is audio (`mp3`, `m4a`, `wav`): Music opens it, and adds what it
opens to your library. A path where nothing is, a device or a pipe opens
nothing, and so does a target carrying a control character, a direction
override or a zero-width space; the plate spells such characters out and marks
a link a click would not open. It also spells out a joiner or a variation
selector with nothing on either side for it to join, as between two ASCII
letters, while keeping the ones an emoji or a script such as Persian or
Sinhala is written with.

### A file at a line

A file link whose fragment names a line opens the file: a line number, as
`rg --hyperlink-format` and `delta` write one, with or without an `L` before
it, and with a range or a column after it (`#L12`, `#L12-L20`, `#L12:5`). To
open it at that line, name the program in `config.toml`, on macOS and Linux
alike:

```toml
[links]
line_handler = "code --goto {path}:{line}:{column}"
```

`{path}`, `{line}` and `{column}` are filled in wherever they stand, and a link
that names no column fills `{column}` with 1. The command is split into words
on spaces and run without a shell. `{path}` is the file Ubiquitty checked, its
symbolic links resolved, and never the link as the program printed it. Any
regular file goes to the handler, a script included, because an editor shows a
script rather than running it; a directory opens as it would without a line.
Other examples are `zed {path}:{line}:{column}` and
`wezterm start -- nvim +{line} {path}`.

Name an editor. A command that opens a file the system's way, such as
`open {path}`, `xdg-open {path}` or `gio open {path}`, would run a script or a
program that a line link points at. The words are split with no quoting, so a
program whose path has a space in it, such as one inside an application named
with two words, is named through a symbolic link to it on a path without one.

A program named without a path is found on the app's `PATH`, which for an app
started from the Dock is the system's: name an editor installed elsewhere by
its full path, such as `/usr/local/bin/code`. With no `line_handler`, or with
one whose program is not found or cannot be started, a line link opens the
file the way any file link does. A fragment that is not a line is refused,
because no file has one.

### Files on a remote host

File paths and `file://` links in a hosted pane refer to that pane's host,
not this computer. Opening one shows the host and resolved path. Choose
**Download** to request the file, or **Cancel** to leave it on the host.
Nothing is requested before approval. A changed or closed connection invalidates
the question; open the link again on the current connection.

A file URI naming another host cannot select a connection or launch a local
handler. Downloaded files retain the macOS quarantine checks before opening.
A link whose fragment names a line, such as `#L12`, downloads the file it
names, and the copy opens at that line in your `line_handler`; with none set,
or one that cannot be started, it opens the way any downloaded file does.
The plate shows a `file://` link's path on the host, and marks one a click
will not request: a link naming a third machine, or carrying a query or a
fragment that is not a line.

## Color

- **True color (24-bit)** — `SGR 38;2;r;g;b` (foreground) / `48;2;r;g;b` (background).
- **256-color palette** — `SGR 38;5;n` / `48;5;n` (xterm-compatible).
- **Default colors** — `SGR 39` / `49`; OSC 10/11 set the defaults, OSC 110/111 reset them.

Color is rendered in sRGB or Display P3 (Settings ▸ Appearance ▸ Background ▸ Color Space).

## Text attributes & effects

- Standard SGR: **bold**, **dim**, *italic*, underline, double-underline, strikethrough,
  reverse video, blink.

## Glyph coverage

- **Box-drawing** (U+2500–257F) and **Braille** (U+2800–28FF) — crisp, aligned rendering.
- **Powerline separators** (U+E0B0–U+E0BF) — drawn procedurally to fit the cell.
  Other Powerline symbols use font glyphs or supported procedural fallbacks.
- **Wide characters / CJK** — full-width cells with correct continuation.
- **Emoji and combining sequences** — grapheme clustering and font shaping,
  subject to the installed fonts' glyph coverage.

## Sound

- **Bell** — `BEL` rings the audible and/or visual bell (Settings ▸ Notifications ▸ Bell).
- **DECPS play-sound** (VT520) — `CSI Pvolume ; Pduration ; Pnote… , ~` plays up to sixteen notes
  in sequence, C5 to C7, through a square-wave voice like the VT520's speaker. Ubiquitty adds colon
  sub-parameters: `Pvolume:channel:wave:down:attack:decay:sustain:release:lowpass:highpass:reverb` picks the voice (0 square, 1 sine,
  2 triangle, 3 sawtooth, 4 noise, 5 drum), a channel (0 the speaker, 1 to 8 the tracker's, each
  playing its requests in turn so consecutive requests join without a gap), an envelope in
  milliseconds, and a transposition in semitones down; `Pduration:gap` leaves silence at each note's
  end; `Pnote:volume` gives one note its own level. Volume 0 stops a channel, and on channel 0 every
  channel. Notes are weighted for equal loudness, so a high note is not louder than a low one.

## Mouse reporting

Ubiquitty reports mouse events to programs that ask for them (X10 / SGR mouse
modes), including clicks, drags, and scrolling. Hold the configured **App
Selection Modifier** (**Shift** by default) to select terminal text instead.
For rectangular selection, also hold the **Block Selection Modifier**
(**Option** by default). See [Selection](selection-clipboard-and-search.md#rectangular-block-selection).
