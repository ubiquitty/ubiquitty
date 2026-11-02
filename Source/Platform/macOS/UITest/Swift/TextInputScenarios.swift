// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// TextInputScenarios.swift — what the surface answers an input method that
// asks about its own composition.
//
// The composition is the only text a terminal can be asked about, and an
// input method counts it in UTF-16 units. These drive the surface through the
// NSTextInputClient calls AppKit makes and read the answers back, with a
// composition whose grapheme count and UTF-16 length differ so a client
// counting the wrong unit cannot pass.

/// Registers the text-input scenarios with the UI-test runner.
enum TextInputScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_input_method_queries_answer_in_utf16_units") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = t.newWindowRunning(["/bin/cat"]), let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)
                let nowhere = NSRange(location: NSNotFound, length: 0)

                t.expect(surface.markedRange() == nowhere, desc: "no composition answers a not-found marked range")
                t.expect(surface.selectedRange() == nowhere, desc: "and a not-found selection")

                // One grapheme, two UTF-16 units, caret after it.
                surface.setMarkedText("🍣", selectedRange: NSRange(location: 2, length: 0), replacementRange: nowhere)
                t.expect(
                    surface.markedRange() == NSRange(location: 0, length: 2),
                    desc: "the marked range counts UTF-16 units (\(surface.markedRange()))"
                )
                t.expect(
                    surface.selectedRange() == NSRange(location: 2, length: 0),
                    desc: "the input method's caret is answered back (\(surface.selectedRange()))"
                )
                var actual = nowhere
                t.expect(
                    surface.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &actual)?.string == "🍣",
                    desc: "a substring query never cuts a surrogate pair"
                )
                t.expect(actual == NSRange(location: 0, length: 2), desc: "and says it covered the whole character (\(actual))")

                surface.setMarkedText("にほん", selectedRange: NSRange(location: 1, length: 1), replacementRange: nowhere)
                t.expect(surface.selectedRange() == NSRange(location: 1, length: 1), desc: "a selection inside the composition is kept")
                t.expect(
                    surface.attributedSubstring(forProposedRange: NSRange(location: 1, length: 1), actualRange: &actual)?.string == "ほ",
                    desc: "a reconversion query is answered from the composition"
                )
                t.expect(
                    surface.attributedSubstring(forProposedRange: NSRange(location: 10, length: 4), actualRange: &actual)?.string == "にほん",
                    desc: "a proposal outside the composition is answered with all of it"
                )
                t.expect(actual == NSRange(location: 0, length: 3), desc: "and the range says so (\(actual))")

                surface.setMarkedText("にほん", selectedRange: NSRange(location: 9, length: 4), replacementRange: nowhere)
                t.expect(
                    surface.selectedRange() == NSRange(location: 3, length: 0),
                    desc: "a selection past the end is held to the composition (\(surface.selectedRange()))"
                )

                // An empty commit ends the composition it answers.
                surface.insertText("", replacementRange: nowhere)
                t.expect(!surface.hasMarkedText(), desc: "an empty commit ends the composition")
                t.expect(surface.markedRange() == nowhere, desc: "so the marked range is not found again")
                t.expect(surface.selectedRange() == nowhere, desc: "and so is the selection")
                t.expect(
                    surface.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &actual) == nil,
                    desc: "and a substring query has no text to answer with"
                )
                t.expect(actual == nowhere, desc: "and says so in the range")
            }
        }
    }
}
