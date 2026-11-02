// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SystemDisplayOptions.swift — the system accessibility display options the
// shell's drawing answers to, read in one place.
//
// Reduce Motion, Reduce Transparency and Increase Contrast are the reader's
// requests to the whole system. Every window, overlay and reveal that honours
// them would, asked at its own call site, make what a UI scenario proves
// depend on the machine it runs on: GitHub's hosted macOS image turns Reduce
// Motion and Reduce Transparency on while it is built, and scenarios asserting
// a flight or a translucent window failed there and passed on a desk. Read
// through one source, a scenario pins the options it depends on and tests the
// reduced behaviour as well as the default one.

import AppKit

/// The system accessibility display options the shell's drawing answers to.
///
/// A shipping app answers what the system reports. A UI scenario pins the
/// options it depends on with ``pinForTesting(reduceMotion:reduceTransparency:increaseContrast:)``
/// and hands them back to the system with ``unpinForTesting()``. Both post the
/// notification the system posts when a switch moves, so open windows follow
/// exactly as they would for the reader.
@objc(UBSystemDisplayOptions)
public final class SystemDisplayOptions: NSObject {
    private struct Pinned {
        var shouldReduceMotion: Bool
        var shouldReduceTransparency: Bool
        var shouldIncreaseContrast: Bool
    }

    /// The options a scenario pinned, or nil for the system's; written on the
    /// main thread only, by the scenario harness.
    nonisolated(unsafe) private static var pinned: Pinned?

    /// Whether movement should be replaced by an immediate change.
    @objc
    public static var shouldReduceMotion: Bool {
        pinned?.shouldReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether translucent materials should be drawn opaque.
    @objc
    public static var shouldReduceTransparency: Bool {
        pinned?.shouldReduceTransparency ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Whether colours should be drawn at higher contrast.
    @objc
    public static var shouldIncreaseContrast: Bool {
        pinned?.shouldIncreaseContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Pins the options for a UI scenario, as if the reader had set them.
    ///
    /// - Parameters:
    ///   - reduceMotion: The Reduce Motion answer to give.
    ///   - reduceTransparency: The Reduce Transparency answer to give.
    ///   - increaseContrast: The Increase Contrast answer to give.
    package static func pinForTesting(reduceMotion: Bool, reduceTransparency: Bool, increaseContrast: Bool = false) {
        pinned = Pinned(
            shouldReduceMotion: reduceMotion,
            shouldReduceTransparency: reduceTransparency,
            shouldIncreaseContrast: increaseContrast
        )
        announceChange()
    }

    /// Hands the options back to the system's answer.
    package static func unpinForTesting() {
        guard pinned != nil else {
            return
        }
        pinned = nil
        announceChange()
    }

    /// Posts where and what the system posts when a display option moves.
    private static func announceChange() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
    }
}
