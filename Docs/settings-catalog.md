<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Settings catalogue and information architecture

The catalogue covers the macOS Settings window. `SettingsCatalog.swift` owns page
identity, navigation, search, and the generic controls. Custom editors use the
same grouped surfaces and row metrics, with generic controls and the custom
editors listed below. Blur Radius is compiled only when
the supported blur-radius implementation is enabled, and Software Update only
when the build carries the updater.

The [profile and workspace specification](design/settings-profiles-workspaces.md)
defines ownership, inheritance, and transfer rules. Global settings and profile
fields are distinct schemas; a global control does not imply a profile override.

## Navigation and grouping

| Sidebar group | Top-level category | Detail pages |
|---|---|---|
| Appearance | Appearance | Themes |
| Appearance | Fonts | Font Features; Fallback Fonts; Text & Graphics |
| Appearance | Cursor | — |
| Appearance | Windows & Tabs | Window Titles; Tab Titles; Pane Titles |
| Input | Selection & Clipboard | — |
| Input | Mouse & Trackpad | — |
| Input | Keyboard | Macros |
| Sessions | Sessions | Profiles; Tags |
| Sessions | Terminal | Vector Graphics; Platform Overrides |
| System | Notifications | — |
| System | Accessibility | — |
| System | Privacy & Security | Agents |
| System | Software Update | — |

The sidebar uses spacing between groups, without extra category headings. A child
page keeps its parent selected; native Back and Forward traverse visited pages.
Search spans all pages and reveals generic controls individually. Custom editors
contribute keyword matches to their page. Appearance's visual choices contribute
an additional category match. Beam derives its settings destinations from this
same catalogue, so moving a control also moves its command-palette destination.

Grouping decisions:

- Themes belong to Appearance; font features, fallback routing, and text/graphics
  rendering belong to Fonts.
- Cursor settings form one discoverable page rather than crowding Appearance.
- Window chrome, padding, and titles stay together; the three title contexts have
  separate pages rather than a long interleaved list.
- Text selection and paste confirmation belong together. Pointer shape, wheel,
  trackpad, and link-click behavior belong to Mouse & Trackpad.
- Remote clipboard access belongs to Privacy & Security because it grants access
  to data on this Mac; copying selected text is an input preference.
- Profiles and tags configure sessions. Macros are associated with keyboard
  actions. Agent access belongs beside the other permissions.
- Scrollback, encoding, and program identity belong to Terminal. There is no
  catch-all Advanced category.
- The automatic update check has a page of its own, Software Update, as it does
  in macOS. It exists exactly when the app menu offers Check for Updates. Session restoration explains its process and
  layout semantics separately.
- Folder-icon and OpenType specification controls each have one destination.
  The font-routing sample is a read-only preview.

## Generic controls

Labels below are the actual UI labels. Multiple controls named Title or Opacity
are unambiguous because their page is part of their search destination.

### Appearance

The custom appearance chooser precedes these groups: **Auto / Light / Dark**,
with a visual light-theme and/or dark-theme picker appropriate to the selected
mode. Changing an automatic palette preserves Auto.

| Group | Settings |
|---|---|
| Background | Color Space; Background Opacity; Perceptual Text Contrast; Background Blur; Blur Radius |
| Command Palette | Beam Uses Terminal Font |

### Fonts

| Group | Settings |
|---|---|
| Font | Family; Size; Proportional Family; Proportional Size; Font Weight; Bold Weight; Font Width |
| Spacing | Line Spacing; Character Spacing; Baseline Offset |
| Shaping | Ligatures; Slashed Zero |
| Underline | Thickness; Offset; Follow Ink; Skip Ink; Skip-Ink Gap |

Proportional Size is the em size OSC 66 p=1 runs are set at. Zero, the default,
sets them one optical step over the grid size — the grid size times 1.08, to a
quarter point and never under it, so a 12-point grid gives 13 — because a
proportional face lays down less ink per line than a monospace and reads smaller
at the same size (Docs/proportional-text.md).

Character Spacing steps in hundredths of a point, and what a fraction buys
depends on the tier the configured family renders through. A CoreText family is
tracked by the exact value — the pitch the grid lays out on is the face's advance
plus the tracking (`FontMetrics::trackedCellAdvance`), the glyph slot stays the
face's own, so the letter keeps the left edge of its column and the whole gap
falls after it. GNU Unifont renders through the embedded bitmap rasterizer, which
draws on whole backing pixels: the tracking is rounded to whole pixels of the
backing scale and widens the cell itself, so at 2x backing scale 1.25 pt of
tracking spaces by 1.5 pt, and at 1x 0.4 pt spaces by nothing. That cell also
splits its gap around the glyph, the odd pixel to the right, rather than banking
it after (`UnifontRasterizer.h`). The Linux FreeType grid rounds the tracking to
whole device pixels as the bitmap tier does and folds it into the pitch as
CoreText does. Every tier floors the cell at one unit of its own — a column on
the bitmap tier, a point or a pixel on the pitch tiers — so negative tracking
tightens the grid without closing it.

