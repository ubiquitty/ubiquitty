// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit

/// Whether an underline under descenders breaks clear of them on a remote pane.
///
/// The break is Core's: the build cuts a rule wherever glyph ink touches it,
/// widened by the clearance, and the renderer draws the pieces left standing.
/// A clearance of zero still cuts, but only the pixels the descender itself
/// covers, so the rule runs into the stroke and the line reads as unbroken.
/// What the pane is drawn under is the app's to say, so the surface is made
/// the way the app makes one, and the cut and its clearance are read off the
/// build that drew the frame.
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
        var rules = (rules: 0, cutRules: 0, clearanceInPixels: Float(0))
        while Date().timeIntervalSince(start) < walkInSeconds, rules.cutRules == 0 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0))
            rules = surface.lastBuiltSkipInkRules
        }
        // The product's clearance in device pixels: the preference Core
        // resolves, at the scale the pane draws at. An automatic clearance
        // (negative) is the rule's own weight, which only the frame knows, so
        // it is held to keeping at least a pixel rather than to a number.
        let configuration = Ubiquitty.Preferences.values().pointee
        let configuredPad = Ubiquitty.Preferences.Effective.underlineSkipInkPad(configuration)
        let isAutomaticPad = configuredPad < 0
        let wantedPad = Float(configuredPad * Double(window.screen.scale))
        let wanted = isAutomaticPad ? "the rule's weight" : "\(wantedPad) px"
        let facts =
            "skip-ink rules \(rules.rules), cut \(rules.cutRules), clearance \(rules.clearanceInPixels) px, wanted \(wanted)"
        guard Ubiquitty.Preferences.Effective.underlineSkipInk(configuration) else {
            return failed("the product's skip-ink preference is off (\(facts))")
        }
        guard rules.rules > 0 else {
            return failed("no underline rule was tested against the descenders' ink (\(facts))")
        }
        guard rules.cutRules > 0 else {
            return failed("no underline rule under the descenders was cut around their ink (\(facts))")
        }
        let keepsClearance =
            isAutomaticPad ? rules.clearanceInPixels >= 1 : wantedPad > 0 && abs(rules.clearanceInPixels - wantedPad) < 0.5
        guard keepsClearance else {
            return failed("the rules keep no clearance from the descenders they cross (\(facts))")
        }
        return true
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("skip-ink: FAIL: \(reason)")
        return false
    }
}
