// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittyKit

/// What the session model does with a lesson: holds the latest words, and
/// nothing else.
///
/// The lifetime is Core's and the surface's re-ask carries it, so the only
/// thing this shell can get wrong is the wire -- a change that does not land,
/// or an empty answer that leaves stale words on screen. Both are checked.
enum HintSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            SmokeLaunch.report("hint: FAIL: no surface to raise a lesson on")
            return false
        }
        let model = TerminalSessionModel()
        check(model.hint.isEmpty, "a fresh model already had a lesson to show")
        model.terminalSurface(surface, didChangeHint: "lesson")
        check(model.hint == "lesson", "the words did not reach the model (hint: '\(model.hint)')")
        model.terminalSurface(surface, didChangeHint: "another")
        check(model.hint == "another", "a replacement did not land (hint: '\(model.hint)')")
        model.terminalSurface(surface, didChangeHint: "")
        check(model.hint.isEmpty, "an empty answer left stale words (hint: '\(model.hint)')")

        for failure in failures {
            SmokeLaunch.report("hint: FAIL: \(failure)")
        }
        SmokeLaunch.report("hint: \(4 - failures.count)/4 checks held")
        return failures.isEmpty
    }
}
