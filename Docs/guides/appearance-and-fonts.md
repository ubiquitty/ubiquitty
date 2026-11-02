<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Appearance & Fonts

## Themes & colors

A theme is a full color palette (16 ANSI colors + foreground, background, and cursor).

- **Pick a theme** — View ▸ Theme ▸ *(name)*, or Settings ▸ Appearance ▸ Themes.
- **Follow System Appearance** — View ▸ Theme ▸ Follow System Appearance. When on, Ubiquitty
  switches between a light and a dark theme as macOS flips appearance. Choose which theme
  is used for each in Settings ▸ Appearance with **Auto**, **Light theme**, and **Dark theme**.
  Picking a theme manually turns Follow off so your choice sticks.
- **Edit or create a theme** — Settings ▸ Appearance ▸ Themes (or View ▸ Theme ▸ Edit Current Theme…).
  Color wells edit each palette entry in a local preview;
  Save writes a `[[themes]]` block to `config.toml`. Built-in themes are read-only — use
  **Duplicate** to base a custom theme on one.
- **Export a theme** — Settings ▸ Appearance ▸ Themes ▸ the palette’s actions menu ▸ Export Theme…. Save a `.toml` palette and import it with File ▸ Import Theme…. Export includes the name, light/dark designation, all 16 ANSI colors, foreground, background, cursor, and any status colors the theme names. iTerm2 and Ghostty formats are import-only.
- **Status colors** — a `[[themes]]` block may name the color each status is drawn in:
  `status_failed`, `status_blocked`, `status_attention`, `status_done`, `status_working`,
  `status_neutral` and `status_progress`, each `"#rrggbb"`. They color the marks beside a tab or a listed session
  (a failed job, a program waiting on you, an unseen bell, a finished job, work in flight).
  A status a theme does not name takes the theme's own ANSI red, yellow, magenta, green or
  blue, and neutral the midpoint of its foreground and background. A progress bar, its dimmed
  and error states, and the dot an unseen notification leaves are drawn in the platform's own
  colors (on macOS the accent, gray, red and blue) until the theme names `status_progress`,
  `status_neutral`, `status_failed` or `status_attention`, which then apply to them too.
- **Color space** — Settings ▸ Appearance ▸ Background ▸ Color Space: **sRGB** (standard) or
  **Display P3** (wider gamut, more saturated on capable displays).

Programs can also set colors at runtime: 24-bit true color (`SGR 38;2;r;g;b` /
`48;2;r;g;b`), the 256-color palette (`38;5;n`), and default fg/bg via OSC 10/11.

## Window opacity & padding

- **Background Opacity** — View ▸ Background Opacity, or Settings ▸ Appearance ▸ Background.
  Makes the window translucent (desktop shows through); **text and ink stay fully opaque**.
- **Padding** — Settings ▸ Windows & Tabs ▸ Content Insets ▸ Top, Bottom, Titleless Top, Left, or Right Padding —
  the inset between the text grid and the window edges. On iOS, Settings ▸ Padding sets
  **All Edges** at once or Top, Bottom, Left and Right alone, and **Reset to Default** returns
  to the default; an open terminal re-lays out its grid as the value changes. In
  `config.toml` these are `[appearance]` `padding` (every edge) and `padding_top`,
  `padding_bottom`, `padding_left` and `padding_right`, which win over `padding`.
- **Titleless top padding** — `[appearance] titleless_padding_top` sets the top inset
  only when the title bar is hidden. When unset, it follows the effective
  `padding_bottom`, independently of `padding_top`.
- **Default padding** — where no padding is set, a desktop window has 6 pt at the left,
  right and bottom and none at the top, below the title bar. iOS has 4 pt on every edge,
  measured inside the screen's safe area, so the text clears the notch, the rounded corners
  and the Home indicator by the safe area and then by the padding.

## Fonts

- **Family** — View ▸ Font, or Settings ▸ Fonts ▸ Family. Ubiquitty probes installed
  fixed-pitch fonts at launch. The default is **SF Mono** where it is installed, then the
  bundled **JetBrains Mono**, then JetBrains Mono NL, then Menlo. The Font menu groups ligature-capable
  fonts separately from plain monospace fonts.
- **Size** — View ▸ Font Size, Settings ▸ Fonts ▸ Size, or zoom with **⌘+ / ⌘- / ⌘0**
  (zoom in / out / actual size).
- **Ligatures** — Settings ▸ Fonts ▸ Ligatures. Contextual shaping (e.g. `->` rendered as
  an arrow) using the font's OpenType features. Only offered for fonts that support it.
- **Line Spacing** — Settings ▸ Fonts ▸ Line Spacing — extra leading above the font's
  natural line height.
- **Character Spacing** — Settings ▸ Fonts ▸ Character Spacing — extra width added to
  each column, in hundredths of a point; a negative value tightens the grid.

On Linux the family defaults to fontconfig's `monospace` and the size to 12 pt,
and `[font] family` and `[font] size` in the configuration change them. Two
environment variables override both at launch: `UBIQUITTY_FONT` names a family,
and `UBIQUITTY_FONT_SIZE` a size in points from 4 to 256, fractions allowed. A
size outside that range is ignored.

### Right-to-left text

Arabic is drawn joined, and Hebrew and Arabic runs are displayed right to left
within a row. The terminal keeps the text in the order it arrived, so cursor
movement, column addresses, and what a program reads back are unchanged; only
the drawn row is reordered. The ordering is a row-local rule rather than the
full Unicode Bidirectional Algorithm (UAX #9): it reverses each run of
right-to-left letters and the spaces between them, and has no embedding levels,
isolates, bracket pairing, or paragraph direction, so digits between two
right-to-left words split them into separate runs. The rule and its limits are
in [Arabic joining and bidirectional display](../arabic-shaping-design.md).

### Fractional character spacing

CoreText fonts use the exact spacing value, added after each glyph. Bitmap
**GNU Unifont** rounds it to whole screen pixels and centers the glyph in the
wider cell, with any odd pixel on the right.

At 2× display scale, 1.25 pt of Unifont spacing rounds to 3 pixels (1.5 pt).
At 1× scale, 0.4 pt rounds to zero. The Linux FreeType renderer also rounds
spacing to whole pixels, but adds the gap after the glyph.

### Underline tuning (Settings ▸ Fonts ▸ Underline)

For underlines and underlined hyperlinks: **Thickness** (multiplier), **Offset** (points
below the baseline), **Follow Ink** (extend a word's underline to where the ink of its
outer letters ends, past the cell), **Skip Ink** (break the rule where descenders cross
it), and the **Skip-Ink Gap** (halo cleared around descenders).

## Text rendering (Settings ▸ Fonts ▸ Text & Graphics)

**Bold Is Bright** lets bold text use the bright ANSI palette (8–15).
The same page holds the braille, shaded-block and wide-glyph controls.

## Cursor (Settings ▸ Cursor)

- **Shape** — Block / Underline / Bar. View ▸ Cursor Shape has the same control. A program
  can override the shape per session via `DECSCUSR`.
- **Blink**, **Linger** (frames the cursor stays solid after a keystroke before blinking),
  and **Opacity** (0 lets the cell beneath show through).
- **Invert Text Under Cursor** — Settings ▸ Cursor — a block cursor inverts the
  glyph beneath it instead of hiding it.

## Bell (Settings ▸ Notifications ▸ Bell)

**Audible Bell** plays a sound on `BEL`; **Visual Bell** flashes the screen. (Programs can
also play tones via the VT520 `DECPS` play-sound sequence — see
[Images, Links & Escape Sequences](images-links-and-escape-sequences.md#sound).)
