<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Native terminal vibrancy

The macOS renderer presents terminal ink through an `NSVisualEffectView` material
host. The Core resolves terminal colors and chooses the ink contribution; AppKit
supplies the appearance-dependent semantic colors and performs backdrop blending.
The terminal model, ANSI palette queries, and exported terminal contents retain
the program's original colors.

Auto appearance defaults to Noir Clair for Light and Noir for Dark. System uses
native colors in light appearance and a balanced Xcode Dark palette in dark
appearance. Selecting System in either automatic theme picker sets both slots.
The default color space is Display P3.

The dark palette's green (`#00d9b2`) and purple (`#d896fe`) anchor the blue and
yellow at mean OKLCH lightness 0.78079, interpreting the encoded channels as
Display P3. Blue is `#89bbff`; yellow is `#eca800`, in both normal and bright
slots. Their hues follow the source palette; chroma is limited by the P3 gamut
at the target lightness. Conversion follows the
[CSS Color 4 matrices](https://www.w3.org/TR/css-color-4/#color-conversion-code)
and [Oklab](https://bottosson.github.io/posts/oklab/), with 8-bit rounding.

The default terminal font is SF Mono when available, otherwise bundled JetBrains
Mono, at 12 pt.

Wide Glyph Scale defaults to 1.2. The underline Skip-Ink Gap defaults to 1.75 pt.

Background Blur and Background Vibrancy default on. Background opacity defaults
to 100%, where neither effect runs; lowering opacity activates them.

With blur off, the titlebar retains the same theme tint and opacity as the
terminal body.

Opening a second tab grows the window downward by the tab strip's height to
preserve terminal rows. Growth stops at the screen's usable bottom edge,
including the Dock; full-screen windows keep their frame.

Perceptual Text Contrast is enabled by default in **Settings → Appearance →
Background**, independently of blur. The `text_contrast` boolean can be set in
`[appearance]` or a theme; an explicit application setting takes precedence.
Ordinary text below the APCA floor is adjusted in lightness while retaining its
hue and saturation. The calculation uses each cell's resolved background, so a
light-themed application's dark ink can remain readable in a dark terminal,
while readable black-on-white cells keep their colors. Dim text has a lower
floor; concealed and equal-color text remain concealed. Backgrounds and filled
Powerline transitions retain their colors. Native vibrant ink keeps its own
continuous hierarchy instead of receiving this contrast floor.

## Text and background vibrancy

Text Vibrancy blends terminal ink with the window's native material, and
**Settings → Appearance → Background → Background Vibrancy** does the same for
explicit cell backgrounds. Both need Background Blur and take effect only
below 100% background opacity. Background Vibrancy defaults on; Text Vibrancy
is off unless a theme turns it on, as the Glass themes do. In `[appearance]`
the keys are `text_contrast_on_blur` and `background_vibrancy`; a theme sets
`text_vibrancy` and `background_vibrancy`, and an explicit application setting
takes precedence over the theme. Themes choose the ink of command marks with
`terminal_marks = "palette"`, `"primary"`, `"secondary"` or `"tertiary"`;
failed commands keep the theme's error color. The program's colors are
unchanged in the terminal model, in palette queries and in copied text.
Accessibility Reduce Transparency turns both effects off.

## Native appearance boundary

Resolve semantic colors from the active AppKit appearance. Ordinary alpha-based
label colors and vibrant ink are not interchangeable: the material determines
how ink combines with the backdrop. Do not embed sampled semantic RGB or alpha
values, or request private compositing filters.

The HUD material owns its fill, saturation, and blur. Zero theme opacity removes
the application's tint, not the native material's fill. Accessibility Reduce
Transparency disables the translucent material and native text layer.

Native tab-track integration must preserve AppKit's blur, vibrancy, focus
behavior, and selection animation. Any observation of the private track-layer
hierarchy is confined to that adapter, must tolerate replacement layers, and
must restore unmodified behavior when the native titlebar style is selected.
No private method or filter is invoked. The macOS 26 glass-style path uses the
public `NSGlassEffectView.style` property.

Apple's [NSVisualEffectView documentation](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
defines the material hierarchy and semantic-color behavior; private layer names
and implementations are not stable API contracts.

## Verification

The native-glass, Powerline, selection and tab-track UI scenarios hold these
behaviors.
