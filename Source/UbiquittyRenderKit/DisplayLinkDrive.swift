// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// DisplayLinkDrive.swift — the continuous drive a flood needs, paced by the
// display and paused without being torn down.
//
// MTKView drives its continuous mode through a CVDisplayLink, and pausing that
// link ends its thread: every idle-to-active edge spawned one and every pause
// joined it. Under a handful of agents whose spinners rewrite the screen a few
// times a second, that was several thread births a second in a terminal
// showing nothing new. A CADisplayLink is the run loop's — pausing it is a
// flag — and one made through NSView follows the view's display across screens,
// so the link is made once and lives as long as the view.
//
// Whether to be driving at all is `Runtime::FrameDriver`, read through the
// frame clock; this is only the link.
//
// Every method runs on the main thread: the view's frame clock delegate is a
// main-thread path and the link fires on the main run loop. Only ``attach(to:)``
// is marked, because `NSView.displayLink(target:selector:)` is itself
// main-actor isolated; the rest touch a `CADisplayLink`, which carries no
// isolation of its own.

import QuartzCore

#if canImport(AppKit)
import AppKit
#endif

/// A display link that starts and stops without a thread behind it.
@objc(UBDisplayLinkDrive)
public final class DisplayLinkDrive: NSObject {
    /// What a frame asks for, on the main thread.
    private let onFrame: () -> Void
    private var link: CADisplayLink?

    /// Whether the link is asking for frames.
    @objc
    public private(set) var isRunning = false

    /// How many times the drive has been started from a stop.
    ///
    /// A drive that is up for as long as output flows starts once; one that is
    /// stopped and restarted between deliveries counts them, which is the
    /// difference between pacing by the display and pacing by the clumps the
    /// output arrives in.
    @objc
    public private(set) var startCount = 0

    /// How many frames the link has asked for.
    @objc
    public private(set) var frameCount = 0

    /// Builds a drive, dormant until it is attached and started.
    ///
    /// - Parameter onFrame: Called on the main thread once per frame.
    @objc
    public init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    #if canImport(AppKit)
    /// Makes the link that follows a view's display.
    ///
    /// Once: a drive already attached keeps its link, which tracks the view
    /// through every window and screen it moves to. The link retains its
    /// target, so the view owning this drive ends the cycle with
    /// ``invalidate()`` when it goes away.
    ///
    /// - Parameter view: The view the frames are for.
    @MainActor
    @objc(attachToView:)
    public func attach(to view: NSView) {
        guard link == nil else { return }
        let fresh = view.displayLink(target: self, selector: #selector(linkDidFire(_:)))
        fresh.isPaused = true
        // Common modes, so the drive survives a window drag and menu tracking
        // the way the animation tick beside it does.
        fresh.add(to: .main, forMode: .common)
        link = fresh
    }
    #endif

    /// Whether a link exists to run.
    @objc
    public var isAttached: Bool { link != nil }

    /// Starts asking for frames, or re-rates a link already running.
    ///
    /// - Parameter framesPerSecond: The rate to ask at; ignored at or below
    ///   zero, which names no clock to run.
    @objc(startAtFramesPerSecond:)
    public func start(framesPerSecond: Int32) {
        guard let link, framesPerSecond > 0 else { return }
        let rate = Float(framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
        link.isPaused = false
    }

    /// Stops asking for frames. The link stays, paused, for the next start.
    @objc
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        link?.isPaused = true
    }

    /// Ends the link; the drive cannot be started again.
    @objc
    public func invalidate() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    @objc
    private func linkDidFire(_ link: CADisplayLink) {
        frameCount += 1
        onFrame()
    }
}
