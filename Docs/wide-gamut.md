<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Surface color space

The `[appearance] color_space` setting selects sRGB or Display P3 for the
terminal surface. This is a surface-wide interpretation, not a per-run escape
sequence.

## Presentation contract

`SurfaceRenderer` tags its `CAMetalLayer` with the selected color space.
Changing the setting re-tags the live layer; it does not rewrite terminal
palette entries or SGR RGB values. The same numeric RGB triplet therefore
denotes a different color under Display P3 than under sRGB. Choosing P3 is not
an sRGB-to-P3 color-preserving conversion.

The renderer's sRGB pixel format supplies the transfer function for blending;
the layer color-space tag identifies the primaries used for presentation.
Background images are decoded into the selected destination color space.

Display P3 describes gamut, not dynamic range. The surface uses normalized
color values rather than extended-range HDR output. There is no per-run
wide-gamut selector.

## References

- `Source/UbiquittyKit/Swift/SurfaceRenderer.swift`: layer preparation and
  color-space changes.
- `Source/UbiquittyRenderKit/BackdropImage.swift`: color-managed backdrop decode.
- [Settings catalog](settings-catalog.md): accepted setting values.
