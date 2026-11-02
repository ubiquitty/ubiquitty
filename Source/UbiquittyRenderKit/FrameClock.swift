// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FrameClock.swift — the pane's frame pacing, owned in Swift: the animation
// timer's lifecycle and the pause/resume/rate decisions. Every fact that
// requires the Terminal, the bridge, the FrameDriver's atomics or an AppKit
// property crosses the delegate as a scalar; the clock holds only what
// schedules. FrameDriver itself stays a view ivar — its std::atomic members
// do not import, and it is Core policy shared with the Linux frame clock, so
// the seam reaches it through two delegate calls rather than a Swift copy.

import QuartzCore
import UbiquittyCore

/// The facts and actions the frame clock exchanges with the view it paces.
///
/// Queries return scalars; actions are imperatives the view applies to its
/// own AppKit and C++ state. Every method is called on the main thread — the
/// timer is scheduled on the view's run loop, and the pause/resume entry
/// points are main-thread AppKit paths.
@objc(UBFrameClockDelegate)
public protocol FrameClockDelegate: AnyObject {
    /// Reports whether a live Terminal is attached.
    func frameClockHasLiveTerm(_ clock: FrameClock) -> Bool
    /// Re-services coalesced ingest events; rides the tick's cadence so a
    /// signal lost in a teardown-adjacent race still lands.
    func frameClockServiceIngestBelt(_ clock: FrameClock)
    /// The 60 Hz monotonic tick count.
    func frameClockMonotonicTicks(_ clock: FrameClock) -> UInt32
    /// Runs the hilite-await deadline check.
    func frameClock(_ clock: FrameClock, checkHiliteDeadlineAt nowTicks: UInt32)
    /// Repaints if a blink phase, bell fade or cursor ramp crossed since the
    /// last painted tick.
    func frameClock(_ clock: FrameClock, updateRepaintIfCrossedAt nowTicks: UInt32)
    /// Advances animated images by real elapsed time, under the model lock.
    func frameClockAdvanceImagesIfDue(_ clock: FrameClock)
    /// Resets the image-advance clock so a fresh animation seeds cleanly.
    func frameClockResetImageClock(_ clock: FrameClock)
    /// Reports whether anything on screen still animates.
    func frameClockHasAnimatingContent(_ clock: FrameClock) -> Bool
    /// Derives the next tick delay from one coherent snapshot.
    ///
    /// The view reads its runtime snapshot once and feeds Core's animation
    /// schedule from that single read — the cross-field consistency the
    /// original tick had is this method's contract, not the caller's problem.
    func frameClock(_ clock: FrameClock, nextAnimationDelayAt nowTicks: UInt32) -> Double

    /// Reports whether the view is in a window; detached link drive is
    /// unrecoverable, so the clock stays on-demand without one.
    func frameClockHasWindow(_ clock: FrameClock) -> Bool
    /// Stamps the perf log's resume marker.
    func frameClockNotePerfResume(_ clock: FrameClock)
    /// The current display's maximum refresh rate, floored to 60.
    func frameClockMaxScreenFramesPerSecond(_ clock: FrameClock) -> Int32
    /// Reports full-rate presentation: selected tab, not miniaturized.
    func frameClockIsPresented(_ clock: FrameClock) -> Bool
    /// Reports the MTKView paused flag.
    func frameClockIsPaused(_ clock: FrameClock) -> Bool
    /// Applies the display link's frame-rate request.
    func frameClock(_ clock: FrameClock, setPreferredFramesPerSecond fps: Int32)
    /// Retunes the ingest-side sync-publish throttle to the live rate.
    func frameClock(_ clock: FrameClock, setSyncPublishRefreshSeconds seconds: Double)
    /// Feeds the adaptive frame driver the presented panel's frame interval
    /// (1/rate). A no-op unless adaptive drive is on.
    func frameClock(_ clock: FrameClock, setDriverFrameIntervalSeconds seconds: Double)
    /// Re-asserts the vsync choice on the metal layer.
    func frameClockApplyVSyncToLayer(_ clock: FrameClock)
    /// Flips MTKView's on-demand drawing mode.
    func frameClock(_ clock: FrameClock, setEnableSetNeedsDisplay enable: Bool)
    /// Flips the MTKView display link.
    func frameClock(_ clock: FrameClock, setPaused paused: Bool)
    /// Requests one on-demand repaint.
    func frameClockSetNeedsDisplayNow(_ clock: FrameClock)
    /// Commits an in-progress Tek frame on ingest-idle, under the model lock.
    func frameClockCommitTekFrameIfIdle(_ clock: FrameClock)
    /// Publishes the FrameDriver mode; the driver's seq_cst atomics stay on
    /// the view, and ordering against the paused flips is the clock's job.
    func frameClock(_ clock: FrameClock, setDriverContinuous continuous: Bool)
    /// Reports whether host output has been idle past the driver's timeout.
    func frameClockDriverIdleExpired(_ clock: FrameClock) -> Bool
}

