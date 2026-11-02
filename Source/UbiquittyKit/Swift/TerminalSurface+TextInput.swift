// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// This half of the surface is AppKit's. The events it answers — mouse
// buttons, a scroll wheel with momentum, NSEvent modifier flags, the
// AppKit text-input client — have no counterpart on a touch screen, so the
// UIKit shell answers its own and neither carries the other's model.
//
// Guarded rather than moved: it extends the shared surface, and keeping it
// beside what it extends is what stops the two halves drifting apart.

#if canImport(AppKit)

// TerminalSurface+TextInput.swift — composed text reaches the host.
//
// A terminal wants two incompatible things from one keystroke. A control or
// escape sequence has to reach the encoder untouched, and a Japanese or Chinese
// composition has to reach the input method, which consumes several keystrokes
// and hands back one string. Routing every key through the input method breaks
// the first; routing none through it breaks the second.
//
// The rule Core states is which of the two a key belongs to, so both frontends
// answer it the same way. The surface adds the one fact AppKit owns: whether a
// composition is already in flight, which outranks the rule for as long as it
// lasts.

import AppKit
internal import UbiquittyCore

// AppKit drives the input client from the responder chain, so the
// conformance is the main actor's.
extension TerminalSurface: @MainActor NSTextInputClient {
    /// Swallows the editor command the input method derived from a key.
    ///
    /// The input method routes any key it does not compose with as an editor
    /// command — Ctrl+A arrives as `moveToBeginningOfLine:`, a delete as
    /// `deleteBackward:` — and `NSResponder`'s inherited implementation, which
    /// otherwise satisfies this protocol requirement, announces every one of
    /// them with a beep. A terminal is not a text view: the encoder owns these
    /// keys, and ``routeKeyPress(_:)`` sends the raw key whenever the input
    /// method commits nothing, so the command itself carries no information the
    /// encode does not. The Metal arm's override is empty for the same reason.
    ///
    /// - Parameter selector: The command, unperformed.
    override public func doCommand(by selector: Selector) {
        editorCommandsSwallowedForTesting += 1
    }

    public func hasMarkedText() -> Bool {
        isComposing
    }

    /// The range the composition occupies, in the UTF-16 units the input
    /// method counts in.
    ///
    /// - Returns: The whole composition, or not found when none is in flight.
    public func markedRange() -> NSRange {
        Self.toolkitRange(Ubiquitty.Input.markedCompositionRange(UInt64(composedText.utf16.count)))
    }

    /// The caret or selection the input method placed inside its composition.
    ///
    /// - Returns: The input method's own selection held inside the
    ///   composition, or not found when none is in flight — the terminal has
    ///   no editable document for a caret to sit in otherwise.
    public func selectedRange() -> NSRange {
        Self.toolkitRange(
            Ubiquitty.Input.selectedCompositionRange(
                UInt64(composedText.utf16.count),
                UInt64(clamping: markedSelection.location),
                UInt64(clamping: markedSelection.length)
            )
        )
    }

