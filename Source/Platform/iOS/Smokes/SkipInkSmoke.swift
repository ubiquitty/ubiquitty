// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit

/// Whether an underline under descenders breaks clear of them on a remote pane.
///
/// The break is the renderer's: a rule marked to skip ink is cut in the
/// fragment stage wherever the glyph's coverage, dilated by the clearance,
/// crosses it. A clearance of zero still marks the rule, but cuts only the
/// pixels the descender itself already covers, so the rule runs into the
/// stroke and the line reads as unbroken. What the pane is drawn under is the
/// app's to say, so the surface is made the way the app makes one and the
/// clearance is read off the rules the frame was built with.
enum SkipInkSmokeEntry {
    /// How long the walk waits for the frame that draws the underlined row.
    private static let walkInSeconds = 2.0

    @MainActor
    static func run() -> Bool {
        let model = TerminalSessionModel()
        guard let surface = model.makePaneSurface() else {
            return failed("Core declined a surface")
        }
        let carrier = HeldCarrier()
        guard let factory = carrier.makeFactory() else {
            return failed("no carrier factory")
        }
        guard surface.attachRemoteOverCarrier(carrierFactory: ubiquittyIOSQUICFactoryAddress(factory)),
            surface.drive.isRemoteAttached
        else {
            return failed("the surface did not become a thin client")
        }
        _ = surface.drive.withTerminal { terminal in
            "\u{1b}[4mgjpqy\u{1b}[0m\r\n".withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
        }
        guard let window = SmokeLaunch.present(surface) else {
            return failed("no window to present in")
        }
        defer { window.isHidden = true }

        let start = Date()
        surface.setNeedsDisplay()
        var rules = (count: 0, widestPadInPixels: Float(0))
        while Date().timeIntervalSince(start) < walkInSeconds, rules.count == 0 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0))
            rules = surface.lastBuiltSkipInkRules
        }
        // The product's clearance in device pixels: the preference Core
        // resolves, at the scale the pane draws at.
        let configuration = Ubiquitty.Preferences.values().pointee
        let wantedPad = Float(
            Ubiquitty.Preferences.Effective.underlineSkipInkPad(configuration) * Double(window.screen.scale)
        )
        let facts = "skip-ink rules \(rules.count), widest clearance \(rules.widestPadInPixels) px, wanted \(wantedPad) px"
        guard Ubiquitty.Preferences.Effective.underlineSkipInk(configuration) else {
            return failed("the product's skip-ink preference is off (\(facts))")
        }
        guard rules.count > 0 else {
            return failed("no underline rule under the descenders was cut around their ink (\(facts))")
        }
        guard wantedPad > 0, abs(rules.widestPadInPixels - wantedPad) < 0.5 else {
            return failed("the rules keep no clearance from the descenders they cross (\(facts))")
        }
        return true
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("skip-ink: FAIL: \(reason)")
        return false
    }
}
