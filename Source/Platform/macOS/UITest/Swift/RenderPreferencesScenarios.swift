// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RenderPreferencesScenarios — [render] vsync and max_fps reach a Swift
// window's layer and clock, and the present-slip accounting is fed while it
// is armed and read as unmeasured while it is not.
//
// The keys are read off the layer and the clock rather than off the
// configuration: a value that the fold carries and nothing applies is what
// the ledger entries named.

import AppKit
import UbiquittyKit

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

enum RenderPreferencesScenarios {
    static func register() {
        UBUITestRegister("swift_shell_render_pacing_keys_reach_the_layer_and_the_clock_on_reload") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Opened under an explicit cap and vsync on: the creation path
                // is one of the two the keys reach through.
                let saved = t.configureAppending("[render]\nvsync = true\nmax_fps = 45\n")
                defer { t.restoreConfiguration(saved) }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                t.expect(surface.metalLayer.displaySyncEnabled, desc: "vsync on reaches the layer at creation")
                t.expect(
                    surface.frameClockMaxFPSForTesting == 45,
                    desc: "max_fps reaches the clock at creation (cap \(surface.frameClockMaxFPSForTesting))"
                )

                // The file changes and Core is configured from it, the link
                // running or not: the layer and the clock follow without a
                // resume.
                t.restoreConfiguration(saved)
                t.configureAppending("[render]\nvsync = false\nmax_fps = 30\n")
                t.pump(0.2)
                t.expect(!surface.metalLayer.displaySyncEnabled, desc: "vsync off reaches the layer on reload")
                t.expect(
                    surface.frameClockMaxFPSForTesting == 30,
                    desc: "max_fps reaches the clock on reload (cap \(surface.frameClockMaxFPSForTesting))"
                )

                // A resume re-asserts the vsync choice on the layer: the layer
                // comes back with the default after a screen or backing
                // change, and the clock is what puts the choice back.
                surface.metalLayer.displaySyncEnabled = true
                surface.resumeFrameClockForTesting()
                t.pump(0.2)
                t.expect(!surface.metalLayer.displaySyncEnabled, desc: "a link resume re-asserts vsync off on the layer")

                // Back to the defaults: a document that names neither key.
                t.restoreConfiguration(saved)
                t.pump(0.2)
                t.expect(surface.metalLayer.displaySyncEnabled, desc: "vsync on again on reload")
                t.expect(
                    surface.frameClockMaxFPSForTesting == 0,
                    desc: "the cap lifts on reload (cap \(surface.frameClockMaxFPSForTesting))"
                )
            }
        }

        UBUITestRegister("swift_shell_presents_feed_the_slip_accounting") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                // A handful of presented frames, and long enough after them
                // for their presented handlers to have run.
                let presentFrames = {
                    for _ in 0..<4 {
                        surface.invalidateRetainedBaseline()
                        surface.needsDisplay = true
                        t.pump(0.15)
                    }
                    t.pump(0.3)
                }

                // Unarmed, a present carries no handler, so nothing counts its
                // slips, and the phase log has to say so rather than print a
                // zero nobody measured. UBIQUITTY_PERFLOG arms every present
                // in the process, which leaves no unarmed case to read.
                if ProcessInfo.processInfo.environment["UBIQUITTY_PERFLOG"] == nil {
                    let unarmedBefore = surface.presentSlipForTesting.presented
                    presentFrames()
                    let unarmedAfter = surface.presentSlipForTesting.presented
                    t.expect(
                        unarmedAfter == unarmedBefore,
                        desc: "an unarmed surface's presents reach no slip handler (\(unarmedBefore) to \(unarmedAfter))"
                    )
                    let field = surface.phaseLogSlipFieldForTesting ?? "no Swift renderer"
                    t.expect(field == "slip=unmeasured", desc: "and its phase log reads the slips as unmeasured (\(field))")
                }

                // Armed, each async present arms the handler, and each
                // handler records its presented time.
                TerminalSurface.shouldArmPresentSlipForTesting = true
                defer { TerminalSurface.shouldArmPresentSlipForTesting = false }
                let before = surface.presentSlipForTesting.presented
                presentFrames()
                let after = surface.presentSlipForTesting
                t.expect(
                    after.presented > before,
                    desc: "the Swift renderer's presents reach the slip accounting (\(before) to \(after.presented))"
                )
                let field = surface.phaseLogSlipFieldForTesting ?? "no Swift renderer"
                t.expect(
                    field == "slip=\(after.slippedVsyncs)",
                    desc: "and the phase log reads the count they kept (\(field) against \(after.slippedVsyncs))"
                )
            }
        }
    }
}
