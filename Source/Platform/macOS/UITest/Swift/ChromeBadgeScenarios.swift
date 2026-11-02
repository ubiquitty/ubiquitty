// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ChromeBadgeScenarios.swift — the badges a Swift-shell title row wears, and
// whether their text reads on what it is painted over.
//
// Core pins the contrast answers over known colour pairs (test_contrast,
// test_tmux_session_badge). These read the colours a badge was actually given
// — the build badge's text colour, a session pill's fill and label — and ask
// the same APCA measure of them, so a badge that painted some other rule, or
// painted Core's answer against a colour the row is not washed with, fails
// here rather than on a reader's screen.

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

/// A colour packed 0xRRGGBB in sRGB, each channel rounded to its byte.
///
/// - Parameter color: The colour a view was painted with.
/// - Returns: The packed colour, or nil for one with no sRGB form.
@MainActor
private func packedSRGB(_ color: NSColor?) -> UInt32? {
    guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
    let byte = { (channel: CGFloat) in UInt32(UInt8(clamping: Int((channel * 255).rounded()))) }
    return (byte(srgb.redComponent) << 16) | (byte(srgb.greenComponent) << 8) | byte(srgb.blueComponent)
}

/// The View menu's Show Build Hash item, as the app installed it.
///
/// - Returns: The menu holding the item and the item's index, or nil when the
///   View menu carries no such item.
@MainActor
private func showBuildHashItem() -> (menu: NSMenu, index: Int)? {
    guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu,
        let index = view.items.firstIndex(where: { $0.title == "Show Build Hash" })
    else {
        return nil
    }
    return (view, index)
}

/// The two answers `[debug] show_build_hash` gives.
private enum BuildHashPreference {
    case shown
    case hidden

    /// What the preference says now.
    static var current: BuildHashPreference {
        Ubiquitty.Preferences.Effective.debugShowBuildHash(Ubiquitty.Preferences.values().pointee) ? .shown : .hidden
    }
}

/// Chooses Show Build Hash from the View menu until the preference gives
/// `state`, the way a reader toggles it.
///
/// - Parameter state: The answer to leave the preference giving.
@MainActor
private func chooseShowBuildHash(until state: BuildHashPreference) {
    guard let item = showBuildHashItem() else { return }
    if BuildHashPreference.current != state {
        item.menu.performActionForItem(at: item.index)
    }
}

/// The DECSET 7402 Color letterbox over `fill`, then the mode.
private func colourLetterbox(_ fill: UInt32) -> String {
    "\u{1b}]7402;fill=\(String(format: "%06x", fill))\u{07}\u{1b}[?7402h"
}

private let fullscreenContentOff = "\u{1b}[?7402l"