A proportional Family has no spacing setting of its own: its cell is the
advance of its `0`, which sizes the window and the winsize, and its rows are
laid out as proportional runs at the face's own advances
(Docs/proportional-text.md).

Fallback Fonts contains Symbol Fallback, CJK Fallback, and Emoji Fallback, followed
by the range and script override editors. Bundled Symbols Nerd Font Mono is the
default symbol fallback; technical symbols also fall back to STIX Two Math.

Text & Graphics groups Bold Is Bright, Braille Grid, Braille Style, Shaded
Blocks, Wide Glyph Boost, and Wide Glyph Scale. Shaded Blocks chooses whether
░ ▒ ▓ draw as a pixel pattern or a translucent fill
(`[appearance] shade_blocks`); the rest of box and block drawing follows the
renderer's glyph-routing rules.

### Cursor

| Group | Settings |
|---|---|
| Shape & Visibility | Shape; Opacity; Invert Text Under Cursor |
| Blinking | Blink; Blink Rate; Linger; Blink Animation |
| Movement | Cursor Motion |

### Windows & Tabs

| Group | Settings |
|---|---|
| Window | Hide Title Bar; Title Bar; Square Bottom Corners; Pane Title Bars; Snap Resize to Cells; Resize on 80/132 Column Switch |
| Content Insets | Top Padding; Bottom Padding; Titleless Top Padding; Left Padding; Right Padding |
| Tabs | Show Shortcut Hints |

### Selection & Clipboard

| Group | Settings |
|---|---|
| Selection | Copy on Select; Smart Double-Click; App Selection Modifier; Block Selection Modifier |
| Paste | Confirm Multi-Line Paste; Confirm Above |

### Mouse & Trackpad

| Group | Settings |
|---|---|
| Pointer | Text Cursor Only Over Text |
| Mouse Wheel | Wheel Speed; Lines per Notch |
| Trackpad | Trackpad Speed |
| Links | Underline Links; Link Underline; Force Link Color; Distinct Link Kinds; Open Links with a Click; Links Clickable Under Mouse Reporting |

### Sessions

| Group | Settings |
|---|---|
| Remote Sessions | Auto-Install Host on Connect |
| Session Persistence | Restore Last Session on Launch |

### Terminal

| Group | Settings |
|---|---|
| Scrollback | History Lines |
| Character Encoding | Input Encoding |
| Terminal Identity | Program; Version |

### Notifications

| Group | Settings |
|---|---|
| Notifications | Enable Notifications; Notification Sound |
| Bell | Audible Bell; Visual Bell |
| Dock | Bounce Dock Icon; Dock Badge |

### Accessibility

| Group | Settings |
|---|---|
| Color Vision | Colorblind Mode |

### Privacy & Security

| Group | Settings |
|---|---|
| Security | Secure Keyboard Entry; Detect Password Prompts; Secure Keyboard Entry at Password Prompts |
| Remote Clipboard | Serve This Mac’s Clipboard |

### Software Update

| Group | Settings |
|---|---|
| — | Check for updates automatically |

