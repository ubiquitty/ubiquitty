// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox
import UbiquittyKit

// LayoutChordScenarios.swift — chords follow the key, not the layout.
//
// ⌘C, ⌃A and ⌃K are muscle memory tied to a key's position. Under a Cyrillic,
// Greek or Hebrew layout the character on that position is not Latin, and a
// chord read from the character matches nothing: Ctrl+ф encoded as the letter
// has no byte form, so it sends nothing. The Latin letter on the
// position comes from the ASCII-capable layout — the one the menu bar
// consults for its own ⌘ equivalents — and Core folds the chord from it.
//
// Each scenario presses the chords as AppKit hands them to the view after the
// user switches layouts: a synthesised press carrying the layout's own
// characters, which is the view's only input either way. Where the runner can
// also select the Russian input source for real, it does, and presses the
// same chords under it: the seam reads the live layout, so under a real
// Russian source a seam that read the selected source rather than the
// ASCII-capable one would answer a Cyrillic letter and the fold would fail —
// a defect the events alone cannot show, since with no switch both sources
// are the runner's Latin layout. A Mac whose text-input session will not take
// the selection (the CI runner's, launched outside a login session) runs the
// events-only pass alone and says so in every description; the chords are
// pressed under the previous source afterwards on both paths. The switch is
// the operator's own input source for the length of the scenario and is
// restored on every path out of it.
//
// ⌘C is the Edit menu's on both shells, and the AppKit menu bar's matching
// is not asked: this harness never makes a window key, and NSMenu validates
// an item through the key window, so its answer here would say nothing about
// the product. (Apple's non-Latin layouts hand the menu bar the Latin letter
// for a ⌘ chord — the same recovery the seam performs — which is why ⌘C works
// in every application under Russian.) What the shells own is asked: the
// Swift surface's claim on the default chords it does hold, ⌘⇧[ among them,
// which resolves through the seam under Russian; both views' key-down
// fallback for ⌘C, which must add nothing to the wire; and the encoder's
// bytes for the control chords.

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