/// Owns the pane's frame pacing: the low-rate animation timer and the
/// continuous-versus-on-demand link decisions.
///
/// The clock is the schedule; the view remains the mechanism. An armed timer
/// retains the clock (the timer retains its target), and two explicit stops —
/// pane detach and view dealloc — break the cycle.
@objc(UBFrameClock)
public final class FrameClock: NSObject {
    private weak var delegate: FrameClockDelegate?
    private var animTimer: Timer?
    /// The ceiling a host pushed, zero when none did.
    private var maxFPS: Int32 = 0

    /// The user's frame-rate ceiling: a host's pushed cap, else `[render] max_fps`
    /// read here.
    ///
    /// A host that pushes one still decides, so a caller can cap a single clock
    /// below the preference. Absent a push the preference is read rather than
    /// assumed uncapped: the ladder is Core's and so is the preference, and a
    /// frontend that never pushes would otherwise leave a documented setting with
    /// no effect at all on its arm.
    private var userFrameCap: Int32 {
        maxFPS != 0
            ? maxFPS
            : Int32(Ubiquitty.Preferences.Effective.maxFPS(Ubiquitty.Preferences.values().pointee))
    }
    /// One fire per blink step at most; fires re-space themselves to the
    /// next crossing, so this is the floor between fires, not a rate.
    private static let tickInterval: TimeInterval = 1.0 / 60.0

    /// Builds the clock around its view.
    ///
    /// Performs no delegate calls: the view constructs the clock before its
    /// bridge exists, and the first callback happens on the first tick or
    /// resume, never here.
    ///
    /// - Parameter delegate: The view the clock paces.
    @objc
    public init(delegate: FrameClockDelegate) {
        self.delegate = delegate
    }

    deinit {
        animTimer?.invalidate()
    }

