// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit

/// Whether a remote pane's cursor blinks on its own, with nothing arriving.
///
/// A thin client's terminal is passive: the host's keyframes write it, and the
/// only thing that moves the cursor's phase between them is the frame clock.
/// So the blink is a frame the surface has to schedule for itself — a timer
/// to the next phase step, a display-link pass, a capture handed the new
/// weight — and every stage of that has to answer for a pane with no local
/// process behind it.
///
/// The host's state is the one an ordinary shell leaves: xterm's `cnorm`
/// (`CSI ? 12 l CSI ? 25 h`, which vim, less and every curses program send on
/// the way out) clears the att610 blink mode, and the keyframe carries that
/// mode to the client verbatim. It is written into the passive terminal here
/// rather than delivered over a carrier, which reaches the same field the
/// keyframe's apply writes.
///
/// The clock is pinned through `UBIQUITTY_FAKE_TICKS` and walked forward with
/// the wall clock, so the activity hold and the phase are the ones the
/// production clock would give while staying anchored at tick zero.
enum CursorBlinkSmokeEntry {
    /// How long the walk runs, in seconds: the activity hold and more than a
    /// blink period after it.
    private static let walkInSeconds = 2.0

    /// When the walk starts counting frames, in seconds: past the hold and the
    /// frames the attach and the window's arrival owe, so every frame counted
    /// after it was asked for by the blink alone.
    private static let blinkOnlyFromSeconds = 1.0

    @MainActor
    static func run() -> Bool {
        // The host as a fresh terminal leaves it, then as a shell that sent
        // `cnorm` leaves it: the first isolates the frame path, the second the
        // blink mode's standing against the reader's preference.
        let fresh = blinks(afterHostWrote: "", named: "a fresh host")
        let afterCnorm = blinks(afterHostWrote: "\u{1b}[?12l\u{1b}[?25h", named: "a host after cnorm")
        return fresh && afterCnorm
    }

    /// Runs one pane through the walk.
    ///
    /// - Parameters:
    ///   - hostBytes: What the host's terminal was last written, as its
    ///     keyframe carries it.
    ///   - name: The leg, for the failure line.
    /// - Returns: Whether the pane blinked.
    @MainActor
    private static func blinks(afterHostWrote hostBytes: String, named name: String) -> Bool {
        func failed(_ reason: String) -> Bool {
            CursorBlinkSmokeEntry.failed("\(name): \(reason)")
        }
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)
        defer { unsetenv("UBIQUITTY_FAKE_TICKS") }
        let model = TerminalSessionModel()
        guard let surface = model.makePaneSurface() else {
            return failed("Core declined a surface")
        }
        let carrier = HeldCarrier()
        guard let factory = carrier.makeFactory() else {
            return failed("no carrier factory")
        }
        guard surface.attachRemoteOverCarrier(carrierFactory: ubiquittyIOSQUICFactoryAddress(factory)),
            surface.drive.isRemoteAttached
        else {
            return failed("the surface did not become a thin client")
        }
        _ = surface.drive.withTerminal { terminal in
            hostBytes.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
        }
        guard let window = SmokeLaunch.present(surface) else {
            return failed("no window to present in")
        }
        defer { window.isHidden = true }
        surface.setSurfaceFocused(true)
        guard surface.drive.withTerminal({ $0.windowFocused }) == true else {
            return failed("a focused remote pane left its terminal unfocused")
        }

        // Font preparation and the first drawable can block the main thread.
        // The blink walk measures scheduling only after that frame is ready.
        let initialFrame = surface.drawnFrameCount
        surface.setNeedsDisplay()
        let readinessDeadline = Date().addingTimeInterval(8)
        while surface.drawnFrameCount == initialFrame, Date() < readinessDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 120.0))
        }
        guard surface.drawnFrameCount > initialFrame else {
            return failed("the initial frame did not become ready")
        }

        let start = Date()
        let framesBefore = surface.drawnFrameCount
        let withheldBefore = surface.withheldForSyncOutputCount
        var alphas = Set<Float>()
        var wasClockArmed = false
        var lastFrame = framesBefore
        var blinkOnlyFrames = 0
        while Date().timeIntervalSince(start) < walkInSeconds {
            let ticks = UInt32(Date().timeIntervalSince(start) * 60)
            setenv("UBIQUITTY_FAKE_TICKS", String(ticks), 1)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 120.0))
            wasClockArmed = wasClockArmed || surface.isAnimationClockArmed
            if surface.drawnFrameCount != lastFrame {
                lastFrame = surface.drawnFrameCount
                if Date().timeIntervalSince(start) >= blinkOnlyFromSeconds {
                    blinkOnlyFrames += 1
                }
                alphas.insert(surface.lastFrameCursorMixAlpha)
            }
        }
        let frames = surface.drawnFrameCount - framesBefore
        let facts =
            "frames \(frames), blink-only \(blinkOnlyFrames), weights \(alphas.sorted()), clock armed \(wasClockArmed), "
            + "withheld \(surface.withheldForSyncOutputCount - withheldBefore), "
            + "held \(surface.drive.isFrameHeld), "
            + "animating \(surface.drive.nextAnimationDelay().hasAnimatingContent)"
        var reasons: [String] = []
        if !wasClockArmed {
            reasons.append("the blinking cursor armed no animation clock")
        }
        if blinkOnlyFrames < 2 {
            reasons.append("no frames were scheduled for the blink alone")
        }
        if surface.withheldForSyncOutputCount != withheldBefore {
            reasons.append("a blink-only frame was withheld")
        }
        if alphas.count < 2 || !alphas.contains(where: { $0 < 0.5 }) {
            reasons.append("the cursor weight never moved between frames")
        }
        for reason in reasons {
            _ = failed("\(reason) (\(facts))")
        }
        return reasons.isEmpty
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("cursor-blink: FAIL: \(reason)")
        return false
    }
}

/// A carrier provider that never completes a connection.
///
/// The session stays a thin client mid-connect for the whole smoke: remote in
/// every respect the surface reads, with no host to answer it. A request still
/// held when the factory is released is completed as a failure, which is the
/// provider's contract.
@MainActor
final class HeldCarrier {
    private var requests: [OpaquePointer] = []

    func makeFactory() -> OpaquePointer? {
        let context = Unmanaged.passRetained(self).toOpaque()
        let hooks = UbiquittyIOSQUICProvider(
            context: context,
            request: { context, request in
                guard let context, let request else { return }
                MainActor.assumeIsolated {
                    Unmanaged<HeldCarrier>.fromOpaque(context).takeUnretainedValue().requests.append(request)
                }
            },
            release: { context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let carrier = Unmanaged<HeldCarrier>.fromOpaque(context).takeRetainedValue()
                    for request in carrier.requests {
                        ubiquittyIOSQUICRequestComplete(request, 0, nil, 0, nil, 0, nil)
                    }
                    carrier.requests.removeAll()
                }
            }
        )
        let factory = "held.invalid".withCString { ubiquittyIOSQUICFactoryCreate($0, hooks) }
        if factory == nil {
            Unmanaged<HeldCarrier>.fromOpaque(context).release()
        }
        return factory
    }
}
