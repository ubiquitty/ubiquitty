// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// AppKit's, and macOS-only: the prompts it serves are an agent asking to drive
// a session, a program asking to read the clipboard, an install asking to copy
// a binary to a remote host, and a remote host asking to write files onto this
// disk. The phone raises none of them.

#if canImport(AppKit)

//
// ConsentAlert.swift — the one way this app asks a human to permit something.
//
// AppKit makes the FIRST button added to an NSAlert the default, so Return
// activates it. A permission prompt that lists its allowing button first
// therefore grants on a keystroke aimed at whatever the sheet appeared over,
// which is the shape a permission prompt must never have. The safe
// order adds Deny first, so it is the default (Return) and the prompt fails
// safe.
//
// So the ordering is not advice here, it is the only way to build one of these:
// the refusal is added by this type, before anything a caller passes. A rule
// spelled at four call sites is a rule that holds at two of them.
//
// Two readings of the same answer, because the prompts split in two. Most ask
// for a GRANT, whose answer is a scope — this once, this session, from now
// on — and those go through Core's `consentDecisionForButtonIndex`, the same
// pure mapping an Objective-C dialog calls. The transfer prompt asks a plain
// question with two ways to say yes, and calling its second button a
// session-lived grant would be a lie told to make one signature fit. It reads
// the choice instead. Both readings share the one thing that matters: a
// response that is not an allowing button is a refusal.
//

import AppKit
package import UbiquittyRenderKit

internal import UbiquittyCore