The switch is `[updates] check_automatically`, on by default: a daily check
that shows a new version and installs nothing until the person chooses to.
The footer names Ubiquitty > Check for Updates for a check now. The page is
absent from a build without the updater ([Application updates](auto-update.md#update-checks)).

### Window Titles

| Group | Settings |
|---|---|
| Title | Folder Icon; Title; Working Directory; Directory Format; App-Set Title; Active Process; Arguments; Shell Command Name; TTY Name; Profile Name; Dimensions |

### Tab Titles

| Group | Settings |
|---|---|
| Title | Title; Working Directory; Directory Format; App-Set Title; Active Process; Arguments; Shell Command Name; TTY Name; Profile Name; Dimensions |

### Pane Titles

| Group | Settings |
|---|---|
| Title | Title; Working Directory; Directory Format; App-Set Title; Active Process; Arguments; Shell Command Name; TTY Name; Profile Name; Dimensions |

## Custom editors

| Page | Controls and actions |
|---|---|
| Themes | Search; All/Light/Dark filter; terminal-preview selection; built-in/custom designation; Import; New; Duplicate; Export Theme as Ubiquitty TOML; Edit/Delete custom themes. Editor: Name, Dark, ANSI colors 0–15, Foreground, Background, Cursor, local preview, Cancel, Save. Existing names are immutable; duplicate to create a separately named palette. |
| Font Features | Font-advertised feature groups, checkbox rows for independent stylistic/contextual features, radio choices for exclusive groups, and a compact character-variant grid. Before/after samples use affected glyphs measured from that font. Variable axes include reset; Advanced Specification edits features and variations and stays synchronized with the selectors. Available controls depend on the font. |
| Fallback Fonts | General symbol/CJK/emoji choices; character/range overrides showing the range and selected family; add characters or a U+ range; script fallback selection; add/remove routing rules; resolution-order explanation. |
| Keyboard | Binding list; New/Edit/Delete; shortcut capture; action selection or custom action text. |
| Macros | Macro list; New/Edit/Delete; Name and text/escape-sequence body; use through a keyboard binding. |
| Profiles | New/Edit/Duplicate/Delete; Name; parent profile (Based on); Allow Export; optional theme chooser, font family, symbol fallback, font size, line spacing, four padding edges, hidden titlebar, local process-exit policy, and startup host. Inherit and explicit values remain distinct. An empty startup-host override means local shell. The editor scrolls independently and saves a draft; existing names are immutable. Export produces a presentation profile; Import opens a review with Apply to Window, Save on This Mac, and Cancel. |
| Tags | Tag Color Strength (title bar and tabs, 50% default); New/Edit/Delete; Name; preset/custom color; icon (searchable Phosphor set) and its Fill/Regular weight; host match; profile match; Quiet/Loud prominence. |
| Vector Graphics | Theme/custom source; beam and background colors; Bright Pen; Glowing Vectors. |
| Platform Overrides | macOS/Linux target; per-field override enablement, inherited value, and editor for Theme, Font Family, Symbol Fallback, Font Size, Line Spacing, four padding edges, and Startup Host. |
| Agents | Existing token label, scopes, expiry; issue and revoke actions. Issue sheet: label and capability scopes; newly issued secret is shown for copying. |

A parent's available choices exclude itself and any descendant, preventing cycles
from the editor. Missing existing parents remain visible as unavailable rather
than being silently erased. Opening and saving a profile preserves absent scope,
parent linkage, and titlebar inheritance. Numeric ranges use the shared schema.

## Shared visual and interaction rules

Use native AppKit and SwiftUI navigation and controls. The following rules
define the shared presentation of catalogue pages.

- Native full-content split window, native navigation toolbar, and the system's
  sidebar material. No separately painted titlebar or extra glass behind forms.
- Search occupies its own fixed sidebar region; the category list has a separate
  clipped scroll viewport. The detail column scrolls independently.
- A 224-point preferred sidebar, 20-point content margins, 13-point body text,
  compact native controls, 20-point category icons, and 12-point group corners.
  Category symbols fit inside 70% of each tile; the continuous tile radius is
  28% of its size.
- Light-mode content is white with `#f7f7f7` groups and quiet inset separators.
  Dark mode uses a separate opaque group surface; increased contrast adds a
  visible boundary. Native accent color determines selection.
- Control pages begin with their controls. An overview can introduce its topic
  briefly. Navigation into larger editors uses a full-width disclosure row.
- Related controls share a group. Section headings are primary text; supporting
  explanations use secondary text, wrap to the available width, and explain consequences.
- Font, fallback, and range selectors use native pop-up menus and open with the
  current value selected. Configuration notifications refresh all bound controls.
- The pinned preview is a process-free `TerminalSurface` using the normal Core
  model, font routing, shaping, and Metal renderer. Its sample selection and view
  identity survive navigation between font subpages. Cursor samples include active
  and inactive focus, blinking, and short/long movement.
- Feature grouping uses CoreText numeric identifiers or OpenType tags, independent
  of localized display names. Unknown specimens have no invented example.
- Immediate controls apply immediately. Text commits on Return or focus loss.
  Collection editors use Cancel/Save drafts. Opening an editor is read-only.
- Visual selection uses both an outline and a checkmark/accessible selected value.
  Reduce Motion disables positional search animation; search reveal retains an
  opacity highlight. Native controls provide keyboard and accessibility behavior.

## Contract validation

Catalogue checks must cover unique destinations, search matching, nested
breadcrumbs, navigation history, and unknown destinations. Native UI checks
must cover independent scrolling at minimum and larger sizes, keyboard focus,
live configuration refresh, text commit, and Cancel/Save behavior.

Profile checks must preserve inheritance and explicit values through a save
round trip. Theme selection must preserve automatic mode when appropriate.
Font previews must use the actual terminal model, keep their identity across
navigation, and show the shaping and fallback behavior that terminal windows use.
