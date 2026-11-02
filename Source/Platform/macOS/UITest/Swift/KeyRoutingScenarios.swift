// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// KeyRoutingScenarios.swift — control keys reach the encoder, and the editor
// commands the input method derives from them are swallowed rather than left to
// NSResponder, whose inherited implementation answers each one with a beep.
//
// The beep itself is unobservable from a test, so the scenario reads the two
// facts that together rule it out: the key's bytes reach the wire (didTransmit),
// and the command lands on the surface's own doCommand(by:) — counted through
// editorCommandsSwallowedForTesting, which stays at zero if the override is
// lost while every key still types. That zero is the regression this exists to
// catch: keys that work and beep pass every typing-level assertion.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
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

/// Records what a surface transmits, forwarding everything to the shell's own
/// observer so the window under test keeps behaving like one.
@MainActor
private final class TransmitRecorder: TerminalSurfaceObserver {
    private(set) var transmitted: [UInt8] = []
    private weak var forward: TerminalSurfaceObserver?

    init(forwardingTo previous: TerminalSurfaceObserver?) {
        forward = previous
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        let taken = bytes.prefix(count).map { UInt8(bitPattern: $0) }
        MainActor.assumeIsolated {
            transmitted.append(contentsOf: taken)
            forward?.terminalSurface(surface, didTransmit: bytes, count: count)
        }
    }

    /// Hands back the observer this recorder was forwarding to.
    func takeForward() -> TerminalSurfaceObserver? {
        forward
    }
}

/// One key press, synthesised the way AppKit would deliver it.
///
/// - Parameters:
///   - characters: The characters the modifiers produce.
///   - unmodified: The characters without modifiers.
///   - keyCode: The hardware key code.
///   - modifiers: The held modifier flags.
/// - Returns: The event, or nil when AppKit refuses the combination.
@MainActor
private func keyPress(
    characters: String,
    unmodified: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: unmodified,
        isARepeat: false,
        keyCode: keyCode
    )
}

