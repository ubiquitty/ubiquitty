// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Saved hosts retain their selected sign-in method and workspace preference.
/// Unknown methods are refused rather than interpreted as another credential.
enum HostRecordSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ passed: Bool, _ what: String) {
            if !passed { failures.append(what) }
        }

        func kind(_ json: String) -> HostAuthenticationKind? {
            try? JSONDecoder().decode(HostRecord.self, from: Data(json.utf8)).authenticationKind
        }

        for method in HostAuthenticationKind.allCases {
            let record = HostRecord(authenticationKind: method, prefersQUIC: false)
            let written = try? JSONEncoder().encode(record)
            let read = written.flatMap { try? JSONDecoder().decode(HostRecord.self, from: $0) }
            check(read?.authenticationKind == method, "saved sign-in method changed")
            check(read?.savedCredential == method.savedCredential, "saved credential changed")
            check(record.canSavePromptedPassword == (method != .privateKey), "password saving could replace a key")
            check(read?.prefersQUIC == false, "saved workspace preference changed")
        }
        check(kind(#"{"authenticationKind":"unknown"}"#) == nil, "an unknown method was accepted")
        check(kind(#"{"authenticationKind":"automatic"}"#) == nil, "an obsolete method was reinterpreted")
        check(HostRecord().prefersQUIC, "a new host starts without workspaces")

        for failure in failures {
            SmokeLaunch.report("host-record: FAIL: \(failure)")
        }
        SmokeLaunch.report("host-record: \(failures.isEmpty ? "ok" : "\(failures.count) failure(s)")")
        return failures.isEmpty
    }
}
