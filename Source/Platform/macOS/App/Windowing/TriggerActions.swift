// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TriggerActions.swift — the two trigger acts that reach past the terminal,
// performed as Core resolved them.
//
// Foundation alone, so Tests/Platform/test_macos_trigger_actions.swift runs
// the spawn against real programs without the app module.
//

import Foundation

/// The two trigger acts that reach past the terminal.
///
/// Each takes what Core resolved and performs it without interpreting it: the
/// argv is not joined, the URL is not rebuilt, the body is not re-encoded.
enum TriggerActions {
    /// Spawns a `run_command` argv.
    ///
    /// A program named by path is executed directly; a bare name is resolved
    /// on the search path through `/usr/bin/env`, which executes it with the
    /// remaining argv — still no shell, so no element is ever interpreted. The
    /// child's standard streams go nowhere: it is a notification, and its
    /// output has no window to land in.
    ///
    /// - Parameter arguments: The explicit argv; element 0 is the program.
    static func spawn(_ arguments: [String]) {
        guard let program = arguments.first else { return }
        let process = Process()
        if program.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("run_command trigger failed to launch %@: %@", program, String(describing: error))
        }
    }

    /// POSTs a webhook body.
    ///
    /// Fire-and-forget on an ephemeral session, so no cookie, cache or
    /// credential is kept between posts. The response is not read: a webhook
    /// is a notification, not a request whose answer anyone is waiting on.
    ///
    /// - Parameters:
    ///   - body: The JSON body, as Core built it.
    ///   - address: The http(s) URL, as Core checked it.
    static func post(_ body: String, to address: String) {
        guard let url = URL(string: address) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { _, _, error in
            if let error {
                NSLog("webhook trigger POST to %@ failed: %@", address, String(describing: error))
            }
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }
}
