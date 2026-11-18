// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittySSH

/// What the connection log keeps, and what it must not.
///
/// The first check is the one with teeth. `ConnectionLog` exists to be read by a
/// person debugging a fallback, which means its contents travel — into a
/// screenshot, a bug report, a paste. The bootstrap token is a bearer
/// credential for the session, so a log that carried it would hand the session
/// to whoever read the report, and nothing about the app would look wrong.
///
/// Asserting the token is absent rather than trusting the call site is the
/// point: `note(bootstrapAnswered:certificateSHA256:)` is one edit away from
/// interpolating the whole answer, and that edit would look like an improvement.
enum ConnectionLogSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        var checks = 0

        func check(_ passed: Bool, _ what: String) {
            checks += 1
            if !passed {
                failures.append(what)
            }
        }

        // The token is kept out of the log by SIGNATURE:
        // `note(bootstrapAnswered:certificateSHA256:)` has no token parameter,
        // so no call site can pass one. That is a stronger guarantee than a
        // test, and it is also why asserting "the token is absent" here would
        // be vacuous — the value has no route into this type, so the assertion
        // would hold no matter how the body were rewritten. What can regress is
        // the pin: it is passed in whole and kept in part, so the truncation is
        // a decision the body makes and a decision a body can lose.
        let pin: [UInt8] = [0x2A, 0x8E, 0x49, 0x33, 0x0D, 0x5E, 0xCF, 0x5E]

        let log = ConnectionLog()
        log.begin("connecting to someone@somewhere:22")
        log.note(bootstrapAnswered: 60851, certificateSHA256: pin)

        let transcript = log.transcript

        check(
            transcript.contains("60851"),
            "the port is missing, so the log cannot say which dial it describes"
        )
        check(
            transcript.contains("2a8e4933"),
            "the pin prefix is missing, so a changed pin cannot be spotted"
        )
        // The one with teeth: widening the prefix, or interpolating the pin
        // whole, fails here.
        check(
            !transcript.contains("0d5ecf5e"),
            "the whole pin was kept where a prefix was meant"
        )

        // A fresh attempt replaces the last one rather than appending to it.
        log.begin("connecting again")
        check(
            log.entries.count == 1,
            "begin() did not discard the previous attempt, so the log grows without bound"
        )
        check(
            !log.transcript.contains("60851"),
            "the previous attempt survived begin(), so a reader sees two dials as one"
        )

        // Order is the whole value of a trail: a fallback is only legible if the
        // step before it is above it.
        log.note("asking the host for a QUIC bootstrap over SSH")
        log.note("falling back to SSH: the session refused the QUIC carrier")
        let lines = log.entries.map(\.message)
        check(
            lines.count == 3 && lines[1].contains("asking") && lines[2].contains("falling back"),
            "the steps are not in the order they happened"
        )

        // A pin shorter than the prefix must not trap.
        let short = ConnectionLog()
        short.begin("short pin")
        short.note(bootstrapAnswered: 1, certificateSHA256: [0x01])
        check(
            short.transcript.contains("01"),
            "a pin shorter than the prefix was dropped instead of shortened"
        )

        let bounded = ConnectionLog()
        bounded.begin("first")
        for index in 0..<ConnectionLog.maximumEntries + 10 {
            bounded.note("step \(index)")
        }
        check(bounded.entries.count == ConnectionLog.maximumEntries, "reconnecting grew the log past its entry bound")
        check(bounded.entries.last?.message == "step \(ConnectionLog.maximumEntries + 9)", "the bounded log lost its newest cause")
        bounded.note(String(repeating: "x", count: ConnectionLog.maximumMessageBytes + 100))
        check(bounded.entries.last?.message.utf8.count == ConnectionLog.maximumMessageBytes, "one diagnostic exceeded the message bound")
        bounded.note(String(repeating: "x", count: ConnectionLog.maximumMessageBytes - 1) + "😀")
        check(
            (bounded.entries.last?.message.utf8.count ?? 0) <= ConnectionLog.maximumMessageBytes,
            "a cut UTF-8 sequence exceeded the message bound"
        )

        let raw = "The kept session has no pinned daemon owner for a Sync-over-SSH connection."
        let failed = TerminalConnectionPresentation(
            hasFailed: true,
            hasExited: false,
            isReconnecting: false,
            detail: raw,
            refusal: nil
        )
        check(!failed.cause.isEmpty, "an untyped failure states no cause")
        check(!failed.cause.contains(raw) && !failed.fix.contains(raw), "the floating banner leaked an internal diagnostic")
        check(!failed.fix.contains("Connection Details"), "the banner sends the person elsewhere for the cause")
        check(failed.actions.first == .tryAgain, "a transport failure lost its manual recovery")
        // What Core says when the host no longer holds the session asked for:
        // the banner's cause and fix, and the detail the log keeps.
        let goneNotice = String(Ubiquitty.Session.connectRefusalNotice(.SessionGone))
        let gone = TerminalConnectionPresentation(
            hasFailed: true,
            hasExited: false,
            isReconnecting: false,
            detail: goneNotice,
            refusal: .SessionGone
        )
        check(
            gone.actions.contains(.chooseWorkspace) && gone.actions.contains(.newWorkspace),
            "a missing session is offered no other workspace"
        )
        check(!gone.actions.contains(.tryAgain), "a missing session blindly retries the same identity")
        check(gone.fix.contains("Choose another workspace"), "the notice does not explain its recovery")
        let reconnecting = TerminalConnectionPresentation(
            hasFailed: false,
            hasExited: false,
            isReconnecting: true,
            detail: "Reconnecting over QUIC…",
            refusal: nil
        )
        check(reconnecting.actions == [.retryNow], "a transient reconnect lost Retry Now")
        let version = TerminalConnectionPresentation(
            hasFailed: true,
            hasExited: false,
            isReconnecting: false,
            detail: "Update the host on Studio.",
            refusal: .VersionMismatch
        )
        check(version.cause == "Update the host on Studio.", "a typed version refusal lost the exact update guidance")
        // A refused port: Core's sentence for what happened, Core's remedy for
        // what to do, and the address before another try.
        let refused = SSHFailurePresentation.failure(
            reason: "POSIXErrorCode(rawValue: 61): Connection refused",
            reachFailure: .system(errorCode: 61),
            host: "127.0.0.1",
            port: 1
        )
        check(refused.cause == "127.0.0.1 refused the connection on port 1.", "a refused port lost Core's cause: \(refused.cause)")
        check(!refused.fix.isEmpty && !refused.fix.contains("POSIX"), "a refused port has no fix, or a raw one: \(refused.fix)")
        check(refused.actions == [.editHost, .tryAgain], "a refused port does not offer the host's settings first")
        let mismatched = SSHFailurePresentation.failure(
            reason: "",
            reachFailure: nil,
            classification: .hostKeyMismatched,
            host: "build.example",
            port: 22
        )
        check(mismatched.actions == [.reviewHostKey], "a changed host key offers anything but reviewing it")
        // Steps are said once, in order, and reset with the attempt.
        let steps = ConnectionLog()
        steps.begin("Connecting to ui@127.0.0.1:22")
        steps.step("Reached 127.0.0.1:22", .succeeded)
        steps.step("Reached 127.0.0.1:22", .succeeded)
        steps.step("Signed in as ui", .succeeded)
        steps.step("The host didn’t offer a fast connection", .failed, detail: "No QUIC connection details: End of file")
        check(
            steps.steps.map(\.sentence) == ["Reached 127.0.0.1:22", "Signed in as ui", "The host didn’t offer a fast connection"],
            "the steps are repeated or out of order"
        )
        check(steps.transcript.contains("End of file"), "a step's raw detail did not reach the raw log")
        steps.begin("Connecting again")
        check(steps.steps.isEmpty, "a new attempt kept the last attempt's steps")
        log.note(raw)
        check(log.transcript.contains(raw), "the internal diagnostic was removed from the selectable log")
        let transitions = ConnectionLog()
        transitions.begin("Connecting over QUIC")
        transitions.noteTransition("Connecting over QUIC…", diagnostic: "connecting over QUIC")
        check(transitions.entries.count == 1, "the same QUIC transition was logged twice")
        let diagnostic = "ssh: Owner_ID=AbC.sock was refused"
        transitions.noteTransition("Unable to Connect", diagnostic: diagnostic)
        check(transitions.entries.last?.message.contains(diagnostic) == true, "a raw command or identifier was recased")
        transitions.noteTransition("Unable to Connect", diagnostic: diagnostic)
        check(transitions.entries.count == 2, "an unchanged distinct diagnostic was logged twice")
        transitions.noteTransition("Unable to Connect", diagnostic: "ssh: Owner_ID=abc.sock was refused")
        check(transitions.entries.count == 3, "meaningful diagnostic case differences were discarded")

        // The production model receives Failed, then Idle when detachRemote
        // destroys the rejected carrier. No surface, factory or stream is made.
        let model = TerminalSessionModel()
        var refusal = Ubiquitty.Session.HostRefusal()
        refusal.hasRefusal = true
        refusal.reason = .SessionGone
        model.applyRemoteConnectionPresentation(
            state: .Failed,
            carrier: "QUIC",
            refusal: refusal,
            failureDetail: goneNotice,
            cause: goneNotice,
            linkDetail: ""
        )
        let messageBeforeDetach = model.statusDetail
        model.applyRemoteConnectionPresentation(
            state: .Idle,
            carrier: "",
            refusal: nil,
            failureDetail: "",
            cause: "",
            linkDetail: ""
        )
        let afterDetach = TerminalConnectionPresentation(
            hasFailed: model.hasFailed,
            hasExited: model.hasExited,
            isReconnecting: false,
            detail: model.statusDetail,
            refusal: model.lastHostRefusalReason,
            failure: model.failure
        )
        check(model.hasFailed && !model.isConnected, "detaching the refused carrier erased the failed card")
        check(model.statusDetail == messageBeforeDetach, "the post-detach Idle event overwrote the refusal")
        check(
            afterDetach.actions.first == .newWorkspace && !afterDetach.actions.contains(.tryAgain),
            "a post-detach SessionGone offered blind retry"
        )
        check(model.connectionLog.transcript.contains(goneNotice), "the failed carrier's raw diagnostic was lost")
        model.resetConnectionFailurePresentation()
        model.applyRemoteConnectionPresentation(
            state: .Connecting,
            carrier: "Sync+SSH",
            refusal: nil,
            failureDetail: "",
            cause: "",
            linkDetail: ""
        )
        check(model.lastHostRefusalReason == nil && !model.hasFailed, "a new explicit attempt retained the old refusal")
        check(model.failure == nil, "a new explicit attempt retained the old failure")

        for failure in failures {
            SmokeLaunch.report("connection-log: FAIL: \(failure)")
        }
        SmokeLaunch.report("connection-log: \(checks - failures.count)/\(checks) checks held")
        return failures.isEmpty
    }
}