/// Registers the key-routing scenarios with the UI-test runner.
enum KeyRoutingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_key_positions_use_hardware_locations") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = t.newWindowRunning(["/bin/sh"]),
                    let surface = controller.beamSurface
                else {
                    t.expect(false, desc: "the terminal opens")
                    return
                }
                defer { t.closeAllWindows() }
                let recorder = TransmitRecorder(forwardingTo: surface.observer)
                surface.observer = recorder
                surface.feed(Data("\u{1b}[?81h".utf8))
                guard let event = keyPress(characters: "φ", unmodified: "φ", keyCode: 0, modifiers: []) else {
                    t.expect(false, desc: "AppKit supplies a physical key")
                    return
                }
                surface.routeKeyPress(event)
                t.expect(
                    recorder.transmitted == Array("\u{1b}_:C0100\u{1b}\\".utf8),
                    desc: "the physical A position bypasses text composition"
                )
                let before = recorder.transmitted.count
                surface.feed(Data("\u{1b}[?81l".utf8))
                surface.routeKeyPress(event)
                let suffix = Array(recorder.transmitted.dropFirst(before))
                t.expect(!suffix.starts(with: [0x1b, 0x5f]), desc: "reset returns to character input")
                surface.observer = recorder.takeForward()
            }
        }
        UBUITestRegister("swift_shell_control_keys_reach_the_pty_without_a_beep") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)

                let recorder = TransmitRecorder(forwardingTo: surface.observer)
                surface.observer = recorder

                // Each press through the real route, wire bytes asserted per
                // key so a miss names the key rather than the batch.
                let presses:
                    [(
                        name: String, characters: String, unmodified: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        expected: UInt8
                    )] = [
                        ("Ctrl+A", "\u{01}", "a", 0, [.control], 0x01),
                        ("Ctrl+K", "\u{0B}", "k", 40, [.control], 0x0B),
                        ("backspace", "\u{7F}", "\u{7F}", 51, [], 0x7F),
                    ]
                for press in presses {
                    guard
                        let event = keyPress(
                            characters: press.characters,
                            unmodified: press.unmodified,
                            keyCode: press.keyCode,
                            modifiers: press.modifiers
                        )
                    else {
                        t.expect(false, desc: "AppKit synthesises a \(press.name) event")
                        continue
                    }
                    let before = recorder.transmitted.count
                    surface.routeKeyPress(event)
                    t.pump(0.05)
                    let sent = Array(recorder.transmitted.dropFirst(before))
                    t.expect(
                        sent.contains(press.expected),
                        desc:
                            "\(press.name) reaches the wire as 0x\(String(press.expected, radix: 16)) (sent \(sent.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                    )
                }

                // The IME half. The input method turns these keys into editor
                // commands and delivers them here; NSResponder's inherited
                // doCommand(by:) — the one the surface's override displaces —
                // beeps on every command it does not recognise. Driven directly
                // because a headless input context is not obliged to route
                // anything: what must hold is that the SURFACE's implementation
                // answers, and the counter is the only witness that it did.
                let beforeSwallow = surface.editorCommandsSwallowedForTesting
                surface.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
                surface.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                t.expect(
                    surface.editorCommandsSwallowedForTesting == beforeSwallow + 2,
                    desc:
                        "the surface's own doCommand(by:) swallows editor commands instead of NSResponder's beeping default (count \(beforeSwallow) -> \(surface.editorCommandsSwallowedForTesting))"
                )

                surface.observer = recorder.takeForward()
            }
        }

        UBUITestRegister("swift_shell_keypress_returns_the_view_to_the_tail") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // History to scroll into, from the real shell.
                surface.send("for i in $(seq 1 200); do echo tail-line-$i; done\n")
                var scrollback = 0
                for _ in 0..<40 {
                    t.pump(0.1)
                    scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
                    if scrollback > 60 { break }
                }
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback (got \(scrollback))")
                    return
                }

                // The user is reading history: the reported freeze begins here.
                surface.offsetView(byLines: 40)
                t.expect(surface.viewOffset > 0, desc: "the view is in history (offset \(surface.viewOffset))")

                // A key press. DEC 1011, default on, says typing returns the
                // view to the live tail — Core owns the policy, the arm
                // realizes the offset reset. The Metal arm does; this asserts
                // the Swift arm does too, which is the showcase report: with
                // the view held in history, every full repaint an application
                // draws lands out of sight and "the screen doesn't refresh".
                guard
                    let press = keyPress(characters: "x", unmodified: "x", keyCode: 7, modifiers: [])
                else {
                    t.expect(false, desc: "AppKit synthesises a key event")
                    return
                }
                _ = surface.sendKey(press, eventType: .Press)
                t.pump(0.1)
                t.expect(
                    surface.viewOffset == 0,
                    desc: "a key press returns the view to the live tail (offset \(surface.viewOffset))"
                )

                // A key RELEASE leaves the view alone: release events report,
                // they do not navigate.
                surface.offsetView(byLines: 40)
                let held = surface.viewOffset
                t.expect(held > 0, desc: "the view is back in history for the release check")
                _ = surface.sendKey(press, eventType: .Release)
                t.pump(0.1)
                t.expect(
                    surface.viewOffset == held,
                    desc: "a key release does not move the view (offset \(surface.viewOffset), was \(held))"
                )

                // With scroll-on-keypress reset, a press holds too: the mode is
                // the policy, not the arm.
                // Fed to the parser directly: a shell round-trip parses the
                // same bytes on the shell's own schedule, which a scenario
                // cannot assert against.
                surface.feed(Data("\u{1b}[?1011l".utf8))
                t.pump(0.2)
                surface.offsetView(byLines: 40)
                let heldUnderReset = surface.viewOffset
                _ = surface.sendKey(press, eventType: .Press)
                t.pump(0.1)
                t.expect(
                    surface.viewOffset == heldUnderReset,
                    desc: "with DEC 1011 reset a press holds the view (offset \(surface.viewOffset), was \(heldUnderReset))"
                )
                surface.feed(Data("\u{1b}[?1011h".utf8))
                t.pump(0.1)
            }
        }

        UBUITestRegister("swift_shell_a_released_modifier_reports_a_release") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)

                // The Kitty protocol at report-all-keys, which is the only
                // regime where a bare modifier is reported at all — the legacy
                // key encoder answers zero bytes for one, so without this the case
                // would assert over silence.
                surface.feed(Data("\u{1b}[>15u".utf8))
                t.pump(0.2)
                let recorder = TransmitRecorder(forwardingTo: surface.observer)
                surface.observer = recorder
                defer { surface.observer = recorder.takeForward() }

                // AppKit's low bits, per side. The general `.shift` cannot tell
                // the two apart, which is what this case turns on.
                let leftShiftBit: UInt = 0x0000_0002
                let rightShiftBit: UInt = 0x0000_0004
                @MainActor
                func flagsChanged(keyCode: UInt16, raw: UInt) -> NSEvent? {
                    NSEvent.keyEvent(
                        with: .flagsChanged,
                        location: .zero,
                        modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: shell.window?.windowNumber ?? 0,
                        context: nil,
                        characters: "",
                        charactersIgnoringModifiers: "",
                        isARepeat: false,
                        keyCode: keyCode
                    )
                }
                let shiftFlag = NSEvent.ModifierFlags.shift.rawValue

                // Both shifts go down, then the LEFT one comes up while the
                // right stays held. The general shift bit is still set at that
                // moment, so a reader of it calls the release a press — and a
                // program under the Kitty protocol then believes a modifier is
                // held that the reader has let go of.
                guard let leftDown = flagsChanged(keyCode: 56, raw: shiftFlag | leftShiftBit),
                    let rightDown = flagsChanged(keyCode: 60, raw: shiftFlag | leftShiftBit | rightShiftBit),
                    let leftUp = flagsChanged(keyCode: 56, raw: shiftFlag | rightShiftBit)
                else {
                    t.expect(false, desc: "AppKit makes the flags-changed events")
                    return
                }
                surface.flagsChanged(with: leftDown)
                surface.flagsChanged(with: rightDown)
                t.pump(0.1)
                let beforeRelease = recorder.transmitted.count
                surface.flagsChanged(with: leftUp)
                t.pump(0.1)
                let released = String(decoding: recorder.transmitted.dropFirst(beforeRelease), as: UTF8.self)
                t.expect(
                    released.contains(":3"),
                    desc:
                        "the left shift going up reports a release while the right is held (sent \(released.debugDescription))"
                )
            }
        }

        UBUITestRegister("swift_shell_ordinary_typing_reaches_the_encoder") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)
                let recorder = TransmitRecorder(forwardingTo: surface.observer)
                surface.observer = recorder
                defer { surface.observer = recorder.takeForward() }
                let nowhere = NSRange(location: NSNotFound, length: 0)

                // A bare printable-ASCII commit with no composition in flight
                // is ordinary typing. The input method is not describing it —
                // the key event is still coming — so this route must not write
                // it and must not mark the key consumed. Written here instead,
                // the bare character goes out where the encoder owed an escape
                // form, and every program that negotiated the Kitty protocol or
                // modifyOtherKeys is silently opted out of it for ordinary keys.
                surface.insertText("a", replacementRange: nowhere)
                t.pump(0.1)
                t.expect(
                    recorder.transmitted.isEmpty,
                    desc: "a bare ASCII commit is left for the encoder (wrote \(recorder.transmitted))"
                )

                // Anything an input method actually composed has no key event
                // behind it, so this route is the only one that can write it.
                surface.insertText("\u{e9}", replacementRange: nowhere)
                t.pump(0.1)
                t.expect(
                    recorder.transmitted == Array("\u{e9}".utf8),
                    desc: "a composed character is written through (wrote \(recorder.transmitted))"
                )

                // The same ASCII 'a' is written after all when it ends a
                // composition: the keys that built it were swallowed as they
                // arrived, so no key event describes the result.
                surface.setMarkedText("a", selectedRange: nowhere, replacementRange: nowhere)
                t.pump(0.1)
                let beforeCommit = recorder.transmitted.count
                surface.insertText("a", replacementRange: nowhere)
                t.pump(0.1)
                t.expect(
                    recorder.transmitted.count == beforeCommit + 1,
                    desc:
                        "an ASCII commit that ends a composition is written (\(recorder.transmitted.count - beforeCommit) byte(s))"
                )
            }
        }

        UBUITestRegister("swift_shell_every_menu_item_reaches_the_shell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeFirstResponder(surface)

                // A menu item with an explicit target dispatches there. For
                // untargeted items, walk the chain rather than asking NSApp:
                // this harness never makes a window key, and
                // `target(forAction:)` searches the KEY window.
                var responders: [NSObject] = []
                var step: NSResponder? = surface
                while let current = step {
                    responders.append(current)
                    step = current.nextResponder
                }
                responders.append(NSApp)
                if let delegate = NSApp.delegate as? NSObject {
                    responders.append(delegate)
                }

                var unanswered: [String] = []
                for menu in NSApp.mainMenu?.items ?? [] {
                    guard let submenu = menu.submenu else { continue }
                    for item in submenu.items {
                        guard let action = item.action else { continue }
                        // A submenu's own opener belongs to NSMenu, which is
                        // not a responder and is never in a chain.
                        guard action != NSSelectorFromString("submenuAction:") else { continue }
                        if let target = item.target {
                            if let target = target as? NSObject, target.responds(to: action) { continue }
                            unanswered.append("\(menu.title)/\(item.title) (\(NSStringFromSelector(action)))")
                            continue
                        }
                        guard !responders.contains(where: { $0.responds(to: action) }) else { continue }
                        unanswered.append("\(menu.title)/\(item.title) (\(NSStringFromSelector(action)))")
                    }
                }
                // Reachability only: whether an item is ENABLED depends on the
                // selection and the shell's marks, and a fresh window has
                // neither. An item nothing answers is the different failure —
                // it is greyed out whatever the state, and its shortcut is
                // silent.
                t.expect(
                    unanswered.isEmpty,
                    desc:
                        "every menu item reaches a responder on a Swift window (\(unanswered.count) do not: \(unanswered.joined(separator: ", ")))"
                )
            }
        }

        UBUITestRegister("swift_shell_live_typing_holds_the_phase_inputs") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                // The reporter's config carries character_spacing as negative
                // float dust from a settings slider — nonzero to every branch,
                // zero to every measurement. Applied here so the run walks the
                // branches the report walked; restored after.
                let savedSpacing = app.settingsCharacterSpacing()
                app.settingsSetCharacterSpacing(-3.46945e-18)
                defer { app.settingsSetCharacterSpacing(savedSpacing) }

                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.4)

                // One keystroke per iteration through the REAL path: pty echo,
                // drain, needsDisplay, a frame the window presents. Every
                // frame's phase inputs must match the first frame's — a drift
                // in either number is the squeeze, and the series is printed so
                // the numbers, not the adjectives, carry the diagnosis.
                var first: TerminalSurface.FramePhaseInputs?
                var series = ""
                var drifts = 0
                var reusedFrames = 0
                var clearedTrustingAPartialSet = 0
                for step in 0..<24 {
                    // Midway, the surface's own stamp goes stale with the model
                    // untouched: visually a no-op, and the one edge that stales
                    // this side's retained stamp while leaving Core's own
                    // eligibility untouched, so the drain still reports the
                    // handful of rows the keystroke dirtied. That combination
                    // is what a frame clearing its target must not trust, and
                    // nothing else a run can reach produces it: a palette
                    // write, a resize and a scroll all fail Core's eligibility
                    // too.
                    if step == 12 {
                        surface.staleRetainedContentForTesting()
                    }
                    surface.send("x")
                    t.pump(0.12)
                    guard let sample = surface.lastFramePhaseInputsForTesting else {
                        t.expect(false, desc: "the surface reports its phase inputs (step \(step))")
                        return
                    }
                    if sample.didReuseLastFrame {
                        reusedFrames += 1
                    } else if sample.didTrustDirtySet {
                        clearedTrustingAPartialSet += 1
                    }
                    guard let reference = first else {
                        first = sample
                        series = "start origin (\(sample.originX),\(sample.originY)) advance \(sample.cellWidth)"
                        continue
                    }
                    if sample.originX != reference.originX || sample.originY != reference.originY
                        || sample.cellWidth != reference.cellWidth
                    {
                        drifts += 1
                        series +=
                            " [\(step): origin (\(sample.originX),\(sample.originY)) advance \(sample.cellWidth) reused=\(sample.didReuseLastFrame)]"
                    }
                }
                t.expect(
                    drifts == 0,
                    desc: "the phase inputs held for 24 echoed keystrokes — \(series)"
                )
                if let reference = first {
                    t.expect(
                        reference.originX == reference.originX.rounded()
                            && reference.originY == reference.originY.rounded(),
                        desc:
                            "the live grid origin is whole device pixels (is \(reference.originX),\(reference.originY)) — a fraction here shifts every pen, and the phase the atlas rasterised stops matching where the ink lands"
                    )
                }
                // The vanishing half of the reported symptom, as a claim a run
                // can refute: a frame that does not Load the retained target is
                // about to clear it, so it owes every row. One that clears and
                // then redraws only the rows the damage named puts the changed
                // text on an empty texture, and every clean row is gone until
                // some later frame rebuilds — text disappearing as the reader
                // types. Counted rather than asserted per step so the failure
                // names how often it happened.
                t.expect(
                    clearedTrustingAPartialSet == 0,
                    desc:
                        "every frame that cleared its target re-read every row (\(clearedTrustingAPartialSet) of 23 cleared while still trusting the dirty set)"
                )
                // Reuse must actually happen, or the claim above is satisfied
                // by a surface that rebuilds the screen on every keystroke —
                // correct pixels at 46 rows a frame, and no retained path left
                // to regress. A boundary capture lands between the echoes, so
                // roughly half the frames are full by design.
                t.expect(
                    reusedFrames >= 4,
                    desc: "reuse census over the run: \(reusedFrames)/23 frames loaded the retained target"
                )
            }
        }
    }
}
