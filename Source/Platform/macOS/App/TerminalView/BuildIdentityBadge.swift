// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// BuildIdentityBadge.swift — the build a window is running, named in its
// title row: "<version> (<hash>)", ", modified" after the hash for a tree
// with uncommitted changes, and "[branch]" after that for a build off main.
//
// It tells two builds apart at a glance, which is a developer's question and
// not a reader's, so it stays out of the row until `[debug] show_build_hash`
// (or View > Show Build Hash) asks for it. It is chrome rather than content:
// it lives in the title row's accessory bar and never over the grid.
//
// The identity is the build's, written into the bundle's Info.plist when the
// build is configured, so every window of one process names the same build.
// Which ink reads on the title row is Core's answer
// (`Themes::Contrast::chromeBadgeInk`); this view paints it. Both shells
// install this one badge, so the two cannot name a build differently.

@preconcurrency import AppKit
import UbiquittyCore

/// The build identity label in a window's accessory bar.
@objc(UBBuildIdentityBadge)
public final class BuildIdentityBadge: NSTextField {
    /// Innermost in the row: every live indicator outranks a build label.
    @objc
    public static let priority = 0

    /// The Info.plist key the build writes its identity under.
    @objc
    public static let identityInfoKey = "UBBuildIdentity"

    /// The type size before `[appearance] ui_font_scale`: small enough that
    /// the label reads as a footnote to the title beside it.
    private static let pointSize: CGFloat = 9

    /// The identity this build carries, or nil for a bundle that names none.
    @objc
    public static var identity: String? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: identityInfoKey) as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    /// Whether `[debug] show_build_hash` asks for the badge.
    private static var isShownByPreference: Bool {
        Ubiquitty.Preferences.Effective.debugShowBuildHash(Ubiquitty.Preferences.values().pointee)
    }

    private weak var bar: ChromeAccessoryBar?

    /// The theme foreground and wash the ink was last resolved from, so a
    /// title row repainted on every screen update resolves it once per change.
    private var inkInputs: (themeForeground: UInt32, wash: UInt32)?

    /// Puts the badge into a bar, shown or hidden as the preference says.
    ///
    /// - Parameter bar: The window's accessory bar.
    /// - Returns: The installed badge, or nil for a bundle that names no build.
    @objc
    @discardableResult
    public static func install(in bar: ChromeAccessoryBar) -> BuildIdentityBadge? {
        guard let identity else { return nil }
        let badge = BuildIdentityBadge(labelWithString: identity)
        badge.bar = bar
        badge.font = .monospacedSystemFont(ofSize: ChromeTypography.scaled(pointSize), weight: .regular)
        // The system's secondary ink until a themed title row inks it.
        badge.textColor = .secondaryLabelColor
        badge.setAccessibilityLabel("Build \(identity)")
        badge.sizeToFit()
        badge.isHidden = !isShownByPreference
        bar.add(badge, priority: priority)
        return badge
    }

    /// The badge a bar holds, if any.
    ///
    /// - Parameter bar: A window's accessory bar.
    /// - Returns: The badge, or nil for a bar it was never installed in.
    public static func badge(in bar: ChromeAccessoryBar) -> BuildIdentityBadge? {
        bar.subviews.lazy.compactMap { $0 as? BuildIdentityBadge }.first
    }

    /// Shows or hides the badge as `[debug] show_build_hash` now says.
    @objc
    public func applyPreference() {
        bar?.setShown(self, Self.isShownByPreference)
    }

    /// Inks the text for a themed title row: Core's ink for the theme's
    /// foreground over the colour the row is washed with, drawn at the
    /// badge's coverage.
    ///
    /// - Parameters:
    ///   - themeForeground: The theme's default foreground, packed 0xRRGGBB.
    ///   - wash: The colour the title row is painted, packed 0xRRGGBB — a
    ///     letterbox fill while a program holds one, the theme's background
    ///     otherwise.
    @objc(applyInkForThemeForeground:wash:)
    public func applyInk(themeForeground: UInt32, wash: UInt32) {
        if let inkInputs, inkInputs.themeForeground == themeForeground, inkInputs.wash == wash {
            return
        }
        inkInputs = (themeForeground, wash)
        let ink = Ubiquitty.Themes.Contrast.chromeBadgeInk(themeForeground, wash)
        textColor = NSColor(
            srgbRed: CGFloat((ink >> 16) & 0xFF) / 255,
            green: CGFloat((ink >> 8) & 0xFF) / 255,
            blue: CGFloat(ink & 0xFF) / 255,
            alpha: CGFloat(Ubiquitty.Themes.Contrast.chromeBadgeCoverage)
        )
    }

    /// Inks the text for the system's own title row: the secondary label
    /// colour, which follows the window's appearance as the row does.
    @objc
    public func applySystemInk() {
        inkInputs = nil
        textColor = .secondaryLabelColor
    }
}
