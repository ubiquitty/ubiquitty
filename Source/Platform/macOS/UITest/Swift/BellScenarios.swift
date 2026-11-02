// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// BellScenarios.swift — one bell, one reaction, and the reaction is the cue
// Core resolved.
//
// The trap this file covers: a second ingest path that re-implements the bell
// and stops at the audible half. Its whole reaction is a beep, so a reader who
// asked for a visual-only bell gets a sound and no flash, and one who turned
// the bell off gets a sound anyway.
//
// The audible half leaves no trace a test can read, so what is asked here is
// the visible one, in both directions: a visual bell puts a flash in the
// frame, an audible-only bell puts none there, and the flash leaves the screen
// only once a frame has been drawn without it.

/// Registers the bell scenarios with the UI-test runner.
enum BellScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_visual_bell_flashes_and_an_audible_one_does_not") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )

                // Audible only: a bell is heard and nothing is drawn. Without
                // this half a shell that flashed for every bell would pass.
                let saved = t.configureAppending("[bell]\naudible = true\nvisual = false\n")
                defer {
                    t.restoreConfiguration(saved)
                    surface.drive.applyTerminalPreferences(Ubiquitty.Preferences.values().pointee)
                }
                surface.drive.applyTerminalPreferences(Ubiquitty.Preferences.values().pointee)
                surface.transmitAsUserInputForTesting("printf '\\a'\r")
                // Watched rather than sampled once: the envelope is short, so
                // a single read a second later finds zero whether the flash
                // was drawn or not.
                t.expect(
                    !t.wait(until: { surface.lastFrameBellFlashAlpha > 0 }, timeout: 2),
                    desc: "an audible-only bell never draws a flash"
                )

                // Visual only: nothing is heard and the frame carries the
                // flash. A shell that beeped for every non-Off style — this
                // one, before — cannot produce it.
                t.restoreConfiguration(saved)
                t.configureAppending("[bell]\naudible = false\nvisual = true\n")
                surface.drive.applyTerminalPreferences(Ubiquitty.Preferences.values().pointee)
                surface.transmitAsUserInputForTesting("printf '\\a'\r")
                t.expect(
                    t.wait(until: { surface.lastFrameBellFlashAlpha > 0 }, timeout: 6),
                    desc: "a visual bell puts the flash in the frame"
                )

                // The overlay leaves only when a frame is drawn without it, so
                // the schedule is still asked for one after the envelope has
                // run out. Put to it at a tick far past the envelope rather
                // than waited for: the transition is one frame wide.
                let farPastTheEnvelope = surface.drive.frameClockFactsNow().blinkTicks &+ 6000
                t.expect(
                    surface.bellFlashDemand(atTicks: farPastTheEnvelope) > 0,
                    desc: "the schedule is still asked for the frame that clears the flash"
                )
                t.expect(
                    t.wait(until: { surface.lastFrameBellFlashAlpha == 0 }, timeout: 8),
                    desc: "and that frame is drawn"
                )
            }
        }

        // A banner carries the pane that rang, so a click on it reaches that
        // pane and not merely the frontmost window — and says so when the pane
        // has closed since, which is the caller's cue to settle for the raise.
        UBUITestRegister("swift_shell_a_banner_focuses_the_pane_that_rang") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.splitRight(nil)
                t.expect(t.wait(until: { panes(of: shell).count == 2 }, timeout: 8), desc: "the window splits")
                let split = panes(of: shell)
                guard let focused = shell.focusedSurfaceForTesting,
                    let other = split.first(where: { $0 !== focused }),
                    let otherIdentifier = shell.paneIdentifier(of: other)
                else {
                    t.expect(false, desc: "the split has two named panes")
                    return
                }

                let origin = other.sessionOriginDescription
                t.expect(
                    origin.contains("pane “\(otherIdentifier)”"),
                    desc: "the background pane's origin resolves independently of focus"
                )
                t.expect(shell.focusPane(withIdentifier: otherIdentifier), desc: "the tagged pane is still open")
                t.expect(
                    t.wait(until: { shell.focusedSurfaceForTesting === other }, timeout: 4),
                    desc: "and the click lands on it rather than on whatever was focused"
                )
                t.expect(other.sessionOriginDescription == origin, desc: "changing focus preserves the request's origin")
                // The keyboard, not only the model's leaf: a window that was a
                // background tab never made its view first responder, so the
                // leaf being right is not the same as typing reaching it.
                t.expect(
                    t.wait(until: { window.firstResponder === other }, timeout: 4),
                    desc: "and the keyboard is bound to it"
                )

                // A pane that closed since the banner posted answers no, and
                // the raise is then the whole of what the click does.
                let noSuchPane = (split.compactMap { shell.paneIdentifier(of: $0) }.max() ?? 0) + 1
                t.expect(
                    !shell.focusPane(withIdentifier: noSuchPane),
                    desc: "a pane that is gone says so instead of focusing something else"
                )
            }
        }

        // A bell rung with nobody there to hear it leaves a mark, and the
        // mark is drawn in the colour the session asked for rather than
        // choosing between the two.
        //
        // The harness cannot take key (it is an accessory application), so
        // every window here is one the reader is not in — which is exactly the
        // state the mark exists for. The clearing half is the same foreground
        // fact and has no window here that can satisfy it; it is pinned in Core
        // instead, by aBellMarksTheTabNobodyWasLookingAt.
        UBUITestRegister("swift_shell_an_unheard_bell_marks_the_tab_and_wears_the_asked_colour") { context in
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
                t.expect(!window.isKeyWindow, desc: "the harness's window cannot take key, so nobody is looking at it")
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )

                // The default cue is audible, which is what raises the bell
                // event at all; a reader who switched both off gets no event
                // and no mark, and that is their setting answering.
                surface.transmitAsUserInputForTesting("printf '\\a'\r")
                t.expect(
                    t.wait(until: { shell.hasUnheardBell }, timeout: 8),
                    desc: "a bell nobody heard marks the tab"
                )
                guard let bell = window.tab.accessoryView as? TabStatusMark, bell.symbolName == "bell.fill" else {
                    t.expect(false, desc: "and the strip carries the bell rather than the ⌘N hint")
                    return
                }
                let plainInk = bell.ink?.usingColorSpace(.sRGB)
                t.expect(
                    plainInk.map { !(Int(($0.redComponent * 255).rounded()) == 0xFF && Int(($0.greenComponent * 255).rounded()) == 0x88) }
                        ?? false,
                    desc: "plain, because no program asked for a colour"
                )
                t.expect(
                    t.wait(until: { bell.isGlowing }, timeout: 3),
                    desc: "and, unheard, it glows"
                )

                // OSC 21337 sets one. The bell outranks the dot, so the colour
                // has to arrive on the bell — ranked the other way it would be
                // the bell that disappeared, which is the thing that cannot be
                // recovered by looking.
                surface.transmitAsUserInputForTesting("printf '\\033]21337;indicator=#FF8800\\007'\r")
                t.expect(
                    t.wait(
                        until: {
                            guard let mark = window.tab.accessoryView as? TabStatusMark, mark.symbolName == "bell.fill",
                                let ink = mark.ink?.usingColorSpace(.sRGB)
                            else { return false }
                            return Int((ink.redComponent * 255).rounded()) == 0xFF && Int((ink.greenComponent * 255).rounded()) == 0x88
                        },
                        timeout: 8
                    ),
                    desc: "a colour asked for while a bell stands is the colour the bell is drawn in"
                )
                let asked = (window.tab.accessoryView as? TabStatusMark)?.ink?
                    .usingColorSpace(.sRGB)
                t.expect(
                    asked.map { Int(($0.redComponent * 255).rounded()) == 0xFF } ?? false,
                    desc: "and it is the colour the program named, not one of ours"
                )

                // What is DRAWN, not what is stored. The checks above read the
                // indicator's properties, and properties passed while an earlier
                // shape painted the program's colour in the wrong place. So the
                // real component is rendered and its pixels read back, once in
                // the tab's ink (blue here) and once asked for a colour (red),
                // which is the only thing a reader ever sees.
                let probe = TabStatusMark(frame: .zero)
                probe.showBellForTesting(ink: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
                probe.frame = NSRect(origin: .zero, size: probe.intrinsicContentSize)
                probe.layoutSubtreeIfNeeded()
                let plain = bellInk(of: probe)
                t.expect(
                    plain.blue > 0 && plain.red == 0,
                    desc: "a plain bell is drawn in the tab's ink (blue \(plain.blue), red \(plain.red))"
                )
                probe.showBellForTesting(ink: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                probe.frame = NSRect(origin: .zero, size: probe.intrinsicContentSize)
                probe.layoutSubtreeIfNeeded()
                let coloured = bellInk(of: probe)
                t.expect(
                    coloured.red > 0 && coloured.blue == 0,
                    desc: "and a coloured bell is drawn wholly in the asked colour (red \(coloured.red), blue \(coloured.blue))"
                )

                // The title carries the same mark, which is what a window with
                // no strip has instead of an accessory slot. Read off the field
                // AppKit actually draws rather than off the controller's flag:
                // the flag being set and the glyph being in the string are two
                // claims, and only the second one is what a reader sees.
                guard let strip = titlebarStrip(of: window), let field = titleField(in: strip) else {
                    t.expect(false, desc: "the window has a title field")
                    return
                }
                t.expect(
                    t.wait(
                        until: { titleTrailingAttachment(field) != nil },
                        timeout: 4
                    ),
                    desc: "and the window title carries the bell after its text"
                )
            }
        }

        // A session asking to be noticed takes the Dock, and only while the
        // reader is somewhere else.
        UBUITestRegister("swift_shell_session_attention_is_gated_on_the_app_being_away") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                SessionAttention.clear()
                t.expect(!SessionAttention.isBadgeShowing, desc: "a cleared badge shows nothing")
                SessionAttention.note(isAppActive: true)
                t.expect(
                    !SessionAttention.isBadgeShowing,
                    desc: "an ask while the reader is here is noise, so nothing is taken"
                )
                SessionAttention.note(isAppActive: false)
                t.expect(
                    SessionAttention.isBadgeShowing,
                    desc: "and an ask while they are elsewhere takes the Dock"
                )
                SessionAttention.clear()
                t.expect(!SessionAttention.isBadgeShowing, desc: "and coming back clears it")
            }
        }
    }

    /// How many of a rendered bell's pixels are red and how many are blue.
    ///
    /// Counts opaque pixels over the whole glyph, each one either past 0.6 in
    /// its own channel and under 0.4 in the other or not counted at all. A bell
    /// drawn in one ink reads as one count and zero of the other, and a render
    /// that produced nothing reads as zero of both — which the callers refuse
    /// rather than pass.
    ///
    /// - Parameter view: The indicator, already sized and laid out.
    /// - Returns: The red and blue pixel counts.
    @MainActor
    private static func bellInk(of view: NSView) -> (red: Int, blue: Int) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (0, 0)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        var red = 0
        var blue = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else {
                    continue
                }
                if c.redComponent > 0.6, c.blueComponent < 0.4 { red += 1 }
                if c.blueComponent > 0.6, c.redComponent < 0.4 { blue += 1 }
            }
        }
        return (red, blue)
    }

    /// Every terminal pane under a window, in the order the host holds them.
    ///
    /// - Parameter shell: The window to walk.
    /// - Returns: The panes.
    @MainActor
    private static func panes(of shell: TerminalWindowController) -> [TerminalSurface] {
        var found: [TerminalSurface] = []
        func walk(_ view: NSView) {
            if let surface = view as? TerminalSurface {
                found.append(surface)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(shell.paneHost)
        return found
    }
}
