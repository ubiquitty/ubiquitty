// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import UbiquittySSH

/// Exercises only typed values and presentation functions; no carrier is instantiated.
@main
struct SSHCloseClassificationTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ reason: String) {
            if !condition {
                failures += 1
                print("FAIL: \(reason)")
            }
        }
        let aborted = NWError.posix(.ECONNABORTED)
        let diagnostic = String(describing: aborted)
        let established = classifySSHClose(.failure, error: aborted, phase: .sessionOpen)
        check(established == .interrupted, "an established POSIX abort is an interruption")
        let summary = SSHFailurePresentation.directShellSummary(established)
        check(summary?.title == String(localized: "SSH Connection Interrupted"), "the title names the established SSH interruption")
        check(
            summary?.message == String(localized: "The SSH connection was interrupted. Reconnecting opens a new shell."),
            "recovery discloses a new shell rather than a resumed session"
        )
        check(summary?.recovery == .newShell, "recovery requires an explicit new-shell action")
        let establishedSentence = SSHFailurePresentation.sentence(
            reason: diagnostic,
            reachFailure: nil,
            classification: established,
            host: "test.invalid",
            port: 22
        )
        check(
            establishedSentence == String(localized: "The SSH connection was interrupted."),
            "status is localizable rather than raw POSIX text"
        )

        let initial = classifySSHClose(.failure, error: aborted, phase: .connecting)
        check(
            initial == .reachFailure(.system(errorCode: POSIXErrorCode.ECONNABORTED.rawValue)),
            "the same abort before TCP opens remains an initial reach failure"
        )
        check(SSHFailurePresentation.directShellSummary(initial) == nil, "an initial failure cannot claim an established shell")
        let initialSentence = SSHFailurePresentation.sentence(
            reason: diagnostic,
            reachFailure: nil,
            classification: initial,
            host: "test.invalid",
            port: 22
        )
        check(
            initialSentence == String(localized: "The SSH connection was interrupted before it opened."),
            "initial failure is distinct without blaming the host"
        )

        let host = "test.invalid"
        let port = "2222"
        let initialCases: [(SSHReachFailure, String)] = [
            (
                .system(errorCode: POSIXErrorCode.ECONNREFUSED.rawValue),
                String(localized: "\(host) refused the connection on port \(port).")
            ),
            (.timedOut, String(localized: "\(host) did not answer on port \(port).")),
            (.system(errorCode: POSIXErrorCode.EHOSTUNREACH.rawValue), String(localized: "\(host) cannot be reached from this network.")),
            (
                .system(errorCode: POSIXErrorCode.ENETUNREACH.rawValue),
                String(localized: "This device has no network that reaches \(host).")
            ),
            (.nameNotResolved, String(localized: "No host named \(host) could be found.")),
            (.system(errorCode: POSIXErrorCode.EINVAL.rawValue), String(localized: "The connection to \(host) on port \(port) failed.")),
        ]
        for (failure, expected) in initialCases {
            let sentence = SSHFailurePresentation.sentence(
                reason: diagnostic,
                reachFailure: failure,
                classification: .reachFailure(failure),
                host: host,
                port: 2222
            )
            check(sentence == expected, "each known initial category has an interpolated localization key")
            check(!sentence.contains(diagnostic) && !sentence.contains("rawValue"), "initial categories never show raw backend diagnostics")
        }
        let legacyReset = SSHFailurePresentation.sentence(
            reason: diagnostic,
            reachFailure: .system(errorCode: POSIXErrorCode.ECONNRESET.rawValue),
            host: host,
            port: 2222
        )
        check(
            legacyReset == String(localized: "\(host) closed the connection on port \(port) before it opened."),
            "the legacy reset sentence is localizable with unchanged wording"
        )

        let login = classifySSHClose(.failure, error: aborted, phase: .transportOpen)
        check(login == .interruptedBeforeSession, "an abort during login is not an established shell interruption")
        check(SSHFailurePresentation.directShellSummary(login) == nil, "an incomplete login offers no shell-resume claim")
        for classification in [login, established] {
            check(
                quicBootstrapCloseDecision(offer: .absent, phase: .sessionOpen, classification: classification) == .unreachable,
                "an interrupted exec without a valid offer cannot decline QUIC"
            )
            check(
                quicBootstrapCloseDecision(offer: .ready, phase: .sessionOpen, classification: classification) == .ready,
                "a complete validated offer survives a later path close"
            )
        }
        check(
            quicBootstrapCloseDecision(offer: .absent, phase: .transportOpen, classification: .normal) == .unreachable,
            "an exec that never opened cannot decline QUIC"
        )
        check(
            quicBootstrapCloseDecision(offer: .absent, phase: .sessionOpen, classification: .normal) == .declined,
            "an authenticated clean exec without an offer retains the genuine decline"
        )

        for phase in [SSHConnectionPhase.connecting, .transportOpen, .sessionOpen] {
            check(classifySSHClose(.cancelled, error: aborted, phase: phase) == .cancelled, "cancellation is not a network interruption")
            check(classifySSHClose(.exited, error: aborted, phase: phase) == .normal, "a remote exit is not a network interruption")
        }
        check(
            quicBootstrapCloseDecision(offer: .ready, phase: .sessionOpen, classification: .cancelled) == .cancelled,
            "local cancellation suppresses even an already parsed offer"
        )
        check(SSHFailurePresentation.directShellSummary(.normal) == nil, "a normal exit has no interruption recovery")
        check(SSHFailurePresentation.directShellSummary(.cancelled) == nil, "cancellation has no interruption recovery")
        for (error, expected) in [
            (SSHCarrierError.authenticationExhausted, SSHCloseClassification.authenticationRefused),
            (.hostKeyUnreadable, .hostKeyUnreadable), (.hostKeyMismatched, .hostKeyMismatched),
        ] {
            for phase in [SSHConnectionPhase.connecting, .transportOpen, .sessionOpen] {
                check(
                    classifySSHClose(.failure, error: error, phase: phase) == expected,
                    "authentication and host-key failures retain their exact cause"
                )
            }
            check(!expected.isTransportInterruption, "a trust refusal is never a path interruption")
            check(SSHFailurePresentation.directShellSummary(expected) == nil, "a trust refusal cannot offer interruption recovery")
            check(
                quicBootstrapCloseDecision(offer: .absent, phase: .sessionOpen, classification: expected) == .unreachable,
                "a trust refusal cannot authorize transport fallback even with a contradictory opened phase"
            )
        }
        for sentence in [initialSentence, establishedSentence, summary?.message ?? ""] {
            check(
                !sentence.contains("POSIXErrorCode") && !sentence.contains("rawValue") && !sentence.contains(diagnostic),
                "raw backend descriptions stay out of presentation"
            )
        }
        check(diagnostic == String(describing: aborted), "formatting leaves the original diagnostic unchanged")
        if failures > 0 {
            print("SSH close classification: FAILED — \(failures) checks")
            exit(1)
        }
        print("SSH close classification: ok")
    }
}
