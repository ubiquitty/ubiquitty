// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyKit

/// Whether a session stays on screen while one of its screens replaces another.
///
/// A window that changes width class — an iPhone that unfolds, a large iPhone
/// turned sideways — can put a new terminal screen up before it takes the old
/// one down. Visibility read from whichever screen spoke last then says nothing
/// is on screen while a terminal is, and a bell rung at a person looking at it
/// is kept as unheard. The order is driven here directly: two appearances, one
/// disappearance, and the session must still be on screen.
enum ScreenVisibilitySmokeEntry {
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
            SmokeLaunch.report("screen-visibility: FAIL: Core declined a surface")
            return false
        }
        check(!model.isScreenVisible, "a fresh session was already on screen")

        model.screenDidAppear()
        model.screenDidAppear()
        model.screenDidDisappear()
        check(model.isScreenVisible, "the old screen leaving after the new one arrived took the session off screen")

        // The bell is judged only with the app in front: a bell in the
        // background is unheard whatever is on screen, and says nothing here.
        if UIApplication.shared.applicationState == .active {
            ringTheBell(on: surface)
            check(!model.hasUnheardBell, "a bell rung at an on-screen session was kept as unheard")
        }

        model.screenDidDisappear()
        check(!model.isScreenVisible, "the session stayed on screen after its last screen left")
        ringTheBell(on: surface)
        check(model.hasUnheardBell, "a bell rung with no screen up was not kept as unheard")

        for failure in failures {
            SmokeLaunch.report("screen-visibility: FAIL: \(failure)")
        }
        return failures.isEmpty
    }

    /// Rings the bell through the terminal and waits for it to reach the model.
    @MainActor
    private static func ringTheBell(on surface: TerminalSurface) {
        surface.feed(Data("\u{7}".utf8))
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            surface.serviceIngestEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
