<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Accessibility

The default macOS terminal surface exposes its active screen as accessible text.
VoiceOver can read text, navigate lines, inspect the caret, and read selected text.
The Linux frontend provides a corresponding GTK accessibility text interface.

New output updates the accessible value, but Ubiquitty does not announce each
new line automatically. There is no prompt-to-prompt rotor or actionable hyperlink
rotor. These limits matter when following a running command without looking at the screen.

Visual adjustments are in **Settings ▸ Accessibility**. Contrast, motion, and
transparency also follow the supported system accessibility settings.
See the [terminal accessibility specification](../voiceover-accessibility-design.md)
for technical requirements.
