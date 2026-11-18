// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import UbiquittySSH

/// The SSH carrier dials through Network.framework, and still says why a
/// connect failed.
///
/// A phone's first dial after it wakes often meets a path that is not up yet:
/// an on-demand VPN that only Network.framework triggers, or a radio still
/// coming up. A BSD-socket connect never waits for either, so it failed once and
/// connected on the next tap. Network.framework waits for the path, which
/// changes the errors a failed connect carries: they arrive as `NWError`, and a
/// carrier that could not read them would report every refusal as an untyped
/// failure rather than Core's sentence.
///
/// - The connect budget outlasts a VPN or radio that takes a few seconds to
///   come up, and stays under the bootstrap's own 30-second deadline, so the
///   typed error is what reaches the person rather than the deadline's.
/// - A refusal and a name that does not resolve are read from `NWError`.
/// - A connect that ran out of time still reads as one.
enum SSHConnectSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }

        let budget = SSHConnectProbe.connectTimeoutSecondsForTesting
        check(budget >= 20 && budget < 30, "the connect budget is \(budget) s, outside 20..<30")
        check(SSHConnectProbe.outboundBudgetIsBoundedForTesting(), "the native SSH outbound queue did not retain its byte and write bounds")

        let refused = SSHCarrier.reachFailure(of: NWError.posix(.ECONNREFUSED))
        check(
            refused == .system(errorCode: POSIXErrorCode.ECONNREFUSED.rawValue),
            "a refusal from Network.framework read as \(String(describing: refused))"
        )
        let unreachable = SSHCarrier.reachFailure(of: NWError.posix(.EHOSTUNREACH))
        check(
            unreachable == .system(errorCode: POSIXErrorCode.EHOSTUNREACH.rawValue),
            "an unreachable host from Network.framework read as \(String(describing: unreachable))"
        )
        // kDNSServiceErr_NoSuchRecord.
        let unresolved = SSHCarrier.reachFailure(of: NWError.dns(-65554))
        check(unresolved == .nameNotResolved, "a failed lookup read as \(String(describing: unresolved))")

        let elapsed = SSHConnectProbe.reachFailureOfAnElapsedConnectForTesting()
        check(elapsed == .timedOut, "a connect that ran out of time read as \(String(describing: elapsed))")

        // A session that ends without the remote's exit status ended because
        // the link did, and reading that as a clean close told the person the
        // shell exited while it was still running on the host.
        let lost = SSHConnectProbe.closeIsFailureForTesting(afterExitStatus: false)
        check(lost == true, "a session gone without an exit status did not close as a failure: \(String(describing: lost))")
        let exited = SSHConnectProbe.closeIsFailureForTesting(afterExitStatus: true)
        check(exited == false, "a session that reported its exit closed as failure: \(String(describing: exited))")

        // An exec's output, exit status and close in one segment reach the
        // session handler exit status first. Closing on the exit status ended
        // a QUIC bootstrap before its one line arrived, and the session read
        // "no quic_port line" from a daemon that had printed it.
        let overtaken = SSHConnectProbe.reportsWhenExitStatusOvertakesOutputForTesting()
        check(
            overtaken == ["output:quic_port=1\n", "close:clean"],
            "an exit status ahead of its output closed the session first: \(String(describing: overtaken))"
        )

        // An idle link that died while the app was away answers nothing, and
        // a session with no probe of its own finds out only when a keystroke
        // times out minutes later.
        let keepalive = SSHConnectProbe.keepaliveForTesting
        check(
            keepalive.isEnabled && keepalive.idleSeconds > 0 && keepalive.idleSeconds <= 30,
            "an idle link is probed \(keepalive.isEnabled ? "after \(keepalive.idleSeconds) s" : "never")"
        )

        for failure in failures {
            SmokeLaunch.report("ssh-connect: FAIL: \(failure)")
        }
        SmokeLaunch.report("ssh-connect: \(10 - failures.count)/10 checks held")
        return failures.isEmpty
    }
}