/// The Objective-C terminal view under a window, found by its class name.
///
/// The class is the app's, above the Kit, so a scenario names it the way the
/// Inspector does rather than importing it.
///
/// - Parameter view: The root to search under.
/// - Returns: The view, or nil when the hierarchy holds none.
@MainActor
private func classicTerminalView(under view: NSView) -> NSView? {
    if view is TerminalSurface {
        return view
    }
    for subview in view.subviews {
        if let found = classicTerminalView(under: subview) {
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
}

/// One key press, synthesised the way AppKit delivers it under a layout.
///
/// - Parameters:
///   - characters: What the modifiers produce — the control byte for ⌃A.
///   - unmodified: The layout's own character for the key, Shift excepted.
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

/// Runs `body` with the general pasteboard's string saved and put back, so a
/// copy the scenario makes does not outlive it.
///
/// - Parameter body: The scenario's copy and its assertions.
@MainActor
private func preservingGeneralPasteboard(_ body: @MainActor () -> Void) {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
        NSPasteboard.general.clearContents()
        if let saved {
            NSPasteboard.general.setString(saved, forType: .string)
        }
    }
    body()
}

/// The chords under test, as each layout delivers them.
///
/// The Russian strings are what Apple's layout produces, read off its key
/// layout data: Control on a letter position yields the C0 control, Command
/// yields the Latin letter, and the unmodified character is Cyrillic.
private struct Chord {
    let name: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let latin: (characters: String, unmodified: String)
    let russian: (characters: String, unmodified: String)

    /// The byte the chord puts on the wire, or nil for one the shell claims.
    let wireByte: UInt8?

    static let controlA = Chord(
        name: "Ctrl+A",
        keyCode: 0,
        modifiers: [.control],
        latin: ("\u{01}", "a"),
        russian: ("\u{01}", "ф"),
        wireByte: 0x01
    )
    static let controlK = Chord(
        name: "Ctrl+K",
        keyCode: 40,
        modifiers: [.control],
        latin: ("\u{0B}", "k"),
        russian: ("\u{0B}", "л"),
        wireByte: 0x0B
    )
    static let commandC = Chord(
        name: "Cmd+C",
        keyCode: 8,
        modifiers: [.command],
        latin: ("c", "c"),
        russian: ("c", "с"),
        wireByte: nil
    )
    /// The surface's own previous-tab default. Under Russian the bracket
    /// position carries х, and Shift makes the reported character Х; under a
    /// Latin layout Shift makes it `{`. Both have to resolve to `[`.
    static let commandShiftBracket = Chord(
        name: "Cmd+Shift+[",
        keyCode: 33,
        modifiers: [.command, .shift],
        latin: ("[", "{"),
        russian: ("{", "Х"),
        wireByte: nil
    )
    /// Its next-tab twin, on the position that carries ъ under Russian.
    static let commandShiftRightBracket = Chord(
        name: "Cmd+Shift+]",
        keyCode: 30,
        modifiers: [.command, .shift],
        latin: ("]", "}"),
        russian: ("}", "Ъ"),
        wireByte: nil
    )

    /// The event this chord is under a layout.
    @MainActor
    func event(isRussian: Bool) -> NSEvent? {
        let shape = isRussian ? russian : latin
        return keyPress(characters: shape.characters, unmodified: shape.unmodified, keyCode: keyCode, modifiers: modifiers)
    }
}

/// German Option presses, as AppKit delivers them: the layout's third-level
/// character, the key's own character, and the hardware key code.
///
/// A synthesised event sets the general Option flag without a side bit, which
/// the setting reads as a hold whose side the event does not report.
private let germanOptionPresses: [(characters: String, unmodified: String, keyCode: UInt16)] = [
    ("@", "l", 37),
    ("[", "5", 23),
]

/// The system's keyboard input source, selected for the length of a closure.
@MainActor
private enum InputSource {
    static let russian = "com.apple.keylayout.Russian"
    static let german = "com.apple.keylayout.German"

    /// The selected source's identifier.
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return id(of: source)
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func installed(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }

    private static func isEnabled(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else {
            return false
        }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    /// Runs `body` with `id` selected, then puts the previous source back —
    /// and disables `id` again when this call had to enable it.
    ///
    /// - Parameters:
    ///   - id: The input source to select.
    ///   - t: The harness, pumped so the selection settles before and after.
    ///   - body: What to do under the source.
    /// - Returns: Nil when the source was selected and `body` ran; otherwise
    ///   why this Mac would not take the selection, and `body` did not run.
    static func selecting(_ id: String, _ t: UBUITestContext, _ body: @MainActor () -> Void) -> String? {
        guard let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "no current keyboard input source"
        }
        guard let target = installed(id) else {
            return "\(id) is not installed"
        }
        let wasEnabled = isEnabled(target)
        if !wasEnabled {
            let status = TISEnableInputSource(target)
            if status != noErr {
                return "TISEnableInputSource answered \(status)"
            }
        }
        defer {
            TISSelectInputSource(previous)
            if !wasEnabled {
                TISDisableInputSource(target)
            }
            t.pump(0.2)
        }
        let status = TISSelectInputSource(target)
        guard status == noErr else {
            return "TISSelectInputSource answered \(status)"
        }
        t.pump(0.2)
        guard currentID() == id else {
            return "the selection did not take (current: \(currentID() ?? "?"))"
        }
        body()
        return nil
    }
}

/// Registers the layout-chord scenarios with the UI-test runner.
enum LayoutChordScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_chords_follow_the_key_across_a_layout_switch") { context in
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

                let recorder = TransmitRecorder(forwardingTo: surface.observer)
                surface.observer = recorder

                // The same presses under each layout, so a miss names the
                // layout and the chord rather than the batch.
                @MainActor
                func exercise(_ layout: String, isRussian: Bool) {
                    // Plain text is the layout's own: ф types ф, through the
                    // input method; only a chord follows the key. The fold
                    // reads the position only under Ctrl.
                    let letter = isRussian ? "ф" : "a"
                    if let event = keyPress(characters: letter, unmodified: letter, keyCode: 0, modifiers: []) {
                        let before = recorder.transmitted.count
                        surface.routeKeyPress(event)
                        t.pump(0.05)
                        let sent = Array(recorder.transmitted.dropFirst(before))
                        t.expect(
                            sent == Array(letter.utf8),
                            desc:
                                "a bare \(letter) under \(layout) types itself (sent \(sent.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                        )
                    } else {
                        t.expect(false, desc: "AppKit synthesises a bare \(letter) under \(layout)")
                    }

                    for chord in [Chord.controlA, Chord.controlK] {
                        guard let event = chord.event(isRussian: isRussian), let expected = chord.wireByte else {
                            t.expect(false, desc: "AppKit synthesises \(chord.name) under \(layout)")
                            continue
                        }
                        let before = recorder.transmitted.count
                        surface.routeKeyPress(event)
                        t.pump(0.05)
                        let sent = Array(recorder.transmitted.dropFirst(before))
                        t.expect(
                            sent == [expected],
                            desc:
                                "\(chord.name) under \(layout) reaches the wire as 0x\(String(expected, radix: 16)) alone (sent \(sent.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                        )
                    }

                    // ⌘⇧[ and ⌘⇧] are the surface's own default chords, taken
                    // on the key-equivalent pass the way AppKit offers it
                    // before any key-down. Each is claimed — the tab action
                    // fires, and the recorded direction flips to prove it was
                    // this press — and nothing of it reaches the wire. Under
                    // Russian the reported characters are Х and Ъ, so the
                    // claim is the seam's.
                    guard let copy = Chord.commandC.event(isRussian: isRussian) else {
                        t.expect(false, desc: "AppKit synthesises Cmd+C under \(layout)")
                        return
                    }
                    var before = recorder.transmitted.count
                    for (chord, direction) in [(Chord.commandShiftBracket, -1), (Chord.commandShiftRightBracket, 1)] {
                        guard let event = chord.event(isRussian: isRussian) else {
                            t.expect(false, desc: "AppKit synthesises \(chord.name) under \(layout)")
                            continue
                        }
                        before = recorder.transmitted.count
                        let isClaimed = surface.performKeyEquivalent(with: event)
                        t.pump(0.1)
                        t.expect(isClaimed, desc: "\(chord.name) under \(layout) is claimed by the surface's default chord")
                        t.expect(
                            surface.lastTabSelectionDirectionForTesting == direction,
                            desc: "and its tab action fired (direction \(surface.lastTabSelectionDirectionForTesting), want \(direction))"
                        )
                        t.expect(
                            recorder.transmitted.count == before,
                            desc: "and nothing of it reached the wire (\(recorder.transmitted.count - before) byte(s) did)"
                        )
                    }

                    // ⌘C is the Edit menu's, matched by AppKit before any
                    // key-down. Asked of the view as the fallback AppKit would
                    // take had no item matched: whichever pass it lands on, it
                    // adds nothing to the wire.
                    before = recorder.transmitted.count
                    _ = surface.performKeyEquivalent(with: copy)
                    surface.routeKeyPress(copy)
                    t.pump(0.1)
                    t.expect(
                        recorder.transmitted.count == before,
                        desc:
                            "Cmd+C under \(layout) puts nothing on the wire on either pass (\(recorder.transmitted.count - before) byte(s) did)"
                    )
                }

                let previous = InputSource.currentID() ?? "?"
                // The events-only pass runs on every Mac; the pass under the
                // real source is the control that tells the ASCII-capable
                // source apart from the selected one, where the runner can
                // select it.
                exercise("Russian events", isRussian: true)
                if let reason = InputSource.selecting(InputSource.russian, t, { exercise("the Russian source", isRussian: true) }) {
                    NSLog("LayoutChordScenarios: the Russian source pass did not run on this Mac: %@", reason)
                }
                t.expect(InputSource.currentID() == previous, desc: "the runner's own source, \(previous), is back")
                exercise(previous, isRussian: false)

                // A Latin layout that is not US keeps its own letters: the
                // German Y position carries z, and Ctrl on it is Ctrl+Z — the
                // letter the user sees — not the US position's Ctrl+Y. The
                // seam is not consulted for a Latin layout, and a fixed US
                // table in its place would have sent 0x19 here.
                @MainActor
                func exerciseGerman(_ layout: String) {
                    if let control = keyPress(characters: "\u{1A}", unmodified: "z", keyCode: 16, modifiers: [.control]),
                        let plain = keyPress(characters: "z", unmodified: "z", keyCode: 16, modifiers: [])
                    {
                        var before = recorder.transmitted.count
                        surface.routeKeyPress(control)
                        t.pump(0.05)
                        var sent = Array(recorder.transmitted.dropFirst(before))
                        t.expect(
                            sent == [0x1A],
                            desc:
                                "Ctrl on the German Y position under \(layout) is Ctrl+Z, 0x1a (sent \(sent.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                        )
                        before = recorder.transmitted.count
                        surface.routeKeyPress(plain)
                        t.pump(0.05)
                        sent = Array(recorder.transmitted.dropFirst(before))
                        t.expect(
                            sent == Array("z".utf8),
                            desc:
                                "and bare under \(layout), it types z (sent \(sent.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                        )
                    } else {
                        t.expect(false, desc: "AppKit synthesises the German presses under \(layout)")
                    }
                }
                exerciseGerman("German events")
                if let reason = InputSource.selecting(InputSource.german, t, { exerciseGerman("the German source") }) {
                    NSLog("LayoutChordScenarios: the German source pass did not run on this Mac: %@", reason)
                }
                t.expect(InputSource.currentID() == previous, desc: "the runner's own source, \(previous), is back again")

                // Option is the layout's third level unless `[keys]
                // option_as_alt` makes it Meta. Under none the input method
                // hands @ and [ back to the key path as one-character ASCII
                // commits, and the encoder has to type them rather than send
                // ESC and the key's own character; under both the same presses
                // are Meta. The configuration is process-wide, so the restore
                // is set before anything can return.
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                for (setting, isMeta) in [("none", false), ("both", true)] {
                    t.restoreConfiguration(saved)
                    t.configureAppending("[keys]\noption_as_alt = \"\(setting)\"\n")
                    for press in germanOptionPresses {
                        guard
                            let event = keyPress(
                                characters: press.characters,
                                unmodified: press.unmodified,
                                keyCode: press.keyCode,
                                modifiers: [.option]
                            )
                        else {
                            t.expect(false, desc: "AppKit synthesises German Option+\(press.unmodified)")
                            continue
                        }
                        let before = recorder.transmitted.count
                        surface.routeKeyPress(event)
                        t.pump(0.05)
                        let sent = Array(recorder.transmitted.dropFirst(before))
                        let expected: [UInt8] = isMeta ? [0x1B] + Array(press.unmodified.utf8) : Array(press.characters.utf8)
                        t.expect(
                            sent == expected,
                            desc:
                                "German Option+\(press.unmodified) with option_as_alt \(isMeta ? "both" : "none") sends \(expected.map { String(format: "%02x", $0) }.joined(separator: " ")) (sent \(sent.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                        )
                    }
                }
            }
        }

        UBUITestRegister("objc_shell_chords_follow_the_key_across_a_layout_switch") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The wire is read off the screen: the shell runs a program
                // that prints each byte it reads in caret notation, so a
                // control byte that reached the PTY is a line the grid shows
                // and one that did not is a missing caret pair.
                guard let controller = t.newWindowRunning(["/bin/sh", "-c", "stty -echo; LC_ALL=C exec cat -v"]),
                    let window = controller.window,
                    let content = window.contentView,
                    let view = classicTerminalView(under: content)
                else {
                    t.expect(false, desc: "a classic-shell window opens with its terminal view")
                    return
                }
                defer { t.closeAllWindows() }
                t.pump(0.6)
                window.makeFirstResponder(view)

                @MainActor
                func exercise(_ layout: String, isRussian: Bool, marker: String) {
                    for chord in [Chord.controlA, Chord.controlK, Chord.commandC] {
                        guard let event = chord.event(isRussian: isRussian) else {
                            t.expect(false, desc: "AppKit synthesises \(chord.name) under \(layout)")
                            continue
                        }
                        // The view's own key-down: what AppKit sends once no
                        // key equivalent claimed the press. In a live window
                        // the menu bar takes ⌘C before this; asked here as
                        // the fallback it is, it must add nothing to the
                        // wire — that view has no default chord of
                        // its own and the copy is the menu's.
                        view.keyDown(with: event)
                        t.pump(0.05)
                    }
                    // Plain text is the layout's own, through the input
                    // method: ф is the two bytes of its UTF-8, which the
                    // program prints in caret notation as M-QM-^D — in the C
                    // locale; a UTF-8 one passes the first byte through raw.
                    let letter = isRussian ? "ф" : "a"
                    if let event = keyPress(characters: letter, unmodified: letter, keyCode: 0, modifiers: []) {
                        view.keyDown(with: event)
                        t.pump(0.05)
                    } else {
                        t.expect(false, desc: "AppKit synthesises a bare \(letter) under \(layout)")
                    }
                    t.sendText("\(marker)\r", to: controller)
                    let line = "^A^K\(isRussian ? "M-QM-^D" : "a")\(marker)"
                    let isShown = t.wait(forText: line, in: controller, timeout: 6.0)
                    let grid = t.gridText(of: controller).trimmingCharacters(in: .whitespacesAndNewlines)
                    t.expect(
                        isShown,
                        desc:
                            "under \(layout) Ctrl+A and Ctrl+K reach the PTY as 0x01 0x0b, Cmd+C adds nothing and \(letter) types itself: the shell shows \(line.debugDescription) (grid: \(grid.debugDescription))"
                    )
                }

                let previous = InputSource.currentID() ?? "?"
                // As on the Swift shell: the events-only pass everywhere, the
                // pass under the real source where the runner can select it.
                exercise("Russian events", isRussian: true, marker: "E")
                if let reason = InputSource.selecting(
                    InputSource.russian,
                    t,
                    { exercise("the Russian source", isRussian: true, marker: "R") }
                ) {
                    NSLog("LayoutChordScenarios: the Russian source pass did not run on this Mac: %@", reason)
                }
                t.expect(InputSource.currentID() == previous, desc: "the runner's own source, \(previous), is back")
                exercise(previous, isRussian: false, marker: "L")

                // German Option presses under each `[keys] option_as_alt`: the
                // layout's characters under none, ESC and the key's own
                // character under both, which the program prints as ^[.
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                for (setting, isMeta, marker) in [("none", false, "N"), ("both", true, "B")] {
                    t.restoreConfiguration(saved)
                    t.configureAppending("[keys]\noption_as_alt = \"\(setting)\"\n")
                    for press in germanOptionPresses {
                        guard
                            let event = keyPress(
                                characters: press.characters,
                                unmodified: press.unmodified,
                                keyCode: press.keyCode,
                                modifiers: [.option]
                            )
                        else {
                            t.expect(false, desc: "AppKit synthesises German Option+\(press.unmodified)")
                            continue
                        }
                        view.keyDown(with: event)
                        t.pump(0.05)
                    }
                    t.sendText("\(marker)\r", to: controller)
                    let typed = germanOptionPresses.map { isMeta ? "^[\($0.unmodified)" : $0.characters }.joined()
                    let line = "\(typed)\(marker)"
                    let isShown = t.wait(forText: line, in: controller, timeout: 6.0)
                    let grid = t.gridText(of: controller).trimmingCharacters(in: .whitespacesAndNewlines)
                    t.expect(
                        isShown,
                        desc:
                            "German Option+L and Option+5 with option_as_alt \(isMeta ? "both" : "none") reach the PTY as the shell shows \(line.debugDescription) (grid: \(grid.debugDescription))"
                    )
                }
            }
        }
    }
}
