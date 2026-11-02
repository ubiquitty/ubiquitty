// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Apply a Theme to a Terminal's LIVE 16-bit TermPalette (distinct from
// CellPalette::fromTheme, which fills the 8-bit CellPalette). Sets ANSI 0-15 plus
// the default foreground/background/cursor; 16-255 stay the xterm cube seeded at
// construction. Dependency arrow points Themes -> Core, never the other way.

#include "Core/TermPalette.h"
#include "Core/Themes/Themes.h"
#include "Forward.h"

namespace Ubiquitty::Themes {

/// Applies a theme's colours to a terminal's live palette.
///
/// Writes the 16 ANSI slots plus the default foreground, background and cursor.
/// Indices 16 through 255 are untouched — they are the xterm cube, seeded
/// separately — so a caller changing the theme must refill the cube or the
/// extended range keeps describing the palette that was replaced.
///
/// - Parameters:
///   - theme: The colours to apply.
///   - palette: The live palette to write into.
void applyToTermPalette(const Theme&, Ubiquitty::TermPalette&);

// Resolve a theme by index and apply it as the Terminal's palette authority
// (applyToTermPalette + cube fill + the baseline OSC 104/110-119 resets restore
// to). False when the index names no theme.
[[nodiscard]] bool applyThemeToTerminal(Ubiquitty::Terminal&, int themeIndex);

} // namespace Ubiquitty::Themes
