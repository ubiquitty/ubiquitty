// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SecureInput.swift — macOS Secure Keyboard Entry.
//
// The single place that drives the Carbon HID secure-input functions
// (`EnableSecureEventInput` / `DisableSecureEventInput`) — the only macOS API
// for system-wide Secure Keyboard Entry; AppKit/SwiftUI have no equivalent
// (`SecureField` only protects a focused masked text field, which a terminal
// view is not). The two symbols are forward-declared in SecureInputCarbon.h
// (pulled in through the bridging header) rather than imported via the Carbon
// module, which does not build under -cxx-interoperability-mode=default.
//
// Secure input is a process-wide, *counted* system resource: each enable must
// be balanced by exactly one disable. This type owns that balance — `apply`
// is idempotent and holds the resource at most once, so callers express intent
// ("should it be on right now?") without tracking the held state themselves.
//
// @MainActor enforces single-thread (main) access, so the held-state flag is
// race-free by construction — AppKit lifecycle is main-thread only.
//

import Foundation
import UbiquittyRenderKit

@MainActor
@objc(UBSecureInput)
public final class SecureInput: NSObject {
    // One secure-input state per process, so a single static is the right scope.
    private static var active = false

    // Reconcile the held secure-input state with `wanted`: enable if wanted and
    // not already held, disable if held and no longer wanted, otherwise no-op.
    @objc
    public static func apply(_ wanted: Bool) {
        if wanted && !active {
            EnableSecureEventInput()
            active = true
        } else if !wanted && active {
            DisableSecureEventInput()
            active = false
        } else {
            return
        }
        // The title-bar locks follow the held state, not the wish: a window
        // shows the lock for the resource the process actually holds.
        SecureKeyboardEntryLock.isHeld = active
        NotificationCenter.default.post(name: SecureKeyboardEntryLock.didChangeNotification, object: nil)
    }

    // yes while secure input is currently held (e.g. for a status indicator).
    @objc
    public static func isActive() -> Bool {
        active
    }
}
