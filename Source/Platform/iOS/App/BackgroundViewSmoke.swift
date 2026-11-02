// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyKit

/// Whether the app going to the background takes every pane off screen as the
/// host sees it, and coming back shows them again.
///
/// A remote pane that is not shown is `Dormant` on the host (Docs/sync.md
/// §6.8): the host sends it no screen, one `PaneDirty` when it changes, so a phone
/// in a pocket wakes its radio for nothing. The background edge is driven here
/// through the model the app's notifications reach, for a workspace whose
/// panes each report what they told the host.
enum BackgroundViewSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }
        let model = TerminalSessionModel()
        guard let surface = model.surfaceForDrawing() else {
            SmokeLaunch.report("background-view: FAIL: Core declined a surface")
            return false
        }
        check(surface.isRemotePaneShown, "a fresh pane was not shown")

        model.noteApplicationBackgrounded(true)
        check(!surface.isRemotePaneShown, "the app went to the background and its pane stayed shown")

        model.noteApplicationBackgrounded(false)
        check(surface.isRemotePaneShown, "the app came back and its pane stayed hidden")

        for failure in failures {
            SmokeLaunch.report("background-view: FAIL: \(failure)")
        }
        return failures.isEmpty
    }
}