@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Measures visible symbol ink at two pixels per point, excluding transparent padding.
@MainActor
private func symbolInkBounds(_ image: NSImage) -> NSRect? {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    var ink = NSRect.null
    for y in 0..<32 {
        for x in 0..<32 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            ink = ink.union(NSRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return ink.isNull ? nil : ink
}

/// Registers the title-row badge scenarios with the UI-test runner.
enum ChromeBadgeScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("title_row_status_symbols_share_geometry") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let window = NSWindow(
                    contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 28),
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let bar = ChromeAccessoryBar(scope: .window, heightInPoints: 28)
                window.contentView = bar
                let lock = SecureKeyboardEntryLock.install(in: bar)
                let clipboard = ClipboardScopeIndicator.install(in: bar)
                bar.setShown(lock, true)
                for scope in [Ubiquitty.Clipboard.Scope.host, .client] {
                    ClipboardScopeIndicator.report(scope, for: window)
                    t.expect(!clipboard.isHidden, desc: "each remote clipboard source has a visible selector")
                    t.expect(lock.frame.size == clipboard.frame.size, desc: "status symbols occupy equal slots")
                    t.expect(lock.frame.midY == clipboard.frame.midY, desc: "status slots share a vertical center")
                    t.expect(
                        lock.frame.minX - clipboard.frame.maxX == ChromeAccessoryBar.gapInPoints,
                        desc: "the clipboard and lock keep the standard accessory spacing"
                    )
                    guard let lockImage = lock.image, let clipboardImage = clipboard.image,
                        let lockInk = symbolInkBounds(lockImage), let clipboardInk = symbolInkBounds(clipboardImage),
                        let buttonImageRect = clipboard.cell?.imageRect(forBounds: clipboard.bounds)
                    else {
                        t.expect(false, desc: "both status symbols draw visible ink")
                        continue
                    }
                    t.expect(lockImage.size == clipboardImage.size, desc: "symbols share one image canvas")
                    t.expect(
                        buttonImageRect.size == lockImage.size
                            && buttonImageRect.midX == clipboard.bounds.midX
                            && buttonImageRect.midY == clipboard.bounds.midY,
                        desc: "the button draws the same centered canvas without title insets"
                    )
                    t.expect(
                        abs(lockInk.height - clipboardInk.height) <= 2
                            && abs(lockInk.midY - clipboardInk.midY) <= 1,
                        desc: "visible symbol heights and centers agree within one point"
                    )
                    t.expect(
                        clipboard.contentTintColor == (scope == .client ? .systemOrange : .secondaryLabelColor),
                        desc: "local clipboard access keeps its warning color"
                    )
                    t.expect(clipboard.accessibilityRole() == .popUpButton, desc: "clipboard remains an accessible selector")
                    t.expect(lock.accessibilityRole() == .image, desc: "the lock remains a noninteractive status image")
                }
                ClipboardScopeIndicator.report(.local, for: window)
                t.expect(clipboard.isHidden && clipboard.image == nil, desc: "local sessions do not show a clipboard selector")
            }
        }

        UBUITestRegister("swift_shell_build_badge_names_the_build_when_asked") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let identity = BuildIdentityBadge.identity else {
                    t.expect(false, desc: "the bundle names the build it was made from")
                    return
                }
                guard showBuildHashItem() != nil else {
                    t.expect(false, desc: "the View menu offers Show Build Hash")
                    return
                }
                let preferenceBefore = BuildHashPreference.current
                defer { chooseShowBuildHash(until: preferenceBefore) }
                chooseShowBuildHash(until: .hidden)

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                guard let badge = shell.buildIdentityBadge, let bar = badge.superview as? ChromeAccessoryBar else {
                    t.expect(false, desc: "the window's accessory bar carries a build badge")
                    return
                }
                t.expect(badge.stringValue == identity, desc: "the badge names the build (\(badge.stringValue))")
                t.expect(badge.isHidden, desc: "with show_build_hash off the badge stays out of the row")

                chooseShowBuildHash(until: .shown)
                t.pump(0.2)
                t.expect(BuildHashPreference.current == .shown, desc: "the View menu's toggle turns show_build_hash on")
                t.expect(!badge.isHidden, desc: "and the open window's badge shows")
                t.expect(badge.window === window, desc: "in the window's own title row, not over the grid")
                let others = bar.subviews.filter { $0 !== badge && !$0.isHidden }
                t.expect(
                    others.allSatisfy { $0.frame.minX > badge.frame.minX },
                    desc: "innermost of the row: every shown indicator sits nearer the trailing edge"
                )

                // A window opened while the preference stands reads it when
                // its bar is built.
                guard let second = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a second Swift-shell window opens")
                    return
                }
                defer { second.window?.close() }
                t.pump(0.4)
                t.expect(second.buildIdentityBadge?.isHidden == false, desc: "a window opened with it on shows its badge")

                chooseShowBuildHash(until: .hidden)
                t.pump(0.2)
                t.expect(badge.isHidden, desc: "turned off, the badge leaves the row")
                t.expect(second.buildIdentityBadge?.isHidden == true, desc: "in every open window")
            }
        }

        UBUITestRegister("swift_shell_build_badge_ink_reads_on_the_title_row_wash") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let wasNative =
                    Ubiquitty.Preferences.Effective.titlebarStyle(Ubiquitty.Preferences.values().pointee)
                    == Ubiquitty.Preferences.TitlebarStyle.Native
                let preferenceBefore = BuildHashPreference.current
                defer {
                    app.settingsSetTitlebarStyle(wasNative ? 1 : 0)
                    chooseShowBuildHash(until: preferenceBefore)
                }
                app.settingsSetTitlebarStyle(0) // themed
                chooseShowBuildHash(until: .shown)

                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer {
                    surface.feed(Data(fullscreenContentOff.utf8))
                    window.close()
                }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.applyChromeTheme()
                t.pump(0.2)
                guard let badge = shell.buildIdentityBadge, !badge.isHidden else {
                    t.expect(false, desc: "the window shows its build badge")
                    return
                }
                let coverage = CGFloat(Ubiquitty.Themes.Contrast.chromeBadgeCoverage)
                let foreground = shell.themeForeground(of: surface)
                // The ground the title row is painted when no letterbox holds
                // it: the published default background, as the chrome reads it.
                let snapshot = surface.drive.readSnapshot()
                let byte = { (channel: Float) in UInt32(UInt8(clamping: Int((channel * 255).rounded()))) }
                let background =
                    (byte(snapshot.defaultBackgroundRed) << 16) | (byte(snapshot.defaultBackgroundGreen) << 8)
                    | byte(snapshot.defaultBackgroundBlue)

                // Over the theme's own ground: Core's ink for that pair, at
                // the badge's coverage.
                let themedInk = Ubiquitty.Themes.Contrast.chromeBadgeInk(foreground, background)
                t.expect(
                    packedSRGB(badge.textColor) == themedInk,
                    desc:
                        "over the theme's ground the badge takes Core's ink (\(String(describing: packedSRGB(badge.textColor))) vs \(themedInk))"
                )
                t.expect(
                    abs((badge.textColor?.alphaComponent ?? 0) - coverage) < 0.01,
                    desc: "drawn at the badge's coverage"
                )

                // A letterbox fill of the foreground's own colour: the theme's
                // ink has no contrast at all against the wash, so an unfloored
                // badge vanishes into the row.
                surface.feed(Data(colourLetterbox(foreground).utf8))
                surface.needsDisplay = true
                let letterboxInk = Ubiquitty.Themes.Contrast.chromeBadgeInk(foreground, foreground)
                t.expect(
                    t.wait(until: { packedSRGB(badge.textColor) == letterboxInk }, timeout: 3),
                    desc:
                        "under the letterbox the badge takes Core's ink for the fill (\(String(describing: packedSRGB(badge.textColor))) vs \(letterboxInk))"
                )
                let inkUnderLetterbox = packedSRGB(badge.textColor) ?? foreground
                t.expect(inkUnderLetterbox != foreground, desc: "the theme's foreground was walked off the fill it matches")
                t.expect(
                    abs(Ubiquitty.Themes.Contrast.apcaLc(inkUnderLetterbox, foreground))
                        >= Ubiquitty.Themes.Contrast.lcSecondary - 0.5,
                    desc: "and clears APCA's secondary floor against it"
                )
                t.expect(
                    abs((badge.textColor?.alphaComponent ?? 0) - coverage) < 0.01,
                    desc: "still at the badge's coverage"
                )

                // Off: the row goes back to the theme's ground, and the ink
                // with it.
                surface.feed(Data(fullscreenContentOff.utf8))
                surface.needsDisplay = true
                t.expect(
                    t.wait(until: { packedSRGB(badge.textColor) == themedInk }, timeout: 3),
                    desc: "after the reset the badge takes the theme's ink again"
                )

                // A native title row is the system's, and so is the ink.
                app.settingsSetTitlebarStyle(1)
                t.pump(0.2)
                t.expect(
                    badge.textColor == NSColor.secondaryLabelColor,
                    desc: "a native title row inks the badge in the system's secondary label colour"
                )
            }
        }

        UBUITestRegister("swift_shell_session_pill_label_reads_on_its_fill") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let key = TmuxSessionBadge.colorsDefaultsKey
                let picks = UserDefaults.standard.dictionary(forKey: key)
                defer { UserDefaults.standard.set(picks, forKey: key) }
                let dark = Ubiquitty.Themes.Contrast.labelDark
                let light = Ubiquitty.Themes.Contrast.labelLight
                var labels: [Int: UInt32] = [:]
                for index in 0..<TmuxSessionBadge.paletteCount {
                    let session = "pill-contrast-\(index)"
                    UserDefaults.standard.set([session: index], forKey: key)
                    // A bar of its own per pill: a bar holds one session pill
                    // and renames it rather than making a second.
                    let bar = ChromeAccessoryBar(scope: .window, heightInPoints: ChromeAccessoryBar.titleRowHeightInPoints)
                    guard let pill = TmuxSessionBadge.setSession(session, in: bar),
                        let fill = pill.layer?.backgroundColor.flatMap({ packedSRGB(NSColor(cgColor: $0)) }),
                        let ink = packedSRGB(pill.nameInk)
                    else {
                        t.expect(false, desc: "the pill for palette slot \(index) paints a fill and a label")
                        continue
                    }
                    t.expect(
                        fill == Ubiquitty.Runtime.tmuxSessionBadgeFill(Int32(index)),
                        desc: "slot \(index) paints Core's fill"
                    )
                    t.expect(ink == dark || ink == light, desc: "slot \(index)'s label is one of the two poles")
                    let other = ink == dark ? light : dark
                    t.expect(
                        abs(Ubiquitty.Themes.Contrast.apcaLc(ink, fill)) >= abs(Ubiquitty.Themes.Contrast.apcaLc(other, fill)),
                        desc: "slot \(index)'s label is the pole with the greater APCA contrast on the fill it sits on"
                    )
                    labels[index] = ink
                }
                // The saturated mid-tones a luma sum sends the other way:
                // blue, purple and pink weigh in above half and read in white.
                t.expect(
                    labels[5] == light && labels[6] == light && labels[7] == light,
                    desc: "the blue, purple and pink pills carry white labels"
                )
                t.expect(labels[2] == dark, desc: "the yellow pill carries a near-black label")
            }
        }
    }
}
