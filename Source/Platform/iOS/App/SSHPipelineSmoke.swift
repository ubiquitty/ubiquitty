// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittySSH

/// The SSH pipeline keeps its order, and reports a setup failure.
///
/// Guarding what the compiler cannot see. The pipeline is built through
/// `syncOperations` to satisfy Swift 6's concurrency checking, and its order is
/// invisible in every way a build can tell you about: any spelling of it
/// compiles, connects, and looks right in a diff. What can silently differ is
/// the order the handlers end up in, and whether a refusal during setup
/// reaches the caller at all.
///
/// Order matters because NIOSSHHandler is what turns transport bytes into SSH
/// events. Behind it, the error handler sees what the SSH layer could not
/// handle; in front of it, the same handler sees raw bytes and stops reporting
/// the failures it exists to report. A carrier that misses errors reads as a
/// flaky network, so the wrong order costs a debugging session somewhere else
/// entirely.
enum SSHPipelineSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }

        let names = SSHPipelineProbe.handlerNamesForTesting()

        check(names != nil, "the pipeline refused the handlers the connection path installs")
        check(
            names == ["NIOSSHHandler", "SSHConnectionErrorHandler"],
            "the handlers are not in the order the carrier needs — got \(names.map(String.init(describing:)) ?? "nothing")"
        )

        // A pipeline that cannot take handlers must FAIL rather than resolve.
        // makeCompletedFuture turns a throw into a failed future, and a caller
        // that never saw the failure would leave the session on "Connecting…"
        // instead of reporting anything.
        check(
            SSHPipelineProbe.setupFailureIsReportedForTesting(),
            "a pipeline that refused its handlers reported success, so a failed setup would hang"
        )

        for failure in failures {
            SmokeLaunch.report("ssh-pipeline: FAIL: \(failure)")
        }
        SmokeLaunch.report("ssh-pipeline: \(3 - failures.count)/3 checks held")
        return failures.isEmpty
    }
}