/// The permission question, as this app asks it.
package enum ConsentAlert {
    /// Asks `alert`'s question and reports the grant scope the human chose.
    ///
    /// The refusal button is added first, so it is the default and Return
    /// refuses. Escape is left alone: an alert with no escape-equivalent button
    /// either ignores the key or dismisses the sheet, and a dismissal maps to
    /// ``ConsentDecision/deny`` like every other non-answer, so both readings
    /// are safe. Naming the refusal as the escape route instead would take the
    /// Return key away from it.
    ///
    /// The allowing titles are positional, and their positions are Core's: the
    /// first grants once, the second for the session, the third from now on. A
    /// prompt offering fewer offers the earlier ones, and one offering a single
    /// allowing button can never produce a remembered grant — the mapping is
    /// told how many were on screen and refuses the scopes that were not.
    ///
    /// - Parameters:
    ///   - alert: The question, with its wording and style already set. It must
    ///     carry no buttons; this adds all of them.
    ///   - refusal: The refusing button's title — "Deny", "Not Now".
    ///   - scopes: The allowing buttons' titles, widest-lived last.
    ///   - window: The window to sheet the alert onto. App-modal when nil,
    ///     which is what a prompt with no window to attach to must do rather
    ///     than answer for the person.
    ///   - answer: What the human chose, on the main actor.
    @MainActor
    package static func ask(
        _ alert: NSAlert,
        refusing refusal: String,
        allowing scopes: [String],
        on window: NSWindow?,
        answer: @escaping (ConsentDecision) -> Void
    ) {
        addButtons(to: alert, refusal: refusal, allowing: scopes)

        // A prompt that offered one allowing button is per-use by construction:
        // there was no session or always button to press, so Core refuses those
        // scopes for it however the response arrives. This is the same argument
        // the capability tiers make — read off the dialog that was actually
        // built rather than passed alongside it, so the two cannot disagree.
        let isPerUse = scopes.count < 2
        let resolve: (NSApplication.ModalResponse) -> Void = { response in
            let chosen = allowingButton(for: response, of: scopes.count)
            let decided = Ubiquitty.Security.consentDecisionForButtonIndex(Int32(chosen), isPerUse)
            answer(ConsentDecision(rawValue: decided.rawValue) ?? .deny)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: resolve)
        } else {
            resolve(alert.runModal())
        }
    }

    /// Asks `alert`'s question app-modally and reports which way the human said
    /// yes, or that they did not.
    ///
    /// For a question whose allowing buttons are alternatives rather than
    /// scopes, so there is no lifetime to report — the ZMODEM prompt's "receive
    /// it here" and "let me pick where" permit the same thing.
    ///
    /// - Parameters:
    ///   - alert: The question, with its wording and style already set. It must
    ///     carry no buttons; this adds all of them.
    ///   - refusal: The refusing button's title.
    ///   - choices: The allowing buttons' titles.
    /// - Returns: The 1-based allowing button the human pressed, or 0 for the
    ///   refusal and for every other way the alert can end.
    @MainActor
    package static func choose(
        _ alert: NSAlert,
        refusing refusal: String,
        between choices: [String]
    ) -> Int {
        addButtons(to: alert, refusal: refusal, allowing: choices)
        return allowingButton(for: alert.runModal(), of: choices.count)
    }

    /// Asks `alert`'s question, sheeted where a window is given, and reports
    /// which way the human said yes, or that they did not.
    ///
    /// The same reading as the app-modal ``choose(_:refusing:between:)``, for
    /// a question whose window must stay usable while it is asked.
    ///
    /// - Parameters:
    ///   - alert: The question, with its wording and style already set. It must
    ///     carry no buttons; this adds all of them.
    ///   - refusal: The refusing button's title.
    ///   - choices: The allowing buttons' titles.
    ///   - window: The window to sheet the alert onto; app-modal when nil.
    ///   - answer: The 1-based allowing button pressed, or 0 for the refusal
    ///     and for every other way the alert can end, on the main actor.
    @MainActor
    package static func choose(
        _ alert: NSAlert,
        refusing refusal: String,
        between choices: [String],
        on window: NSWindow?,
        answer: @escaping (Int) -> Void
    ) {
        addButtons(to: alert, refusal: refusal, allowing: choices)
        if let window {
            alert.beginSheetModal(for: window) { response in
                answer(allowingButton(for: response, of: choices.count))
            }
        } else {
            answer(allowingButton(for: alert.runModal(), of: choices.count))
        }
    }

    /// The allowing buttons for a prompt offering a one-shot grant and one that
    /// lasts as long as the session.
    ///
    /// One spelling, because two prompts asking the same question in different
    /// words read as two different questions — and because the words are what
    /// tell the person which of the positional scopes they are picking.
    package static let onceOrSession = ["Allow Once", "Allow This Session"]

    /// Refusal first, then the rest in the order given.
    ///
    /// - Parameters:
    ///   - alert: The alert to build.
    ///   - refusal: The refusing button's title.
    ///   - allowing: The allowing buttons' titles.
    @MainActor
    private static func addButtons(to alert: NSAlert, refusal: String, allowing: [String]) {
        alert.addButton(withTitle: refusal)
        for title in allowing {
            alert.addButton(withTitle: title)
        }
        // Taken back, because AppKit gives a button titled "Cancel" the Escape
        // key instead and leaves the panel with no default button at all —
        // measured here, and not what the folklore says, which is that Return
        // moves to the next button. Either way the safest key stops refusing,
        // and a caller's choice of word should not be how that happens.
        alert.buttons.first?.keyEquivalent = "\r"
    }

    /// Which allowing button a modal response names, counting from one.
    ///
    /// Zero for the refusal, and zero for every response that is not a button
    /// this alert put on screen: a dismissed sheet, a stale response, an index
    /// past the buttons that were offered. That is the whole fail-safe, and it
    /// is here rather than at each call site because a caller reading the
    /// response itself is a caller that can get it wrong.
    ///
    /// - Parameters:
    ///   - response: What the alert returned.
    ///   - count: How many allowing buttons it carried.
    /// - Returns: The 1-based allowing button, or 0.
    private static func allowingButton(for response: NSApplication.ModalResponse, of count: Int) -> Int {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return index >= 1 && index <= count ? index : 0
    }
}

#endif
