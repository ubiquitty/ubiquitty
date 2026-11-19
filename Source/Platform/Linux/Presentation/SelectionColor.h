// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Rendering/OverlayGeometry.h"

#include <cstdint>

namespace Ubiquitty::Linux::Presentation {

/// How strongly a focused selection shows the desktop's accent: libadwaita's
/// text selection, `color-mix(accent-bg 30%, transparent)`.
inline constexpr float focusedSelectionStrength = 0.30f;
/// How strongly an unfocused selection shows the view's ink: libadwaita's
/// `color-mix(view-fg 10%, transparent)`, the grey of a text view in an
/// inactive window or a widget without the keyboard.
inline constexpr float unfocusedSelectionStrength = 0.10f;

/// Whether a pane holds the keyboard in an active window, which decides the
/// colour its selection takes.
enum class SelectionFocus : std::uint8_t {
    /// The pane holds the keyboard and its window is active.
    Focused,
    /// The window is inactive, or another pane holds the keyboard.
    Unfocused,
};

/// The colour that, washed over `ground` at Core's `nativeSelectionOpacity`,
/// draws what `overlay` mixed into `ground` at `strength` draws.
///
/// Core washes a native selection at one fixed opacity; a desktop draws its
/// selection at its own. Solving the one wash for the other lands on the
/// desktop's colour exactly over the terminal's default background, the
/// ground nearly every selected cell has.
///
/// - Parameters:
///   - ground: The frame's default background, opaque.
///   - overlay: The colour the desktop mixes in, opaque.
///   - strength: How much of `overlay` the desktop mixes in, 0 to 1.
/// - Returns: The colour to report, opaque, each channel clamped to 0…1.
[[nodiscard]] Rendering::Vec4 nativeWashMatching(Rendering::Vec4 ground, Rendering::Vec4 overlay, float strength);

/// The colour a GNOME desktop selects text in, for one pane's frame.
///
/// - Parameters:
///   - ground: The frame's default background, opaque.
///   - accent: The desktop's accent background colour, opaque.
///   - focus: Whether the pane holds the keyboard in an active window.
/// - Returns: The colour to report as the platform's selection colour.
[[nodiscard]] Rendering::Vec4 desktopSelectionColor(Rendering::Vec4 ground, Rendering::Vec4 accent, SelectionFocus focus);

} // namespace Ubiquitty::Linux::Presentation
