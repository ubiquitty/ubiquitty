// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyKit

/// Whether a pane keeps the focused cursor through the responder edges a
/// phone produces, and gives it up only to another text input.
///
/// The keyboard lives on ``TerminalKeyInputView``, not on the surface: the
/// surface becomes first responder for the selection menu and for a hardware
/// keyboard's click, and hands it back to the keyboard's view on the next tap.
/// Each leg is a sequence of those edges, run in a real window so UIKit makes
/// the handovers itself, and reads the focus the frame draws with — the fact
/// that separates the filled cursor from the hollow outline.
enum SurfaceFocusSmokeEntry {
    @MainActor
    static func run() -> Bool {
        guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13) else {
            return failed("Core declined a surface")
        }
        guard let window = SmokeLaunch.present(surface) else {
            return failed("no window to present in")
        }
        defer { window.isHidden = true }
        let keyboard = TerminalKeyInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        // The screen has asked for the keyboard: its view takes first
        // responder only while that request stands.
        keyboard.wantsFirstResponder = true
        window.addSubview(keyboard)
        let findField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        window.addSubview(findField)
        settle()

        var failures: [String] = []
        func expect(_ wantsFocused: Bool, _ what: String) {
            settle()
            if surface.isSurfaceFocused != wantsFocused {
                failures.append("\(what): the pane drew \(surface.isSurfaceFocused ? "focused" : "unfocused")")
            }
        }

        expect(true, "a pane on screen with no responder")

        // The selection menu, then a tap that raises the keyboard.
        _ = surface.becomeFirstResponder()
        expect(true, "the selection menu took first responder")
        _ = keyboard.becomeFirstResponder()
        expect(true, "the keyboard's view took first responder from the selection menu")
        _ = keyboard.resignFirstResponder()
        expect(true, "the keyboard was put away")

        // A hardware keyboard's click, then the software keyboard raised.
        _ = surface.becomeFirstResponder()
        _ = keyboard.becomeFirstResponder()
        expect(true, "the software keyboard raised after a hardware keyboard's click")

        // The find field, from the keyboard and from the selection menu.
        _ = findField.becomeFirstResponder()
        expect(false, "the find field took the keyboard")
        _ = findField.resignFirstResponder()
        expect(true, "the find field closed")
        _ = surface.becomeFirstResponder()
        _ = findField.becomeFirstResponder()
        expect(false, "the find field took the keyboard from the selection menu")
        _ = keyboard.becomeFirstResponder()
        expect(true, "the keyboard's view took first responder back from the find field")

        // A tab switch takes the pane out of its window and puts it back.
        _ = surface.becomeFirstResponder()
        surface.removeFromSuperview()
        settle()
        window.addSubview(surface)
        expect(true, "the pane returned to its window after leaving it as first responder")

        // A sheet's field still editing when the pane arrives is still focus
        // held elsewhere.
        _ = findField.becomeFirstResponder()
        surface.removeFromSuperview()
        settle()
        window.addSubview(surface)
        expect(false, "the pane arrived while another text input held the keyboard")
        _ = findField.resignFirstResponder()
        expect(true, "the other text input let the keyboard go")

        for failure in failures {
            _ = failed(failure)
        }
        return failures.isEmpty
    }

    /// Runs the main loop briefly, so settled responder edges have landed.
    @MainActor
    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("surface-focus: FAIL: \(reason)")
        return false
    }
}
