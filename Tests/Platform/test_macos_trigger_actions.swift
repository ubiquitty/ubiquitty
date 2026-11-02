// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_macos_trigger_actions.swift — the macOS arm's spawn of a
// `run_command` trigger performs Core's argv as given. The gate, the template
// split and the webhook checks are Core's and are pinned by
// test_trigger_effects and test_trigger_actions; what only this side can lose is
// the no-shell spawn, so it is run here against real programs:
//
//   1. A match laden with shell syntax is one argument to the program: a
//      `touch` given "<dir>/one; touch two", run in <dir>, makes the one file
//      of that whole name, and no "two".
//   2. A program named without a path is found on the search path and still
//      gets the match as one argument, never through a shell.
//   3. An empty argv spawns nothing.
//
// Compiled by plain `xcrun swiftc` with TriggerActions.swift alone. A failure
// prints FAIL file:line, and any failure exits nonzero.
//

import Foundation

var failures = 0

func check(_ condition: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        print("FAIL \(file):\(line): \(what)")
        failures += 1
    }
}

/// Polls until `path` exists, for a spawn that does not report its end.
func waitForFile(_ path: String, seconds: Double = 10) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return FileManager.default.fileExists(atPath: path)
}

@main
struct TriggerActionsTest {
    static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-trigger-actions-\(getpid())").path
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // The spawned program inherits this directory, so a shell that ran the
        // tail of a match would leave its file here.
        check(FileManager.default.changeCurrentDirectoryPath(directory), "premise: could not enter the scratch directory")

        // 1. The match is one argument to a program named by path.
        let hostile = "\(directory)/one; touch two"
        TriggerActions.spawn(["/usr/bin/touch", hostile])
        check(waitForFile(hostile), "the program did not receive the whole match as one argument")
        check(!FileManager.default.fileExists(atPath: "\(directory)/one"), "the match was split at its space")
        check(!FileManager.default.fileExists(atPath: "\(directory)/two"), "the match reached a shell and ran a second command")

        // 2. A bare program name resolves on the search path, still without a shell.
        let substituted = "\(directory)/$(echo three)"
        TriggerActions.spawn(["touch", substituted])
        check(waitForFile(substituted), "a bare program name was not run with the match as one argument")
        check(!FileManager.default.fileExists(atPath: "\(directory)/three"), "a command substitution in the match was evaluated")

        // 3. Nothing to run, nothing run.
        TriggerActions.spawn([])

        if failures == 0 {
            print("test_macos_trigger_actions: a run_command spawn passes Core's argv to the program with no shell between")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
