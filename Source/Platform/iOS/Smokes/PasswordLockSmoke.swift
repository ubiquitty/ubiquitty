// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyKit

/// A password prompt puts the lock in the frame on this surface.
///
/// Whether a secret is being taken is Core's decision (private mode 7401, or
/// the password heuristic), and the badge that says so is behaviour. The
/// macOS surface draws it as a view above the frame; the UIKit surface has no
/// such view, so Core's lock stands in the frame on every tier. The check
/// renders the same prompt with the mode set and with it reset: if the two
/// frames are the same picture, the lock was never drawn.
enum PasswordLockSmokeEntry {
    @MainActor
    static func run() -> Bool {
        // The mode alone after a steady cursor: the lock stands beside the
        // cursor, so a blink phase that hides the cursor hides the lock with
        // it, and text that is not a prompt lets the heuristic stand the mode
        // down again.
        let steady = "\u{1b}[2 q"
        guard
            let locked = IOSSurfaceSnapshot.renderPNG(rows: 3, columns: 24, feed: Data((steady + "\u{1b}[?7401h").utf8)),
            let unlocked = IOSSurfaceSnapshot.renderPNG(rows: 3, columns: 24, feed: Data(steady.utf8))
        else {
            SmokeLaunch.report("password-lock: FAIL: the frames did not render")
            return false
        }
        guard locked != unlocked else {
            SmokeLaunch.report("password-lock: FAIL: mode 7401 drew no lock in the frame")
            return false
        }
        SmokeLaunch.report("password-lock: 1/1 checks held")
        return true
    }
}
