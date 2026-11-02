// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PlatformSelection.swift — the system's selection colour, reported to the frame.
//
// Whether a selection is drawn in the system's colour is Core's decision, made
// in the capture from `[selection] style`; the colour itself is a fact only the
// platform holds, and both macOS arms report it through this one function so
// that they select in the same colour.

import UbiquittyCore

#if canImport(AppKit)
import AppKit
#endif

/// Writes the frame's selection style and the platform's selection colour.
///
/// The colour is the one a text view on the same desktop fills a selection
/// with: the Highlight colour while the view has focus, the unemphasised grey
/// while it does not. It is resolved under the appearance the frame's default
/// background reads as — the rule the window's own appearance follows — so a
/// light theme in a dark session selects in the light colour, as a text view in
/// that window would.
///
/// Resolved on every frame that draws a native selection rather than kept,
/// because the system colour follows the Highlight and accent settings and a
/// kept copy would draw the old one until something else invalidated it; the
/// resolve costs about two microseconds, and a frame without a selection pays
/// nothing.
///
/// Call after ``applyFrameStyle(to:_:)``, whose default background this reads.
///
/// - Parameters:
///   - style: The style block to write into.
///   - selectionStyle: The configured `[selection] style`.
///   - isFocused: Whether the view has keyboard focus.
///   - hasSelection: Whether the frame draws a selection at all.
public func applyPlatformSelection(
    to style: inout Ubiquitty.Rendering.TerminalSnapshotStyle,
    selectionStyle: Ubiquitty.Rendering.SelectionStyle,
    isFocused: Bool,
    hasSelection: Bool
) {
    style.selectionStyle = selectionStyle
    style.platformSelectionColor = Ubiquitty.Rendering.Vec4()
    #if canImport(AppKit)
    guard hasSelection, selectionStyle == .Native else {
        return
    }
    let background = style.uniformDefaultBackground
    let byte = { (channel: Float) in UInt8(max(0, min(255, (channel * 255).rounded()))) }
    let isDark =
        Ubiquitty.perceivedLightness(
            Ubiquitty.ColorRGBA(red: byte(background.x), green: byte(background.y), blue: byte(background.z), alpha: 255)
        ) < 128
    NSAppearance(named: isDark ? .darkAqua : .aqua)?
        .performAsCurrentDrawingAppearance {
            let system = isFocused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
            guard let color = system.usingColorSpace(.sRGB) else {
                return
            }
            style.platformSelectionColor.x = Float(color.redComponent)
            style.platformSelectionColor.y = Float(color.greenComponent)
            style.platformSelectionColor.z = Float(color.blueComponent)
            style.platformSelectionColor.w = 1
        }
    #endif
}
