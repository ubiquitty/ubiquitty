// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PresentSlipAccounting.swift — the presents that latched a vsync late.
//
// A present that latches one vsync late is invisible to CPU-side drop
// counters: the frame was encoded and committed on time, and only the glass
// saw it a refresh later. Differencing consecutive presented times, on the
// CoreAnimation present thread where the drawable reports them, is the only
// place that slip is a number at all. One component every renderer's presented handler feeds.

import Foundation
import Metal

/// Records frame delivery stages when presentation diagnostics are enabled.
public final class FrameDeliveryTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    private var transactional = 0
    private var completed = 0
    private var failed = 0
    private var presented = 0
    private var invalidTimes = 0
    private var repeatedTimes = 0
    private var firstTime = 0.0
    private var lastTime = 0.0
    private var gpuSeconds = 0.0
    private var longestGPUSeconds = 0.0
    private var latencySeconds = 0.0
    private var intervals = [Int](repeating: 0, count: 4)

    public init() {}

    public func attach(to commands: any MTLCommandBuffer, drawable: any MTLDrawable, transactionally: Bool) {
        let submittedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        submitted += 1
        if transactionally { transactional += 1 }
        lock.unlock()
        commands.addCompletedHandler { [self] buffer in
            lock.lock()
            completed += 1
            if buffer.status == .error { failed += 1 }
            let elapsed = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
            gpuSeconds += elapsed
            longestGPUSeconds = max(longestGPUSeconds, elapsed)
            lock.unlock()
        }
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { [self] value in
            let time = value.presentedTime
            lock.lock()
            defer { lock.unlock() }
            guard time > 0 else {
                invalidTimes += 1
                return
            }
            presented += 1
            latencySeconds += max(0, time - submittedAt)
            if firstTime == 0 { firstTime = time }
            if lastTime > 0 {
                let delta = time - lastTime
                if delta <= 0 { repeatedTimes += 1 } else { intervals[delta < 0.010 ? 0 : delta < 0.020 ? 1 : delta < 0.100 ? 2 : 3] += 1 }
            }
            lastTime = max(lastTime, time)
        }
        #endif
    }

    public var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let rate = lastTime > firstTime ? Double(presented - 1) / (lastTime - firstTime) : 0
        return String(
            format:
                "submitted=%d transactional=%d completed=%d failed=%d presented=%d invalid=%d repeated=%d presentedHz=%.2f gpuMeanMs=%.3f gpuMaxMs=%.3f latencyMeanMs=%.3f gaps=%d/%d/%d/%d",
            submitted,
            transactional,
            completed,
            failed,
            presented,
            invalidTimes,
            repeatedTimes,
            rate,
            gpuSeconds * 1000 / Double(max(1, completed)),
            longestGPUSeconds * 1000,
            latencySeconds * 1000 / Double(max(1, presented)),
            intervals[0],
            intervals[1],
            intervals[2],
            intervals[3]
        )
    }
}

/// Counts presents that latched a vsync late, from the presented times the
/// drawables report.
///
/// A gap between consecutive presents in (``slipThresholdInVsyncs``,
/// ``idleGapInVsyncs``) refresh periods is a slipped vsync — the extra
/// refreshes the content sat on glass; beyond the idle bound the terminal had
/// stopped drawing, which is not a slip. The first present has nothing to
/// difference against.
///
/// Written from the present thread and read from main, so the fields sit
/// under one lock; a handler still in flight at teardown holds this object,
/// so there is nothing freed for it to write through.
@objc(UBPresentSlipAccounting)
public final class PresentSlipAccounting: NSObject, @unchecked Sendable {
    /// A gap beyond this many refresh periods is idle time, not a slip.
    public static let idleGapInVsyncs = 4.0
    /// A gap beyond this many refresh periods is a present that latched late.
    public static let slipThresholdInVsyncs = 1.5

    /// One present kept for a scenario: which armed drawable it was, and when
    /// it reached the glass.
    package struct RecordedPresent: Sendable {
        /// The drawable's place in arming order, from one; zero for a present
        /// noted directly rather than through ``attach(to:)``.
        package let serial: UInt64
        /// The drawable's `presentedTime`, in host-time seconds; zero or less
        /// when the drawable never reached the glass.
        package let presentedSeconds: Double
    }