    /// Replaces the composition in flight.
    ///
    /// - Parameters:
    ///   - string: The composition, as `String` or `NSAttributedString`.
    ///   - selectedRange: Which part of it the input method has selected, kept
    ///     for ``selectedRange()``.
    ///   - replacementRange: The range to replace; the terminal has no editable
    ///     document, so the composition always replaces the whole of itself.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        composeText(Self.plainText(from: string), selecting: selectedRange)
        inputContext?.invalidateCharacterCoordinates()
    }

    public func unmarkText() {
        guard isComposing else { return }
        cancelComposition()
        inputContext?.invalidateCharacterCoordinates()
    }

    /// Commits text to the host.
    ///
    /// - Parameters:
    ///   - string: The committed text.
    ///   - replacementRange: Unused; the terminal has no editable document.
    public func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = Self.plainText(from: string)
        // An empty commit still ends the composition it answers: the input
        // method has nothing left marked, and a stale composition would keep
        // claiming every key.
        guard !text.isEmpty else {
            unmarkText()
            return
        }
        let endsComposition = hasMarkedText()
        // A commit that ends a composition is composed whatever its text: the
        // keys that built it were swallowed as they arrived. Otherwise Core
        // decides, and for ordinary typing it says no — the key event is still
        // coming, and `keyDown` hands it to the encoder that applies the
        // control forms, modifyOtherKeys and the Kitty protocol. Committing it
        // here instead writes the bare character and leaves the generation
        // moved, which is this arm's way of saying the input method consumed
        // the key: a program that negotiated any of those encodings would be
        // opted out of it for every key it typed.
        let isComposed =
            hasMarkedText()
            || Ubiquitty.Keys.isComposedCommit(
                UInt32(text.utf16.count),
                UInt32(text.utf16.first ?? 0)
            )
        guard isComposed else { return }
        commitComposedText(text)
        if endsComposition {
            inputContext?.invalidateCharacterCoordinates()
        }
    }

    /// Where the input method should put its candidate window.
    ///
    /// The cursor cell in screen coordinates, so the candidates appear under the
    /// text being composed rather than at the window's origin.
    ///
    /// - Parameters:
    ///   - range: The character range being asked about, which for a terminal is
    ///     always the composition and always at the cursor.
    ///   - actualRange: Receives the range this rectangle covers.
    /// - Returns: The cursor cell, in screen coordinates.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = compositionAnchorRect()
        return window?.convertToScreen(convert(local, to: nil)) ?? local
    }

    /// The composition's text over a range the input method proposes.
    ///
    /// The composition is the only text a terminal can be asked about: the
    /// committed screen is not an editable document. Core decides which part
    /// of the composition answers the proposal, and the answer is widened to
    /// whole composed characters so a surrogate pair is never cut in half.
    ///
    /// - Parameters:
    ///   - range: The proposed range, in UTF-16 units.
    ///   - actualRange: Receives the range the answer covers, or not found.
    /// - Returns: The text, or nil when no composition is in flight.
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = composedText as NSString
        let answer = Ubiquitty.Input.compositionSubstringRange(
            UInt64(text.length),
            UInt64(clamping: range.location),
            UInt64(clamping: range.length)
        )
        guard answer.isPresent else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let covered = text.rangeOfComposedCharacterSequences(for: Self.toolkitRange(answer))
        actualRange?.pointee = covered
        return NSAttributedString(string: text.substring(with: covered))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func characterIndex(for _: NSPoint) -> Int {
        NSNotFound
    }

    /// Spells a Core composition range the way AppKit reads one.
    ///
    /// - Parameter range: Core's answer.
    /// - Returns: The range, or AppKit's not-found range.
    private static func toolkitRange(_ range: Ubiquitty.Input.CompositionRange) -> NSRange {
        guard range.isPresent else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: Int(range.location), length: Int(range.length))
    }

    /// Reads either spelling AppKit uses for text input.
    ///
    /// - Parameter value: A `String` or an `NSAttributedString`.
    /// - Returns: The characters, or empty for anything else.
    private static func plainText(from value: Any) -> String {
        switch value {
        case let string as String: string
        case let attributed as NSAttributedString: attributed.string
        default: ""
        }
    }
}

extension TerminalSurface {
    /// Routes one key press between the encoder and the input method.
    ///
    /// Three outcomes, in the order they are decided. A key Core classes as
    /// terminal input goes straight to the encoder, unless a composition is in
    /// flight — an input method mid-composition owns every key until it commits
    /// or cancels, including the ones that would otherwise encode. Otherwise the
    /// key goes to the input method, and if that produced neither committed text
    /// nor a composition, it falls through to the encoder so an unmapped key
    /// still reaches the host.
    ///
    /// - Parameter event: The key press.
    public func routeKeyPress(_ event: NSEvent) {
        // Cmd+1..9 selects a tab, and the parse of "is this that" is Core's —
        // digit, accelerator-only, nothing else held. Before the bindings so a
        // user who rebinds a digit still wins: their table is consulted first
        // and this only runs when nothing matched.
        if selectTabForCommandNumber(event) {
            return
        }
        // The user's [keys] bindings get the key before the input method and
        // before the default keymap. A bound chord means that chord, not
        // whatever the layout would have produced from it.
        if consultKeyBindings(event) == .consumed {
            return
        }
        if drive.readSnapshot().modes.shouldReportKeyPositions {
            sendKey(event, eventType: .Press)
            return
        }
        // Terminal-decoded compose ([keys] compose_key), after the bindings
        // and before the input method: the trigger key and the run after it
        // are the terminal's, not the platform's.
        if consultComposeKey(event) == .consumed {
            return
        }
        // Option is Meta only on the sides `[keys] option_as_alt` names, read
        // live so an edit applies to the next key. An Option key it does not
        // name falls through to the input method, which types the layout's
        // character or opens its dead key; a one-character ASCII commit comes
        // back to the encoder, which types it without the Option bit.
        let flags = event.modifierFlags
        let bypasses = Ubiquitty.Input.eventShouldBypassTextInputForTerminalEncoding(
            Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee),
            Self.heldOptionKeys(flags),
            flags.contains(.command) ? .Held : .Up
        )
        if bypasses, !hasMarkedText() {
            sendKey(event, eventType: Ubiquitty.Keys.KeyEventType.Press)
            return
        }
        // The count is what says whether the input method consumed the key:
        // `insertText` commits and `setMarkedText` composes, and either one
        // means the key is spoken for. A key the input method ignored leaves
        // both untouched and has to reach the encoder.
        let before = textInputGeneration
        inputContext?.handleEvent(event)
        if hasMarkedText() || textInputGeneration != before {
            return
        }
        sendKey(event, eventType: Ubiquitty.Keys.KeyEventType.Press)
    }
}

#endif
