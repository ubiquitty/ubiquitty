// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
import Metal
import QuartzCore

/// Drives visible output at the surface's display cadence.
@MainActor
internal final class SurfaceFrameLink: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
    private let onTick: () -> Void
    private var displayLink: CAMetalDisplayLink?
    private weak var layer: CAMetalLayer?
    private weak var view: NSView?
    private var transactionalLink: CADisplayLink?
    internal private(set) var currentDrawable: CAMetalDrawable?
    internal var diagnosticSnapshot: (() -> String)?
    private let tracesCadence = ProcessInfo.processInfo.environment["UBIQUITTY_TRACE_FRAME_LINK"] == "1"
    private var traceStart: CFTimeInterval = 0
    private var traceTicks = 0
    private var traceWork: CFTimeInterval = 0
    private var traceLongestWork: CFTimeInterval = 0
    private var requestedRate = 0

    internal init(layer: CAMetalLayer, view: NSView, onTick: @escaping () -> Void) {
        self.layer = layer
        self.view = view
        self.onTick = onTick
        super.init()
    }

    internal var isRunning: Bool { displayLink != nil || transactionalLink != nil }
    internal var ownsDrawableDelivery: Bool { displayLink != nil }

    /// Uses ordinary display ticks while resize steps present inside AppKit transactions.
    internal func synchronizePresentationMode() {
        if isRunning { start(framesPerSecond: requestedRate) }
    }

    internal private(set) var startCount = 0

    /// Starts the display link or updates its requested rate without resetting its phase.
    internal func start(framesPerSecond: Int) {
        guard framesPerSecond > 0, let layer else { return }
        requestedRate = framesPerSecond
        let rate = Float(framesPerSecond)
        let range = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        if layer.presentsWithTransaction, let view {
            displayLink?.invalidate()
            displayLink = nil
            if let transactionalLink {
                transactionalLink.preferredFrameRateRange = range
                return
            }
            let link = view.displayLink(target: self, selector: #selector(transactionalDisplayLinkFired))
            link.preferredFrameRateRange = range
            transactionalLink = link
            startCount += 1
            link.add(to: .main, forMode: .common)
            return
        }
        transactionalLink?.invalidate()
        transactionalLink = nil
        if let displayLink {
            displayLink.preferredFrameRateRange = range
            return
        }
        traceStart = 0
        traceTicks = 0
        traceWork = 0
        traceLongestWork = 0
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = range
        displayLink = link
        startCount += 1
        // Tracking modes must keep presenting during window resizing and menu tracking.
        link.add(to: .main, forMode: .common)
    }

    /// Invalidates continuous delivery so the layer can supply on-demand drawables.
    internal func stop() {
        displayLink?.invalidate()
        displayLink = nil
        transactionalLink?.invalidate()
        transactionalLink = nil
        if tracesCadence {
            NSLog("frame-link stopped %@", diagnosticSnapshot?() ?? "")
        }
    }

    internal func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        currentDrawable = update.drawable
        defer { currentDrawable = nil }
        performTick()
    }

    @objc
    private func transactionalDisplayLinkFired() {
        performTick()
    }

    private func performTick() {
        guard tracesCadence else {
            onTick()
            return
        }
        let start = CACurrentMediaTime()
        if traceStart == 0 { traceStart = start }
        onTick()
        let work = CACurrentMediaTime() - start
        traceWork += work
        traceLongestWork = max(traceLongestWork, work)
        traceTicks += 1
        let elapsed = start - traceStart
        if elapsed >= 1 {
            NSLog(
                "frame-link requested=%d callbacks=%.2f workMeanMs=%.3f workMaxMs=%.3f",
                requestedRate,
                Double(traceTicks - 1) / elapsed,
                traceWork * 1000 / Double(traceTicks),
                traceLongestWork * 1000
            )
            if let diagnosticSnapshot { NSLog("frame-delivery %@", diagnosticSnapshot()) }
            traceStart = start
            traceTicks = 1
            traceWork = work
            traceLongestWork = work
        }
    }
}
#endif