    private let lock = NSLock()
    private var lastPresentedSeconds = 0.0
    private var refreshSeconds = 1.0 / 60.0
    private var slippedVsyncCount: UInt64 = 0
    private var presentedCount: UInt64 = 0
    private var armedCount: UInt64 = 0
    /// Reserved to ``recordingCapacity`` when recording begins, so a handler
    /// on the present thread appends without allocating.
    private var recordedPresents: [RecordedPresent] = []
    /// Zero while no scenario records, which is every release frame's state.
    private var recordingCapacity = 0

    /// Records the panel's refresh period the gaps are measured against.
    ///
    /// - Parameter seconds: The refresh period; zero or less is ignored.
    @objc(noteRefreshSeconds:)
    public func noteRefreshSeconds(_ seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock()
        refreshSeconds = seconds
        lock.unlock()
    }

    /// Records one present, from its drawable's presented time.
    ///
    /// - Parameter seconds: The drawable's `presentedTime`.
    @objc(notePresentedAtSeconds:)
    public func notePresented(atSeconds seconds: Double) {
        notePresented(atSeconds: seconds, serial: 0)
    }

    private func notePresented(atSeconds seconds: Double, serial: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if recordedPresents.count < recordingCapacity {
            recordedPresents.append(RecordedPresent(serial: serial, presentedSeconds: seconds))
        }
        presentedCount += 1
        let previous = lastPresentedSeconds
        lastPresentedSeconds = seconds
        guard previous > 0, refreshSeconds > 0 else { return }
        let gapInVsyncs = (seconds - previous) / refreshSeconds
        if gapInVsyncs > Self.slipThresholdInVsyncs, gapInVsyncs < Self.idleGapInVsyncs {
            slippedVsyncCount += UInt64(gapInVsyncs + 0.5) - 1
        }
    }

    /// Whether this build can see when a drawable reached the glass.
    ///
    /// The iOS simulator SDK's `MTLDrawable` declares `present` and
    /// `presentAtTime:` and nothing else: no presented handler and no presented
    /// time. The member is missing from that header, not marked unavailable, so
    /// no runtime check can reach it and the conditional is a compile-time one.
    /// Where this is false ``attach(to:)`` records nothing, and a reader shows
    /// the count as unmeasured rather than as a clean zero.
    #if targetEnvironment(simulator)
    public static let canMeasurePresents = false
    #else
    public static let canMeasurePresents = true
    #endif

    /// Arms a drawable's presented handler to record its present.
    ///
    /// The handler is a dead-end observer: it captures this object and
    /// nothing of the renderer, reads the presented time, and returns. Where
    /// ``canMeasurePresents`` is false there is no handler to arm.
    ///
    /// - Parameter drawable: The drawable about to be presented.
    public func attach(to drawable: any MTLDrawable) {
        #if !targetEnvironment(simulator)
        lock.lock()
        armedCount += 1
        let serial = armedCount
        lock.unlock()
        drawable.addPresentedHandler { [self] presented in
            notePresented(atSeconds: presented.presentedTime, serial: serial)
        }
        #endif
    }

    /// The serial the most recently armed drawable took, for a scenario
    /// pairing its own commits with the presents recorded for them; zero
    /// before any drawable is armed.
    package var lastArmedSerialForTesting: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return armedCount
    }

    /// Starts keeping every present's serial and presented time, for a
    /// scenario reading what reached the glass rather than what was encoded.
    ///
    /// The storage is reserved here, so the present thread never allocates;
    /// presents past `capacity` are counted but not kept. Whatever
    /// an earlier recording kept is dropped.
    ///
    /// - Parameter capacity: The most presents to keep.
    package func beginRecordingForTesting(capacity: Int) {
        lock.lock()
        defer { lock.unlock() }
        recordedPresents.removeAll(keepingCapacity: true)
        recordedPresents.reserveCapacity(max(0, capacity))
        recordingCapacity = max(0, capacity)
    }

    /// The presents kept since recording began, in the order their handlers
    /// ran; recording continues.
    package var recordedPresentsForTesting: [RecordedPresent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPresents
    }

    /// Stops keeping presents and releases what was kept.
    package func endRecordingForTesting() {
        lock.lock()
        defer { lock.unlock() }
        recordingCapacity = 0
        recordedPresents = []
    }

    /// The refreshes that presents have so far latched late by, in total.
    @objc
    public var slippedVsyncs: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return slippedVsyncCount
    }

    /// How many presents have been recorded, for a scenario checking that the
    /// handler fires at all.
    public var presentedCountForTesting: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return presentedCount
    }
}
