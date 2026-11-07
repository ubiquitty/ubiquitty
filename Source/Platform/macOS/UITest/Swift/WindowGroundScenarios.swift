// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// WindowGroundScenarios.swift — an opaque window carries no material, and the
// ground under a new pane is the theme's own colour from the first moment.
//
// A window opens before its Metal layer has presented anything, and whatever
// lies under the pane is what the person sees in that gap. Two facts decide
// what that is, and neither is visible to a property read on the window: the
// content tree may hold an `NSVisualEffectView` (a blurred desktop, not the
// theme), and the pane's host may hold no fill at all (the window's backing,
// whatever AppKit last put there). At full background opacity both are
// wrong, and the effect view is not merely wrong for a moment — it has
// nothing to blend and no reason to exist.
//
// So what is asserted here is the tree: no visible effect view anywhere under
// an opaque window's content, and a themed layer under the panes.

/// Registers the window-ground scenarios with the UI-test runner.
enum WindowGroundScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_configured_background_image_reaches_the_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                t.expect(!surface.isShowingBackdrop, desc: "a window with no configured image carries none")

                // A real file: the decode reads one, and a path naming nothing
                // is the other half of what this asserts.
                let directory = NSTemporaryDirectory() + "ubq-backdrop-\(UInt32.random(in: 0...UInt32.max))"
                let imagePath = directory + "/ground.png"
                guard
                    let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: 8,
                        pixelsHigh: 8,
                        bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true,
                        isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 32,
                        bitsPerPixel: 32
                    ),
                    let png = bitmap.representation(using: .png, properties: [:])
                else {
                    t.expect(false, desc: "the scenario could make a picture to point at")
                    return
                }
                do {
                    try FileManager.default.createDirectory(
                        atPath: directory,
                        withIntermediateDirectories: true
                    )
                    try png.write(to: URL(fileURLWithPath: imagePath))
                } catch {
                    t.expect(false, desc: "the picture could be written (\(error))")
                    return
                }
                defer { try? FileManager.default.removeItem(atPath: directory) }

                // The same fan-out a settings write and a config reload reach.
                let saved = t.configureAppending("[appearance]\nbackground_image = \(tomlQuoted(imagePath))\n")
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyBackgroundEffectsToOpenWindows()
                }
                TerminalWindowController.applyBackgroundEffectsToOpenWindows()
                t.expect(
                    surface.isShowingBackdrop,
                    desc: "the configured picture reaches the live window's renderer"
                )

                // And a cleared key takes it down, rather than leaving the last
                // picture on a window the reader stopped asking for it in.
                t.restoreConfiguration(documentDroppingKeys(["background_image"], inSection: "appearance", of: saved))
                TerminalWindowController.applyBackgroundEffectsToOpenWindows()
                t.expect(
                    !surface.isShowingBackdrop,
                    desc: "and clearing the key takes it down again"
                )
            }
        }

        UBUITestRegister("swift_shell_opaque_window_carries_no_material") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureOpaqueTheme()
                defer { t.restoreConfiguration(saved) }
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let window = shell.window, let content = window.contentView else {
                    t.expect(false, desc: "the window has a content view")
                    return
                }
                t.expect(window.isOpaque, desc: "a window at full background opacity declares itself opaque")
                let materials = visibleEffectViews(in: content)
                t.expect(
                    materials.count,
                    equals: 0,
                    desc: "an opaque window's content holds no visible effect view"
                )
            }
        }

        // The scenario above opens a window under the test harness's own config
        // home, where every key is a default and the blur radius is zero — so
        // it can only ever see an opaque window, and passes whether or not the
        // rule it names holds for anyone who has set a radius. This one hands
        // the shell that configuration outright: a radius of 50 at full
        // background opacity, which is where nothing behind the window can
        // reach the person and a material under the panes is pure cost.
        UBUITestRegister("swift_shell_a_blur_radius_does_not_make_an_opaque_window_translucent") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The system's Reduce Transparency decides as well as the
                // configuration, so each answer is pinned in turn rather than
                // read off whichever machine runs the suite.
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                t.pump(0.1)
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.3)
                guard let window = shell.window, let content = window.contentView else {
                    t.expect(false, desc: "the window has a content view")
                    return
                }

                // Configured as a file saying so would be: the subscription
                // re-applies the ground to every open window.
                let saved = t.configureAppending("[appearance]\nblur_radius = 50.0\nbackground_opacity = 1.0\n")
                defer { t.restoreConfiguration(saved) }
                t.pump(0.2)
                t.expect(window.isOpaque, desc: "a radius at full opacity leaves the window opaque")
                t.expect(
                    visibleEffectViews(in: content).count,
                    equals: 0,
                    desc: "a radius at full opacity hangs no material under the panes"
                )

                // Below one the radius means what it says, so the assertions
                // above are the opacity deciding and not blur being ignored.
                t.restoreConfiguration(saved)
                t.configureAppending("[appearance]\nblur_radius = 50.0\nbackground_opacity = 0.8\n")
                t.pump(0.2)
                t.expect(!window.isOpaque, desc: "a radius below full opacity does make the window translucent")

                // Reduce Transparency is the reader's to set, and it wins over
                // the configuration: the same translucent request stays opaque.
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: true)
                t.pump(0.2)
                shell.applyTranslucency()
                t.pump(0.2)
                t.expect(window.isOpaque, desc: "under Reduce Transparency the same request leaves the window opaque")
                t.expect(
                    visibleEffectViews(in: content).count,
                    equals: 0,
                    desc: "and hangs no material under the panes"
                )
            }
        }

        UBUITestRegister("swift_shell_pane_ground_is_the_theme_before_the_first_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureOpaqueTheme()
                defer { t.restoreConfiguration(saved) }
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                // The host the panes live in, read as the person sees it: a
                // colour it carries itself, not one a pane paints later.
                guard let ground = shell.paneHost.layer?.backgroundColor else {
                    t.expect(false, desc: "the pane host carries a ground of its own")
                    return
                }
                let alpha = ground.alpha
                t.expect(alpha > 0.99, desc: "the pane host's ground is opaque at full background opacity")
                guard let themed = shell.window?.backgroundColor?.usingColorSpace(.sRGB),
                    let painted = NSColor(cgColor: ground)?.usingColorSpace(.sRGB)
                else {
                    t.expect(false, desc: "both grounds resolve in sRGB")
                    return
                }
                let distance =
                    abs(themed.redComponent - painted.redComponent)
                    + abs(themed.greenComponent - painted.greenComponent)
                    + abs(themed.blueComponent - painted.blueComponent)
                t.expect(distance < 0.02, desc: "the pane host's ground is the window's themed backing")
            }
        }

        // A reader who follows the system has a theme pinned beside the pair
        // all the same, the one they last chose by hand. A pane a split adds
        // opens on the system's theme, as the window's first pane did, not on
        // that pinned one.
        UBUITestRegister("swift_shell_a_split_opens_on_the_system_theme_its_window_follows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[appearance]\nfollow_system = true\ntheme = \"Glass Dark\"\n")
                defer { t.restoreConfiguration(saved) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let first = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a pane")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                let opened = first.currentThemeName ?? "none"
                t.expect(opened != "Glass Dark", desc: "the window's first pane opens on the system's theme (\(opened))")
                // The window is composited for the theme it shows: an opaque
                // system theme makes no see-through window.
                t.expect(window.isOpaque, desc: "and the window is opaque, as that theme is")
                shell.splitRight(nil)
                t.pump(0.4)
                guard let split = shell.focusedSurfaceForTesting, split !== first else {
                    t.expect(false, desc: "the split adds a pane")
                    return
                }
                t.expect(
                    split.currentThemeName == opened,
                    desc: "and the pane the split adds opens on the same one (\(split.currentThemeName ?? "none"))"
                )
                t.expect(window.isOpaque, desc: "and the window stays opaque with it")
            }
        }

        UBUITestRegister("swift_shell_chrome_takes_the_terminals_colour_space") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureOpaqueTheme()
                defer { t.restoreConfiguration(saved) }
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let wasP3 = Ubiquitty.Preferences.Effective.liveRenderConfiguration().usesDisplayP3
                defer { app.settingsSetColorSpaceP3(wasP3) }
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                // Each setting in turn: the chrome a person sees beside the
                // grid is built in the space the grid's layer is tagged with,
                // or one triple is two colours across the seam.
                for wantsP3 in [true, false] {
                    app.settingsSetColorSpaceP3(wantsP3)
                    shell.applyChromeTheme()
                    t.pump(0.2)
                    let name = wantsP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
                    let space = wantsP3 ? "Display P3" : "sRGB"
                    guard let ground = shell.paneHost.layer?.backgroundColor?.colorSpace else {
                        t.expect(false, desc: "the pane ground carries a colour space")
                        continue
                    }
                    t.expect(ground.name == name, desc: "the pane ground is built in " + space)
                    guard let backing = shell.window?.backgroundColor.cgColor.colorSpace else {
                        t.expect(false, desc: "the window backing carries a colour space")
                        continue
                    }
                    t.expect(backing.name == name, desc: "the window backing is built in " + space)
                }
            }
        }

        // The accessibility switches arrive on the WORKSPACE notification
        // centre, and a Reduce Transparency flip is meant to take the blur and
        // the opacity away and give them back on a window already open. Both
        // halves are what this asks — the delivery, by posting where the
        // system posts, and the effect, by moving the ground under a window
        // nobody has otherwise touched.
        UBUITestRegister("swift_shell_accessibility_flip_rerealizes_the_ground") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Reduce Transparency pinned off, so the first half tests the
                // notification and not the machine's own switch.
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                t.pump(0.1)
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let window = shell.window else {
                    t.expect(false, desc: "the window is there")
                    return
                }
                t.expect(window.isOpaque, desc: "a window at full background opacity opens opaque")

                let saved = t.configureAppending("[appearance]\nbackground_opacity = 0.5\n")
                defer {
                    TerminalSurface.systemTransparencyOverrideForTesting = nil
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyBackgroundEffectsToOpenWindows()
                }
                t.pump(0.2)
                t.expect(!window.isOpaque, desc: "a configured opacity reaches the open window")

                // The control: the switch moving with nobody announcing it
                // moves nothing, so whatever the post below changes came from
                // the post.
                TerminalSurface.systemTransparencyOverrideForTesting = .Reduced
                t.pump(0.2)
                t.expect(!window.isOpaque, desc: "an unannounced switch leaves the open window's ground where it was")

                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                    object: NSWorkspace.shared
                )
                t.pump(0.3)
                t.expect(window.isOpaque, desc: "the switch moving re-realizes the ground on a window already open")

                TerminalSurface.systemTransparencyOverrideForTesting = nil
                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                    object: NSWorkspace.shared
                )
                t.pump(0.3)
                t.expect(!window.isOpaque, desc: "and gives the translucent ground back, which is the half a one-way apply loses")

                // The switch itself: a window the reader asked to be translucent
                // goes opaque when Reduce Transparency turns on, and comes back
                // when it turns off, without being reopened.
                t.restoreConfiguration(saved)
                t.configureAppending("[appearance]\nbackground_opacity = 0.5\n")
                TerminalWindowController.applyBackgroundEffectsToOpenWindows()
                t.pump(0.2)
                t.expect(!window.isOpaque, desc: "a half-opaque window is translucent while Reduce Transparency is off")
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: true)
                t.pump(0.3)
                t.expect(window.isOpaque, desc: "Reduce Transparency turning on flattens the open window")
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                t.pump(0.3)
                t.expect(!window.isOpaque, desc: "and turning it off gives the translucency back")
            }
        }
    }

    ///
    /// Visible rather than present: AppKit builds materials into containers it
    /// owns, and hiding one is how a themed window takes the row back.
    ///
    /// - Parameter view: The root to walk.
    /// - Returns: The materials a person would see through.
    @MainActor
    private static func visibleEffectViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if let material = view as? NSVisualEffectView, !view.isHidden, view.alphaValue > 0.01,
            material.maskImage == nil
        {
            found.append(view)
        }
        if view.isHidden {
            return found
        }
        for subview in view.subviews {
            found.append(contentsOf: visibleEffectViews(in: subview))
        }
        return found
    }
}

/// Configures an opaque palette so chrome assertions do not depend on system materials.
///
/// - Returns: The document to restore after the scenario.
@MainActor
private func configureOpaqueTheme() -> String {
    configureAppendingToLiveDocument(
        "[appearance]\nfollow_system = false\ntheme = \"Dracula\"\nbackground_opacity = 1.0\ntitlebar_style = \"themed\"\n"
    )
}
