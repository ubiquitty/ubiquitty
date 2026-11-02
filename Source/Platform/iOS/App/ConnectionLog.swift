// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the session did while connecting, step by step.
///
/// The transport row says which carrier won. That is the verdict and not the
/// story, and for a fallback the story is the part worth having: a QUIC dial
/// that fails ends on SSH with a working shell, so "QUIC is broken" and "QUIC
/// was never attempted" are the same picture from the grid. `quicRefusal` names
/// the last step that went wrong; this names every step that came before it,
/// which is what separates a host with no daemon from a daemon that answered
/// and a carrier that then refused.
///
/// The bootstrap token is excluded. It is a bearer credential — whoever holds
/// it can open the session — and a debugging log is the thing a person
/// screenshots into a bug report. The port and a short pin prefix identify a
/// dial well enough to debug it, so `note(bootstrapAnswered:)` is the only
/// entry point for that answer and it takes the parts it may keep rather than
/// the whole reply.
@MainActor
final class ConnectionLog {
    static let maximumEntries = 128
    static let maximumMessageBytes = 2048
    /// One step, at the moment it happened.
    struct Entry: Identifiable {
        let id = UUID()
        /// Seconds since the attempt began. Relative because the interesting
        /// quantity is how long a step took, not what time it was: a bootstrap
        /// that answers in 4s is a different fault from one that answers in 40.
        let offset: TimeInterval
        let message: String

        /// `  0.42s  the message`, for a fixed-width column that stays aligned.
        var line: String {
            String(format: "%6.2fs  %@", offset, message)
        }
    }

    /// A step a person would name, in a sentence of their words, with how it
    /// came out.
    ///
    /// Beside the entries rather than in place of them: the entries are what
    /// the code saw, a step is what that meant — "Reached 127.0.0.1:22",
    /// "Signed in as ui" — and Connection Details shows the steps with the
    /// raw entries behind a disclosure.
    struct Step: Identifiable {
        enum Outcome {
            case succeeded
            case failed
        }

        let id = UUID()
        let offset: TimeInterval
        let sentence: String
        let outcome: Outcome
        /// The raw entry behind the step, when there is one worth showing.
        let detail: String
    }

    static let maxSteps = 32

    private(set) var entries: [Entry] = []
    private(set) var steps: [Step] = []
    private var startedAt = Date()

    /// Begins a fresh attempt, discarding the previous one.
    ///
    /// Per attempt rather than appended forever: a reader debugging a reconnect
    /// wants the reconnect, and an unbounded log on a phone that redials every
    /// path change grows without anything ever reading the old end.
    func begin(_ message: String) {
        startedAt = Date()
        entries = []
        steps = []
        note(message)
    }

    /// Records a step a person would name, logging its raw detail as an
    /// entry too.
    ///
    /// - Parameters:
    ///   - sentence: What happened, in the person's words.
    ///   - outcome: Whether it went through.
    ///   - detail: The raw description behind it, empty when the sentence is
    ///     all there is.
    func step(_ sentence: String, _ outcome: Step.Outcome, detail: String = "") {
        if !detail.isEmpty { note(detail) }
        // A repeated step — the same dial reported twice — reads as one.
        if let last = steps.last, last.sentence == sentence, last.outcome == outcome { return }
        if steps.count == Self.maxSteps { steps.removeFirst() }
        steps.append(
            Step(
                offset: Date().timeIntervalSince(startedAt),
                sentence: Self.bounded(sentence),
                outcome: outcome,
                detail: Self.bounded(detail)
            )
        )
    }

    /// Records one step.
    func note(_ message: String) {
        if entries.count == Self.maximumEntries { entries.removeFirst() }
        entries.append(Entry(offset: Date().timeIntervalSince(startedAt), message: Self.bounded(message)))
    }

    /// The text cut to the message bound.
    private static func bounded(_ text: String) -> String {
        var bounded = String(decoding: text.utf8.prefix(maximumMessageBytes), as: UTF8.self)
        // Decoding a cut sequence adds U+FFFD, whose bytes may straddle the
        // same bound. Drop that final character rather than exceed the cap.
        while bounded.utf8.count > maximumMessageBytes { bounded.removeLast() }
        return bounded
    }

    /// Records one human status, retaining a distinct diagnostic verbatim.
    /// Case and trailing punctuation are ignored only when comparing the
    /// human status with a cause that repeats it; raw diagnostics are not edited.
    func noteTransition(_ status: String, diagnostic: String) {
        func statusKey(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        }
        if diagnostic.isEmpty || statusKey(status) == statusKey(diagnostic) {
            if let previous = entries.last, statusKey(previous.message) == statusKey(status) { return }
            note(status)
        } else {
            let message = "\(status)\nDiagnostic: \(diagnostic)"
            if entries.last?.message != message { note(message) }
        }
    }

    /// Records the daemon's bootstrap answer, excluding its token.
    ///
    /// - Parameters:
    ///   - port: The UDP port the daemon named.
    ///   - certificateSHA256: The pin, of which only a prefix is kept — enough
    ///     to tell one host from another and to spot a pin that changed, and
    ///     not enough to be the pin.
    func note(bootstrapAnswered port: UInt16, certificateSHA256: [UInt8]) {
        let prefix = certificateSHA256.prefix(4).map { String(format: "%02x", $0) }.joined()
        note("The host answered: port \(port), pin \(prefix)… (token withheld)")
    }

    /// The whole log as text, for a reader to copy into a report.
    var transcript: String {
        entries.map(\.line).joined(separator: "\n")
    }
}
