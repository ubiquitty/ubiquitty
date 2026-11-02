// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// DisplayPowerScenarios.swift — the Linux-console display blank covers a Swift
// window's view, and CSI 13 ] takes the cover away.
//
// Core's half is proven headless (testLinuxConsolePowerSequences): the family
// parses, CSI 13 ] wakes a blanked display, and the mode snapshot carries the
// state. What only a running window can answer is whether the view goes black
// while the display is blanked and comes back when it is woken — a view with a
// `WindowClient` hears `setDisplayPower`, which a Kit-hosted surface cannot
// install, so the surface reads the published state each drain instead.
//
// No escape blanks a display: console_codes' blank is the kernel's idle timer,
// which a terminal emulator does not run. The blanked state is therefore set on
// the model under its lock, the way Core's own test sets it, and the escapes are
// fed to see what the view makes of it.

/// Registers the display-power scenarios with the UI-test runner.
enum DisplayPowerScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_blanked_display_is_covered_until_woken") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                t.expect(!surface.isDisplayBlankCoverShown, desc: "a lit display wears no cover")

                // A timeout is stored and nothing blanks: this terminal runs no
                // idle timer, so the escape that arms one covers nothing.
                surface.feed(Data("\u{1b}[9;15]".utf8))
                t.pump(0.3)
                t.expect(!surface.isDisplayBlankCoverShown, desc: "a blank timeout alone covers nothing")

                surface.drive.withTerminal { $0.screenBlanked = true }
                // Any drain publishes the state; a second timeout is the family's
                // own byte that moves nothing else.
                surface.feed(Data("\u{1b}[14;30]".utf8))
                t.expect(
                    t.wait(until: { surface.isDisplayBlankCoverShown }, timeout: 4),
                    desc: "a blanked display covers the view"
                )
                guard let cover = surface.displayBlankCoverForTesting else {
                    t.expect(false, desc: "the cover exists while it is shown")
                    return
                }
                t.expect(cover.superlayer === surface.layer, desc: "the cover stands in the view's own layer")
                t.expect(
                    cover.zPosition > surface.metalLayer.zPosition,
                    desc: "and above the layer the frames are drawn into"
                )
                t.expect(cover.backgroundColor == CGColor(gray: 0, alpha: 1), desc: "the cover is black")
                t.expect(cover.frame == surface.bounds, desc: "the cover spans the whole view (\(cover.frame))")

                // The cover follows the view: a window that grows while blanked
                // must not show its new strip of grid beside a black box.
                var grown = window.frame
                grown.size.width += 120
                grown.size.height += 80
                window.setFrame(grown, display: true)
                t.pump(0.4)
                t.expect(
                    cover.frame == surface.bounds,
                    desc: "the cover follows a resize (\(cover.frame) over \(surface.bounds))"
                )

                surface.feed(Data("\u{1b}[13]".utf8))
                t.expect(
                    t.wait(until: { !surface.isDisplayBlankCoverShown }, timeout: 4),
                    desc: "CSI 13 ] wakes the display and takes the cover away"
                )
                t.expect(
                    surface.drive.withTerminal { $0.screenBlanked } == false,
                    desc: "and the model agrees the display is lit"
                )
            }
        }
    }
}
