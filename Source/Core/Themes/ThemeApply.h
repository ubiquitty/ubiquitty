// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The theme list, and a theme's colours as the bytes a palette apply takes.
//
// Themes.h and TermPaletteFromTheme.h carry the whole model — Theme, its colour
// slots, TermPalette — and reach Preferences and the palette through their
// includes. A frontend picking a theme wants none of that: it wants a list of
// names and the colours of one. This header names no type of its own and
// includes nothing, which is what lets it be imported beside the terminal model
// rather than dragging a second definition of what those headers already own.
//
// Colours come out as bytes rather than as a TermPalette because that is what
// the one palette-apply path takes (`Runtime::TerminalSession::applyPalette`),
// and a second way to write a palette is a second place for the write to be
// wrong. A theme carries only its sixteen ANSI colours and three named ones;
// indices 16-255 are the xterm cube, which this fills in the way every other
// consumer gets it.

namespace Ubiquitty::Themes {

/// Represents the operating-system appearance for automatic theme selection.
enum class AutomaticAppearance {
    Light,
    Dark,
};

/// How many themes there are, built-in and registered.
[[nodiscard]] int themeCount();

/// The theme's display name.
///
/// - Parameter index: 0 ..< ``themeCount``.
/// - Returns: A nul-terminated name Core owns for the life of the process, or
///   nullptr when there is no theme at `index`.
[[nodiscard]] const char* themeName(int index);

/// Whether the theme at `index` is a dark one.
///
/// Core's own answer, so a picker cannot group themes differently from the
/// scheme a program is told about.
[[nodiscard]] bool isThemeDark(int index);

/// Resolves the configured automatic theme for one system appearance.
///
/// - Parameter appearance: The operating system's effective appearance.
/// - Returns: A matching registered theme index, or -1 when none exists.
[[nodiscard]] int resolvedAutomaticThemeIndex(AutomaticAppearance appearance);

/// Writes a theme's colours as the two tables a palette apply takes.
///
/// - Parameters:
///   - index: The theme's index.
///   - indexedRGB: 768 bytes, red/green/blue for each index 0-255.
///   - defaultsRGB: 9 bytes — default foreground, default background, cursor,
///     three each in that order.
///   - indexedAlpha: 256 bytes, one foreground opacity per index — the
///     theme's for the sixteen it carries, opaque for the cube — or null to
///     skip it.
/// - Returns: Whether there was a theme at `index` and the two colour
///   pointers were given.
[[nodiscard]] bool themeColorBytes(int index, unsigned char* indexedRGB, unsigned char* defaultsRGB, unsigned char* indexedAlpha);

} // namespace Ubiquitty::Themes
