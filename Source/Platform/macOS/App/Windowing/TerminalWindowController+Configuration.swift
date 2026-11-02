// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TerminalWindowController+Configuration.swift — every open window follows the
// live configuration through one subscription.
//
// A settings row, a menu toggle and a save from an editor all reach Core the
// same way: a document is configured, and Core tells each subscriber once. The
// window owner holds the one subscription, folds the new document into the
// renderer's configuration, and re-applies to every open window what moved —
// the faces when the typography moved, the frame style when it moved, the
// storage tube, the pacing, the terminal state, the chrome. Nothing upstream
// names a window or a setting; a setter that broadcast to the windows it
// thought it touched is how a setting reached one shell and not the other.
//

import AppKit
internal import UbiquittyAppleCallbacks
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// The one subscription every open window follows the configuration
    /// through, and what it last applied.
    @MainActor
    final class ConfigurationFollower {
        /// Core's registration; the follower lives for the process.
        private var subscription: Ubiquitty.Preferences.ConfigurationSubscription
        /// The renderer configuration the open windows were last given.
        fileprivate var applied: Ubiquitty.Rendering.RenderConfiguration
        /// The window facts the open windows were last given.
        fileprivate var appliedWindowFacts: WindowFacts

        init() {
            applied = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
            appliedWindowFacts = WindowFacts(Ubiquitty.Preferences.values().pointee)
            subscription = Ubiquitty.Preferences.ConfigurationSubscription.notifying(
                Ubiquitty.Apple.ownedCallback {
                    // Core calls subscribers on the main thread, after the
                    // live values are replaced.
                    MainActor.assumeIsolated { TerminalWindowController.applyConfigurationToOpenWindows() }
                }
            )
        }
    }

    /// The facts a window holds per window rather than per frame, whose apply
    /// is not idempotent: re-hiding the title bar would undo the reader's
    /// per-window toggle, so each runs when its setting moved.
    struct WindowFacts: Equatable {
        var hidesTitleBar: Bool
        var usesNativeTitlebar: Bool

        init(_ values: borrowing Ubiquitty.Preferences.Values) {
            hidesTitleBar = Ubiquitty.Preferences.Effective.hideTitleBar(values)
            usesNativeTitlebar = Ubiquitty.Preferences.Effective.titlebarStyle(values) == .Native
        }
    }

    /// The follower, made on first use.
    private static var configurationFollower: ConfigurationFollower?

    /// Starts following the live configuration; idempotent.
    ///
    /// Called where a window is made, so the first window to exist is the
    /// first one to hear a change.
    static func followConfiguration() {
        guard configurationFollower == nil else { return }
        configurationFollower = ConfigurationFollower()
    }

    /// Re-applies the live configuration to every open window: the faces and
    /// the title bar's stateful pieces when they moved, everything else on
    /// every configure.
    ///
    /// The subscription's one body.
    static func applyConfigurationToOpenWindows() {
        guard let follower = configurationFollower else { return }
        let configuration = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
        let previous = follower.applied
        follower.applied = configuration
        let values = Ubiquitty.Preferences.values()
        let facts = WindowFacts(values.pointee)
        let previousFacts = follower.appliedWindowFacts
        follower.appliedWindowFacts = facts

        // Terminal state — the cursor's shape and blink, the bell, the
        // encoding, the triggers — is re-seeded on every terminal.
        applyTerminalPreferencesToOpenWindows()

        var typographyChanged = false
        for controller in spawnedControllers {
            let next = controller.windowRenderConfiguration
            if let applied = controller.appliedTypographyConfiguration,
                next.hasSameTypography(applied), next.usesDisplayP3 == applied.usesDisplayP3
            {
                continue
            }
            controller.applyWindowTypography()
            typographyChanged = true
        }
        if typographyChanged { NotificationCenter.default.post(name: .terminalAppearanceChanged, object: nil) }
        // The frame style, the storage tube and the pacing are re-applied on
        // every configure: they cut no sheets, and a window whose ground the
        // system's switches moved since the last apply takes the configured
        // answer again rather than the one it was left with.
        applyAppearanceToOpenWindows()
        applyTektronixSettingsToOpenWindows()
        applyRenderPreferencesToOpenWindows()
        if configuration.colorblindMode != previous.colorblindMode {
            applyThemeToOpenWindows()
        }
        if facts.hidesTitleBar != previousFacts.hidesTitleBar {
            applyHideTitleBarToOpenWindows()
        }
        if facts.usesNativeTitlebar != previousFacts.usesNativeTitlebar {
            applyTitlebarStyleToOpenWindows()
        }
        // The chrome re-derives its titles, corners and snap from the
        // configuration and holds no state a repeat would disturb.
        applyWindowChromeToOpenWindows()
        applyTitleCompositionToOpenWindows()
        for controller in spawnedControllers {
            controller.applyWindowTags()
            // Held per chrome and set where a bar is made, so a window open
            // across the change has nothing else to learn it from.
            controller.applyPaneTitleBars()
        }
        refreshTabAccessoriesForOpenWindows()
        refreshClosePolicy()
        applyScrollPreferencesToOpenWindows()
        applyShowBuildHashToOpenWindows()
        showConfigurationDiagnostics()
    }
}
