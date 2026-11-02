// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// This half of the surface is AppKit's. The events it answers — mouse
// buttons, a scroll wheel with momentum, NSEvent modifier flags, the
// AppKit text-input client — have no counterpart on a touch screen, so the
// UIKit shell answers its own and neither carries the other's model.
//
// Guarded rather than moved: it extends the shared surface, and keeping it
// beside what it extends is what stops the two halves drifting apart.

#if canImport(AppKit)

// TerminalSurface+PointerLock.swift — relative pointer-lock ("mouselook",
// private mode 7403). One idempotent apply owns the OS grab, so hide and
// dissociate stay balanced against unhide, reassociate and warp-back — the
// NSCursor hide counter can never leak and the cursor can never be stranded
// system-wide. Dissociation freezes the device: motion arrives as pure
// hardware deltas with no screen-edge clamp and nothing to recentre.
//
// The break-out chord (hold the control-command pair) is the
// app-independent release, evaluated natively above the key resolver and
// the host so no rebind, mode, or escape stream can shadow it; its arming
// and hold thresholds are Core's (`Input::isPointerLockBreakoutArmed`,
// `pointerLockShouldBreakOut`), and the mode clear is the session's, so a
// hung application that never resets 7403 cannot re-trap the pointer.

import AppKit
import QuartzCore
internal import UbiquittyCore

extension TerminalSurface: PointerLockHolder {
    /// Releases the grab if this surface holds one; see ``PointerLockHolder``.
    public func releasePointerLockGrab() {
        applyPointerLock(false)
    }

    /// Re-asks whether this surface should hold the grab; see
    /// ``PointerLockHolder``.
    public func reconcilePointerLockGrab() {
        updatePointerLock()
    }
    /// Whether this surface should hold the OS cursor grab: the published
    /// 7403 bit, and this surface being the active app's key window's first
    /// responder — a backgrounded lock would trap a pointer no window owns.
    ///
    /// The published bit leads, and while nothing is locked it is the whole
    /// cost: the reconcile runs on every drain delivery, and the AppKit
    /// reads behind it are three message sends the common case must not
    /// pay. With a lock held the AppKit half runs regardless — that is the
    /// half that releases a grab the focus left behind.
    internal var isPointerLockDesired: Bool {
        guard drive.readSnapshot().mouseRelativePointerLockActive || isPointerLocked else {
            return false
        }
        // The one fact Core cannot see: whether this surface is the live input
        // target. The decision is Core's.
        let isFocused = NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
        return drive.pointerLockVerdict(isSurfaceFocused: isFocused) == .hold
    }

    /// Reconciles the OS grab against ``isPointerLockDesired``. Idempotent
    /// and cheap; called from every state change that can move the answer —
    /// a mode drain, a focus edge, a window-key edge, app activation.
    internal func updatePointerLock() {
        applyPointerLock(isPointerLockDesired)
    }

    /// The one enable/teardown, guarded by the single source of truth.
    ///
    /// - Parameter locked: Whether the grab should hold.
    internal func applyPointerLock(_ locked: Bool) {
        guard locked != isPointerLocked else {
            return
        }
        isPointerLocked = locked
        if locked {
            // Capture where the cursor is, hide it, dissociate, then warp
            // once to the view centre so the hidden cursor rests somewhere
            // sane. Dissociation and the hide counter are process-scoped, so
            // a crash auto-restores the cursor — the last resort, never a
            // substitute for the clean teardown below.
            let mouseBottomLeft = NSEvent.mouseLocation
            let primaryTop = NSScreen.screens.first?.frame.size.height ?? 0
            pointerLockRestorePoint = CGPoint(x: mouseBottomLeft.x, y: primaryTop - mouseBottomLeft.y)
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
            warpCursorToViewCenter()
            window?.invalidateCursorRects(for: self)
            reportPointerLockGrab(.held)
        } else {
            // Teardown in the safe order: disarm the chord, reassociate
            // first so the warp lands, warp back to where the lock began,
            // then unhide.
            disarmPointerLockChord()
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(pointerLockRestorePoint)
            NSCursor.unhide()
            window?.invalidateCursorRects(for: self)
            reportPointerLockGrab(.released)
        }
    }

    /// Reports the grab to Core and asks what that changed.
    ///
    /// The grab is an OS fact only this arm sees; everything after the report
    /// -- that the way out is owed for as long as the trap lasts, and for
    /// how many traps -- is the ladder's. Apart from `applyPointerLock` so a
    /// smoke can exercise the report without taking the lock, which would
    /// hide and dissociate the real cursor of whoever is running it.
    ///
    /// - Parameter grab: Whether the grab is held.
    package func reportPointerLockGrab(_ grab: Ubiquitty.Input.PointerLockGrab) {
        drive.notePointerLockGrab(grab)
        refreshHint()
    }

    /// Warps the hidden, dissociated cursor to the view centre, in CG-global
    /// top-left coordinates.
    private func warpCursorToViewCenter() {
        guard let window else {
            return
        }
        let inWindow = convert(bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let primaryTop = NSScreen.screens.first?.frame.size.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.midX, y: primaryTop - onScreen.midY))
    }

    /// Reports a modifier change to Core's chord and books its one wake-up.
    ///
    /// The arming rule, the hold and the abort on a release in the last
    /// instant are the ladder's; this arm reports what the keys are, asks
    /// when to ask again, and executes the release it is told to.
    ///
    /// - Parameter event: The flags-changed event.
    internal func updatePointerLockChord(_ event: NSEvent) {
        drive.notePointerLockChord(chordKeyState(event.modifierFlags))
        bookPointerLockChordTick()
    }

    /// Reports that a non-modifier key joined the chord, which makes it a
    /// shortcut rather than the break-out.
    internal func disarmPointerLockChord() {
        var keys = chordKeyState(NSEvent.modifierFlags)
        keys.isAnyNonModifierKeyHeld = true
        drive.notePointerLockChord(keys)
    }

    /// Books the one wake-up Core names for the chord, if it is armed.
    private func bookPointerLockChordTick() {
        let ticks = drive.pointerLockChordTicksUntilDeadline()
        guard ticks != 0, pointerLockChordTimer == nil else { return }
        // One tick past the deadline, so the ask lands on its far side. The
        // timer fires on the run loop that schedules it, and the only
        // scheduler is this method, reached from AppKit flags-changed handling
        // on the main thread; the assertion states that guard at runtime.
        pointerLockChordTimer = Timer.scheduledTimer(withTimeInterval: Double(ticks + 1) / 60.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.firePointerLockChordTick()
            }
        }
    }

    /// The wake-up fired: ask Core against the live modifier flags, and release
    /// the grab if it says so. The mode is already clear by then.
    private func firePointerLockChordTick() {
        pointerLockChordTimer = nil
        if drive.tickPointerLockChord(chordKeyState(NSEvent.modifierFlags)) == .breakOut {
            applyPointerLock(false)
        } else {
            bookPointerLockChordTick()
        }
    }

    private func chordKeyState(_ flags: NSEvent.ModifierFlags) -> Ubiquitty.Input.PointerLockKeyState {
        var keys = Ubiquitty.Input.PointerLockKeyState()
        keys.isControlHeld = flags.contains(.control)
        keys.isCommandHeld = flags.contains(.command)
        keys.isShiftHeld = flags.contains(.shift)
        keys.isOptionHeld = flags.contains(.option)
        keys.isAnyNonModifierKeyHeld = false
        return keys
    }
}

#endif
