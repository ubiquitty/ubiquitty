// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// KeyBindingScenarios.swift — the user's [keys] section, on a Kit-hosted
// window.
//
// The machinery is shared — Input::BindingTable parses the specs,
// Input::ChordResolver runs the leader state machine, and the Web and Linux
// frontends drive both. What this file pins is this arm asking: without it, a
// binding written in the config does nothing, and the key types itself instead.
//
// So the assertions are about the two things a user notices: a bound chord
// does its thing rather than typing, and a leader waits for its second key
// instead of sending the first.

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

/// Records what a surface transmits.
@MainActor
private final class TransmitRecorder: TerminalSurfaceObserver {
    private(set) var transmitted: [UInt8] = []

    nonisolated func terminalSurface(_ surface: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        let taken = bytes.prefix(count).map { UInt8(bitPattern: $0) }
        MainActor.assumeIsolated { transmitted.append(contentsOf: taken) }
    }
}

/// One key press, synthesised the way AppKit would deliver it.
@MainActor
private func keyPress(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )
}

/// Registers the key-binding scenarios with the UI-test runner.
enum KeyBindingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_honours_a_keys_binding") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Bindings configured through a `[keys]` document: a single
                // chord that sends bytes, and a leader whose first key must be
                // swallowed rather than typed. What is under test is the
                // resolver being consulted; the parser reading the table has
                // tests of its own. The actions are quoted from the raw text
                // the resolver decodes, so the escapes reach it unread.
                let saved = t.configureAppending(
                    "[keys]\n"
                        + "\"ctrl+alt+j\" = \(tomlQuoted("send:\\x1b[99~"))\n"
                        + "\"ctrl+alt+g ctrl+alt+h\" = \"send:LEADER\"\n"
                        + "\"ctrl+alt+b\" = \(tomlQuoted("send:\\xFF\\x00B"))\n"
                        + "\"ctrl+alt+m\" = \"macro:parity-bytes\"\n"
                        + "[macros]\n"
                        + "\"parity-bytes\" = \(tomlQuoted("\\x80\\x00M"))\n"
                        + "\"parity-invalid\" = \(tomlQuoted("\\xZZ"))\n"
                )
                defer { t.restoreConfiguration(saved) }

                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                let recorder = TransmitRecorder()
                surface.observer = recorder

                // The bound chord fires its bytes instead of typing 'j'.
                if let event = keyPress("j", keyCode: 38, modifiers: [.control, .option]) {
                    surface.routeKeyPress(event)
                    t.pump(0.1)
                }
                t.expect(
                    recorder.transmitted == [0x1b, 0x5b, 0x39, 0x39, 0x7e],
                    desc:
                        "the bound chord sent its bytes (\(recorder.transmitted.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                )
                t.expect(
                    !recorder.transmitted.contains(0x6a),
                    desc: "and did not also type the key it was bound to"
                )

                let beforeBinary = recorder.transmitted.count
                if let event = keyPress("b", keyCode: 11, modifiers: [.control, .option]) {
                    surface.routeKeyPress(event)
                }
                t.expect(
                    Array(recorder.transmitted.dropFirst(beforeBinary)) == [0xff, 0, 0x42],
                    desc: "send bindings preserve invalid UTF-8 and embedded null bytes"
                )
                let beforeMacro = recorder.transmitted.count
                if let event = keyPress("m", keyCode: 46, modifiers: [.control, .option]) {
                    surface.routeKeyPress(event)
                }
                t.expect(
                    Array(recorder.transmitted.dropFirst(beforeMacro)) == [0x80, 0, 0x4d],
                    desc: "a macro binding decodes and sends the exact configured bytes"
                )
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.1)
                let beforeMenu = recorder.transmitted.count
                MacroActions.invokeNamed("parity-bytes", in: shell.window)
                t.expect(
                    Array(recorder.transmitted.dropFirst(beforeMenu)) == [0x80, 0, 0x4d],
                    desc: "the menu's window dispatcher reaches the Swift surface and preserves the same payload"
                )
                let beforeMissingMacro = recorder.transmitted.count
                surface.invokeMacro(named: "parity-no-such-macro")
                surface.invokeMacro(named: "parity-invalid")
                t.expect(
                    recorder.transmitted.count == beforeMissingMacro,
                    desc: "missing and malformed macros send nothing"
                )

                // The leader's first key is swallowed, not sent.
                let beforeLeader = recorder.transmitted.count
                if let event = keyPress("g", keyCode: 5, modifiers: [.control, .option]) {
                    surface.routeKeyPress(event)
                    t.pump(0.1)
                }
                t.expect(
                    recorder.transmitted.count == beforeLeader,
                    desc: "a leader's first key sends nothing while the chord captures"
                )

                // And its second completes the chord.
                if let event = keyPress("h", keyCode: 4, modifiers: [.control, .option]) {
                    surface.routeKeyPress(event)
                    t.pump(0.1)
                }
                let after = Array(recorder.transmitted.dropFirst(beforeLeader))
                t.expect(
                    after == Array("LEADER".utf8),
                    desc:
                        "the second key completes it (\(String(decoding: after, as: UTF8.self)))"
                )
            }
        }

        UBUITestRegister("swift_shell_composes_after_the_keys_config_changes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // An empty compose key is the unconfigured one.
                let saved = t.configureAppending("[keys]\ncompose_key = \"\"\n")
                defer { t.restoreConfiguration(saved) }

                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                let recorder = TransmitRecorder()
                surface.observer = recorder
                let acute: [UInt8] = Array("é".utf8)

                // The surface was built with no compose key, so the sequence
                // types itself. This is the control: without it, a composed
                // character below would prove nothing about the rebuild.
                for (characters, keyCode) in [("k", UInt16(40)), ("'", UInt16(39)), ("e", UInt16(14))] {
                    if let event = keyPress(characters, keyCode: keyCode, modifiers: characters == "k" ? [.control, .option] : []) {
                        surface.routeKeyPress(event)
                        t.pump(0.1)
                    }
                }
                t.expect(
                    !recorder.transmitted.contains(acute[0]),
                    desc: "an unconfigured compose key composes nothing"
                )

                // The reader edits [keys] and saves. The notice is what the
                // settings pane posts; both shells watch it.
                t.restoreConfiguration(saved)
                t.configureAppending("[keys]\ncompose_key = \"ctrl+alt+k\"\n")
                NotificationCenter.default.post(
                    name: TerminalSurface.keyBindingsDidChangeNotification,
                    object: nil
                )
                t.pump(0.3)

                let beforeCompose = recorder.transmitted.count
                for (characters, keyCode) in [("k", UInt16(40)), ("'", UInt16(39)), ("e", UInt16(14))] {
                    if let event = keyPress(characters, keyCode: keyCode, modifiers: characters == "k" ? [.control, .option] : []) {
                        surface.routeKeyPress(event)
                        t.pump(0.1)
                    }
                }
                let composed = Array(recorder.transmitted.dropFirst(beforeCompose))
                t.expect(
                    composed == acute,
                    desc:
                        "the trigger and its sequence compose one character (\(composed.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                )

                // A binding on the same chord wins: the bindings are asked
                // first, and a reader who bound a key meant the binding.
                t.restoreConfiguration(saved)
                t.configureAppending("[keys]\ncompose_key = \"ctrl+alt+k\"\n\"ctrl+alt+k\" = \"send:BOUND\"\n")
                NotificationCenter.default.post(
                    name: TerminalSurface.keyBindingsDidChangeNotification,
                    object: nil
                )
                t.pump(0.3)

                let beforeBound = recorder.transmitted.count
                if let event = keyPress("k", keyCode: 40, modifiers: [.control, .option]) {
                    surface.routeKeyPress(event)
                    t.pump(0.1)
                }
                let bound = Array(recorder.transmitted.dropFirst(beforeBound))
                t.expect(
                    bound == Array("BOUND".utf8),
                    desc: "a binding on the compose key wins (\(String(decoding: bound, as: UTF8.self)))"
                )
            }
        }
    }
}
