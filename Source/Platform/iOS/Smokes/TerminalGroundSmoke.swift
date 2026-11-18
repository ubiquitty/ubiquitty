// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyKit

/// The chrome around the grid follows the terminal's ground, and the menu
/// knows whether there is a selection to copy.
///
/// The ground is driven by a program, through OSC 11, rather than by the
/// theme picker: a program that repaints its background is the case a colour
/// read once at launch gets wrong, and the band around the grid then frames it
/// in a colour it no longer has. Both directions are driven, so a reading that
/// never moves fails one of them.
enum TerminalGroundSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }

        let model = TerminalSessionModel()
        guard let surface = model.surfaceForDrawing() else {
            SmokeLaunch.report("terminal-ground: Core declined a surface")
            return false
        }

        func settle(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline {
                surface.serviceIngestEvents()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            return condition()
        }

        surface.feed(Data("\u{1b}]11;#f0f0f0\u{7}light ground\r\n".utf8))
        check(settle { !model.isGroundDark }, "a light OSC 11 ground still reads as dark")
        var red: CGFloat = 0
        model.groundColor.getRed(&red, green: nil, blue: nil, alpha: nil)
        check(abs(red - 0xF0 / 255) < 0.01, "the ground is not the colour the program set (red \(red))")

        surface.feed(Data("\u{1b}]11;#101010\u{7}".utf8))
        check(settle { model.isGroundDark }, "a dark OSC 11 ground still reads as light")

        check(!model.hasSelection, "a fresh terminal reports a selection")
        surface.selectAll(nil)
        check(settle { model.hasSelection }, "selecting everything was not reported to the model")

        for failure in failures {
            SmokeLaunch.report("terminal-ground: \(failure)")
        }
        return failures.isEmpty
    }
}

/// Under a light theme the screen opens light: the ground the screen paints
/// before any pane exists, and the first frame of the pane's host once one
/// does, are the configured theme's and never a colour of the shell's own.
enum TerminalFirstFrameGroundSmokeEntry {
    @MainActor
    static func run() -> Bool {
        let original = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer { _ = Ubiquitty.Preferences.configureOwnDocument(std.string(original)) }
        for colorSpace in ["srgb", "display-p3"] {
            guard firstFrameUsesThemeGround(colorSpace: colorSpace) else { return false }
        }
        return true
    }

    /// Checks the launch, surface and host grounds in one colour space.
    ///
    /// - Parameter colorSpace: Core's presentation colour-space token.
    /// - Returns: Whether the first composite and chrome agree with the theme.
    @MainActor
    private static func firstFrameUsesThemeGround(colorSpace: String) -> Bool {
        let theme = "Gruvbox Light"
        _ = Ubiquitty.Preferences.configureOwnDocument(
            std.string("[appearance]\nfollow_system = false\ntheme = \"\(theme)\"\ncolor_space = \"\(colorSpace)\"\n")
        )
        let index = theme.withCString { Ubiquitty.Themes.indexForName($0) }
        guard let background = Ubiquitty.Themes.get(index)?.pointee.defaultBackground else {
            return failed("\(theme) is not a theme Core knows")
        }
        let expected = bytes(
            of: TerminalColor(red: background.red, green: background.green, blue: background.blue)
                .platformColor(usesDisplayP3: colorSpace == "display-p3")
        )

        // The screen's ground before the pane is built: what its first frame
        // paints behind every edge.
        let model = TerminalSessionModel()
        let before = bytes(of: model.groundColor)
        guard isClose(before, expected) else {
            return failed("before any pane the ground is \(before), not the theme's \(expected)")
        }
        guard !model.isGroundDark else {
            return failed("before any pane the light ground reads as dark")
        }

        // The pane's host, put on screen. What its first composite shows is
        // read off the layers top down, as the compositor stacks them: a
        // snapshot of the window does not capture a Metal layer, and read one
        // here as black while the layer carried the theme's ground.
        guard
            let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            return failed("no window scene to present in")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TerminalSurfaceHost(session: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        guard let surface = model.surfaceForDrawing(), surface.window === window else {
            return failed("the pane's surface is not in the window")
        }
        guard isClose(bytes(of: surface.chromeBackgroundColor()), expected) else {
            return failed("the surface's chrome disagrees with its \(colorSpace) theme ground")
        }
        guard let first = firstComposite(of: surface) else {
            return failed("nothing under the pane carries a ground")
        }
        guard isClose(first.color, expected) else {
            return failed("the pane's first composite is \(first.color) from \(first.source), not the theme's \(expected)")
        }
        guard isClose(bytes(of: model.groundColor), expected) else {
            return failed("adopting the pane moved the ground to \(bytes(of: model.groundColor))")
        }
        let programGround = bytes(
            of: TerminalColor(red: 0x80, green: 0x40, blue: 0xC0)
                .platformColor(usesDisplayP3: colorSpace == "display-p3")
        )
        surface.feed(Data("\u{1b}]11;#8040c0\u{7}".utf8))
        let deadline = Date().addingTimeInterval(3)
        while !isClose(bytes(of: model.groundColor), programGround), Date() < deadline {
            surface.serviceIngestEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard isClose(bytes(of: model.groundColor), programGround),
            isClose(bytes(of: surface.chromeBackgroundColor()), programGround)
        else {
            return failed("a program's ground disagrees with the \(colorSpace) chrome")
        }
        return true
    }

    /// The colour the pane composites before its first frame: the Metal
    /// layer's own ground when it is opaque, else the first opaque ground
    /// beneath it. An opaque layer with neither a drawable nor a ground shows
    /// an undefined colour, counted here as black.
    @MainActor
    private static func firstComposite(of surface: TerminalSurface) -> (color: [UInt8], source: String)? {
        if surface.metalLayer.isOpaque {
            guard let ground = surface.metalLayer.backgroundColor else { return ([0, 0, 0], "an opaque Metal layer with no ground") }
            return (bytes(of: UIColor(cgColor: ground)), "the Metal layer")
        }
        var view: UIView? = surface
        while let current = view {
            if let color = current.backgroundColor, color.cgColor.alpha > 0.99 {
                return (bytes(of: color), "\(type(of: current))")
            }
            view = current.superview
        }
        return nil
    }

    private static func bytes(of color: UIColor) -> [UInt8] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return [red, green, blue].map { UInt8(clamping: Int(($0 * 255).rounded())) }
    }

    private static func isClose(_ sample: [UInt8], _ expected: [UInt8]) -> Bool {
        sample.count == 3 && zip(sample, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("light-first-frame: \(reason)")
        return false
    }
}