    /// Re-arms or leaves the animation tick based on the current animating
    /// state; a non-animating fire stops itself.
    ///
    /// Cheap and idempotent, called on any event that could start an
    /// animation. A running timer is never killed here — the next fire sees
    /// "nothing animating" and stops, keeping this path allocation-free on
    /// the common still-animating call.
    @objc
    public func noteAnimationActivity() {
        guard let delegate, delegate.frameClockHasAnimatingContent(self) else { return }
        // The crossing schedule owns the delay: arming at a flat tick fired
        // the first tick early whatever the real crossing distance, and every
        // ingest event dragged an armed schedule forward to it — a fire per
        // event during output where the content's cadence wanted a fraction
        // of that. The tick interval survives as the floor between fires.
        let delay = max(
            Self.tickInterval,
            delegate.frameClock(self, nextAnimationDelayAt: delegate.frameClockMonotonicTicks(self))
        )
        if let animTimer {
            if animTimer.fireDate.timeIntervalSinceNow > delay {
                animTimer.fireDate = Date(timeIntervalSinceNow: delay)
            }
            return
        }
        // The timer retains its target on purpose: an armed timer pins the
        // clock the way a target:self timer pins its owner; stop()
        // breaks the cycle at the same explicit teardown points.
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(fireTimer(_:)), userInfo: nil, repeats: true)
        animTimer = timer
        // Common modes so blink keeps ticking during window drags and menu
        // tracking.
        RunLoop.current.add(timer, forMode: .common)
    }

    /// Whether the animation tick is armed.
    ///
    /// The tick stops itself one fire after the content goes static, so a
    /// true here can lag the content by one crossing; it can never read
    /// false while a fire is scheduled.
    @objc
    public var isTicking: Bool { animTimer != nil }

    /// Stops the animation tick.
    @objc
    public func stop() {
        animTimer?.invalidate()
        animTimer = nil
    }

    /// Switches to continuous link drive at the derived rate, or to on-demand
    /// drive for a pane nobody can see.
    ///
    /// A detached view has no display link, so the clock stays on-demand and
    /// leaves the driver idle; the next drain re-takes the edge against a
    /// window. Publish order matters: the driver goes active before the link
    /// unpauses, so an edge test never observes paused-but-idle.
    @objc
    public func resume() {
        guard let delegate else { return }
        guard delegate.frameClockHasWindow(self) else {
            delegate.frameClock(self, setPaused: true)
            delegate.frameClock(self, setEnableSetNeedsDisplay: true)
            delegate.frameClockSetNeedsDisplayNow(self)
            return
        }
        // Core's rate ladder: the screen's maximum, the user's cap, and no
        // link at all for a pane nobody can see — one rule for every clock.
        let rate = Ubiquitty.Rendering.presentationFramesPerSecond(
            delegate.frameClockMaxScreenFramesPerSecond(self),
            userFrameCap,
            delegate.frameClockIsPresented(self) ? .presented : .background
        )
        guard rate > 0 else {
            // Hidden: on-demand drive, in maybePause's order — paused first,
            // then the driver clears — so an edge test never observes a link
            // running under an idle driver, and the next drain after the
            // reveal re-takes the edge. The session keeps publishing at the
            // reduced cadence, so the frame the reveal repaints from is
            // current; the reveal itself asks for that repaint.
            delegate.frameClock(self, setPaused: true)
            delegate.frameClock(self, setDriverContinuous: false)
            delegate.frameClock(self, setEnableSetNeedsDisplay: true)
            delegate.frameClock(
                self,
                setSyncPublishRefreshSeconds: 1.0 / Double(Ubiquitty.Rendering.backgroundSyncPublishFramesPerSecond)
            )
            return
        }
        delegate.frameClockNotePerfResume(self)
        delegate.frameClock(self, setDriverContinuous: true)
        delegate.frameClock(self, setPreferredFramesPerSecond: rate)
        delegate.frameClock(self, setSyncPublishRefreshSeconds: 1.0 / Double(rate))
        // The resolved rate the link runs at, re-fed each resume so a display hop re-sources it.
        delegate.frameClock(self, setDriverFrameIntervalSeconds: 1.0 / Double(rate))
        delegate.frameClockApplyVSyncToLayer(self)
        delegate.frameClock(self, setEnableSetNeedsDisplay: false)
        delegate.frameClock(self, setPaused: false)
    }

    /// Parks a running link to on-demand drive when recommendedMode has fallen to
    /// OnDemand. A no-op when already paused. Order matches maybePause: paused
    /// flips before the driver clears, so no edge reads paused-but-active.
    @objc
    public func pauseToOnDemand() {
        guard let delegate, !delegate.frameClockIsPaused(self) else { return }
        delegate.frameClockCommitTekFrameIfIdle(self)
        delegate.frameClock(self, setPaused: true)
        delegate.frameClock(self, setDriverContinuous: false)
        delegate.frameClock(self, setEnableSetNeedsDisplay: true)
    }

    /// Re-pauses once host output has idled past the driver timeout.
    ///
    /// A no-op when already paused, so a caller can invoke this
    /// unconditionally every frame. Otherwise paused flips first, then the
    /// driver clears — the inverse of resume's order, so no edge is lost —
    /// and one recheck catches a drain that landed during the flip.
    @objc
    public func maybePause() {
        guard let delegate, !delegate.frameClockIsPaused(self),
            delegate.frameClockDriverIdleExpired(self)
        else { return }
        delegate.frameClockCommitTekFrameIfIdle(self)
        delegate.frameClock(self, setPaused: true)
        delegate.frameClock(self, setDriverContinuous: false)
        delegate.frameClock(self, setEnableSetNeedsDisplay: true)
        if !delegate.frameClockDriverIdleExpired(self) {
            resume()
        }
    }

    /// The user's frame-rate ceiling as stored, for a scenario; 0 is no cap.
    public var maxFPSForTesting: Int32 { maxFPS }

    /// Stores the user's frame-rate ceiling and re-clamps a live link now.
    ///
    /// Zero hands the decision back to `[render] max_fps`, which the resolve
    /// reads for itself.
    ///
    /// - Parameter cap: Frames per second; 0 defers to the preference.
    @objc
    public func setMaxFPS(_ cap: Int32) {
        let clamped = max(cap, 0)
        guard clamped != maxFPS else { return }
        maxFPS = clamped
        if let delegate, !delegate.frameClockIsPaused(self) {
            resume()
        }
    }

    /// Carries the run loop's fire into the pacing step.
    ///
    /// The firing timer arrives as an argument, so the schedule a fire writes
    /// lands on the timer that fired even when a delegate call re-entered the
    /// clock and re-armed it.
    ///
    /// - Parameter timer: The timer that fired.
    @objc
    private func fireTimer(_ timer: Timer) {
        fire(timer)
    }

    /// One animation fire: repaint whatever crossed, then re-space to the
    /// next crossing or stop when the screen went static.
    private func fire(_ timer: Timer) {
        guard let delegate else {
            stop()
            return
        }
        guard delegate.frameClockHasLiveTerm(self) else {
            stop()
            return
        }
        // A detached view can show no repaint this tick requests; the timer
        // parks with it, exactly as the resume path leaves the link. The next
        // drain-delivered event re-arms against a window — the same edge the
        // link re-takes.
        guard delegate.frameClockHasWindow(self) else {
            stop()
            return
        }
        delegate.frameClockServiceIngestBelt(self)
        let nowTicks = delegate.frameClockMonotonicTicks(self)
        delegate.frameClock(self, checkHiliteDeadlineAt: nowTicks)
        delegate.frameClock(self, updateRepaintIfCrossedAt: nowTicks)
        delegate.frameClockAdvanceImagesIfDue(self)
        guard delegate.frameClockHasAnimatingContent(self) else {
            delegate.frameClockResetImageClock(self)
            stop()
            return
        }
        // The same floor the arm applies: a zero or sub-tick delay from the
        // schedule would turn the timer into a runloop spin.
        timer.fireDate = Date(timeIntervalSinceNow: max(Self.tickInterval, delegate.frameClock(self, nextAnimationDelayAt: nowTicks)))
    }
}
