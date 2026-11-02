// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// AppKit-only: the frame lane drives the composition path, which is the
// desktop surface's. The parse and service halves are portable, but a lane
// that cannot encode attributes nothing, so the whole bench rides the guard.

#if canImport(AppKit)
// DeliveryBench.swift — what one PTY delivery costs, measured per delivery.
//
// The paced regime's cost is per-delivery, not per-byte: a recorded agent
// session hands over a few hundred bytes at a time and the terminal answers
// every one of them. The other benches here measure throughput — bytes
// drained per second under a flood — which is exactly the regime where
// per-delivery overhead vanishes into the bulk. So none of them can say what
// one delivery costs, and the paced energy accounting has had no instrument
// at all: the measured cost per content event and the frame work that can be
// named for it differ by more than an order of magnitude.
//
// This replays a recording at its own delivery boundaries. record-stream.py
// writes a `UBQTSTREAM1\n` magic and then `<delay, length>` records, and each
// record is one read() the recorded terminal saw — so replaying them one at a
// time reproduces the paced shape the recorder saw, with no PTY, no window,
// no focus state and no display link. The delays are not slept: this measures
// the cost of a delivery, not the idle between two.
//
// Two lanes over the same records, because a single total attributes nothing.
// The service lane feeds and services; the frame lane also encodes. Their
// difference is the frame path's share, and whatever the service lane spends
// is the per-delivery fan-out itself — the term the accounting has been
// carrying as unattributed. A one-lane run cannot tell those apart, which is
// why neither lane is optional.
import AppKit
import Darwin
import Foundation
import Metal
import QuartzCore
internal import UbiquittyRenderKit
internal import UbiquittyCore

/// The delivery bench's entry, shaped like the other headless modes so the
/// entry point dispatches it the same way.
public final class DeliveryBenchEntry: NSObject {
    /// Runs both lanes and prints their per-delivery costs.
    ///
    /// - Returns: Whether both lanes replayed their recording.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            DeliveryBench.run()
        }
    }
}

/// A CPU and wall reading, taken as one triple so the three clocks describe
/// the same interval.
///
/// Thread and process time are both read because they answer different
/// questions: a delivery serviced entirely on the main thread makes them
/// equal, and a gap between them is work some other thread did for it.
private struct WorkReading {
    /// Main-thread CPU seconds.
    let threadCPUSeconds: Double
    /// Whole-process CPU seconds, user plus system.
    let processCPUSeconds: Double
    /// Monotonic wall seconds.
    let wallSeconds: Double

    /// Reads all three clocks now.
    static func now() -> WorkReading {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return WorkReading(
            threadCPUSeconds: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9,
            processCPUSeconds: user + system,
            wallSeconds: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        )
    }

    /// The interval from `earlier` to this reading.
    func since(_ earlier: WorkReading) -> WorkReading {
        WorkReading(
            threadCPUSeconds: threadCPUSeconds - earlier.threadCPUSeconds,
            processCPUSeconds: processCPUSeconds - earlier.processCPUSeconds,
            wallSeconds: wallSeconds - earlier.wallSeconds
        )
    }
}

/// The bench's scenario, kept as a type so its pieces stay named.
@MainActor
enum DeliveryBench {
    /// The recording replayed when the environment names no other.
    ///
    /// The paced scenario's own stream: an agent working under tmux, which is
    /// the shape the energy baselines measure.
    private static let defaultStreamPath = "/tmp/ubqstreams/agent_tmux_140x36.stream"

    /// The recording's grid, which must match or the replay re-wraps every
    /// line and measures a reflow the recorded terminal never did.
    private static let rows = 36
    private static let columns = 140

    /// How many deliveries each lane replays unless the environment says
    /// otherwise. Enough for the per-delivery mean to settle, short enough
    /// that both lanes finish in a few seconds.
    private static let defaultDeliveryLimit = 4000

    /// One record in the recording: a slice of the payload the recorded
    /// terminal received as a single read.
    private struct Delivery {
        let offset: Int
        let length: Int
        /// Microseconds between the previous delivery and this one, as recorded.
        let delayMicroseconds: UInt32
    }

    /// Replays the recording through both lanes.
    ///
    /// - Returns: Whether both lanes ran.
    static func run() -> Bool {
        let path = ProcessInfo.processInfo.environment["UBIQUITTY_DELIVERY_STREAM"] ?? defaultStreamPath
        guard let payload = FileManager.default.contents(atPath: path) else {
            return failed("no recording at \(path)")
        }
        guard let deliveries = parseTimedRecords(payload) else {
            return failed("\(path) is not a timed recording — record-stream.py writes the magic this needs")
        }
        let limit =
            ProcessInfo.processInfo.environment["UBIQUITTY_DELIVERY_LIMIT"]
            .flatMap(Int.init) ?? defaultDeliveryLimit
        let replayed = Array(deliveries.prefix(limit))
        guard !replayed.isEmpty else {
            return failed("\(path) holds no deliveries")
        }
        // The payload is borrowed per delivery as a CChar buffer, so it is
        // converted once here rather than per record: a per-delivery copy
        // would land inside the measured interval and be charged to the
        // terminal.
        let bytes = [CChar](unsafeUninitializedCapacity: payload.count) { buffer, initialized in
            payload.withUnsafeBytes { raw in
                raw.withMemoryRebound(to: CChar.self) { source in
                    _ = buffer.update(fromContentsOf: source)
                }
            }
            initialized = payload.count
        }

        guard let device = SystemMetalDevice.resolve() else {
            return failed("no Metal device")
        }
        guard let library = MetalPipelines.moduleShaderLibrary(for: device) else {
            return failed("no module shader library")
        }
        // A pipeline that failed to build encodes as a skipped pass without
        // reporting it, which here would silently discount the frame lane.
        let pipelines = MetalPipelines(device: device, pixelFormat: .bgra8Unorm, library: library)
        guard pipelines.unbuiltPipelines.isEmpty else {
            return failed("pipelines this device could not build: \(pipelines.unbuiltPipelines.joined(separator: ", "))")
        }

        // A cadence sweep, not two lanes. One frame per delivery is a shape
        // the app never runs -- the drive coalesces -- so a single frame lane
        // measures a worst case and cannot say what coalescing buys. Encoding
        // every Nth delivery instead makes the frame count the independent
        // variable, which is the lever this bench exists to size.
        var lanes: [(cadence: Int, result: LaneResult)] = []
        for cadence in [0, 1, 4, 16] {
            let name = cadence == 0 ? "delivery_service_only" : "delivery_frame_every_\(cadence)"
            guard
                let lane = runLane(
                    named: name,
                    bytes: bytes,
                    deliveries: replayed,
                    device: device,
                    library: library,
                    frameCadence: cadence
                )
            else {
                return false
            }
            lanes.append((cadence, lane))
        }

        // The control. Every lane fed the same recording, so every lane must
        // end on the same screen: a service lane whose servicing did nothing
        // would still report a small per-delivery cost and read as a finding,
        // and nothing else here would catch it. Comparing the end state to the
        // frame lanes' -- which demonstrably rendered, having reused 3999 of
        // 4000 frames -- is what makes the cheap number mean "cheap" rather
        // than "skipped".
        let witnesses = Set(lanes.map(\.result.screenDigest))
        guard witnesses.count == 1 else {
            return failed(
                "lanes ended on different screens \(lanes.map { "\($0.cadence):\($0.result.screenDigest)" })"
                    + " — one of them did not service what it was fed, so its cost is not a cost"
            )
        }
        guard lanes[0].result.screenDigest != emptyScreenDigest(rows: rows, columns: columns) else {
            return failed("every lane ended on a blank screen, so none of them parsed anything")
        }

        // The shipped configuration, replayed on the recording's own clock. The
        // cadence sweep presents every Nth DELIVERY, which no link does; a real
        // link fires on a wall clock and skips the fire when nothing is owed
        // (`drawSurfaceFrame` in TerminalSurface.swift). Modelling that turns the
        // lane's own CPU over the recording's own span directly into cpu-s/s, which
        // is the unit the energy baselines are in -- so this is a comparison rather
        // than an extrapolation, and the dirty-row count is measured instead of
        // guessed from bytes over columns.
        for hz in [120, 60, 30] {
            guard
                runLinkLane(
                    hertz: hz,
                    bytes: bytes,
                    deliveries: replayed,
                    device: device,
                    library: library
                )
            else {
                return false
            }
        }

        // The fixed term, isolated rather than fitted. The cadence sweep can
        // only infer a per-frame floor by extrapolating two points, and that
        // extrapolation is exactly where a saturating damage set misleads:
        // cadence 16 already falls under its own linear prediction. Encoding a
        // surface nobody has fed measures the floor outright -- zero dirty
        // rows, so whatever it costs is what a frame charges before it looks
        // at any content at all.
        guard
            let floor = runFrameFloor(
                bytes: bytes,
                deliveries: replayed,
                device: device,
                library: library
            )
        else {
            return false
        }

        // The attribution, stated rather than left to the reader.
        let perDelivery = { (seconds: Double) in seconds / Double(replayed.count) * 1e6 }
        let service = lanes[0].result
        print(String(format: "delivery_frame_floor us_per_frame=%.1f", floor))
        for lane in lanes.dropFirst() {
            let frameShare = lane.result.spent.threadCPUSeconds - service.spent.threadCPUSeconds
            let perFrame =
                lane.result.encodedFrames > 0
                ? frameShare / Double(lane.result.encodedFrames) * 1e6
                : 0
            print(
                String(
                    format: "delivery_attribution cadence=%d fanout_us=%.1f frame_us_per_delivery=%.1f frame_us_per_frame=%.1f",
                    lane.cadence,
                    perDelivery(service.spent.threadCPUSeconds),
                    perDelivery(frameShare),
                    perFrame
                )
            )
        }
        return true
    }

    /// The digest a grid of this size shows when nothing has been parsed into
    /// it, so "every lane agreed" cannot be satisfied by every lane agreeing
    /// on emptiness.
    private static func emptyScreenDigest(rows: Int, columns: Int) -> UInt64 {
        var blank = ""
        for _ in 0..<rows {
            blank += String(repeating: " ", count: columns)
            blank += "\n"
        }
        return digest(of: blank)
    }

    /// A seed-stable checksum. Swift's own hashing is randomly seeded, and
    /// while every lane here shares one process, a digest that changes between
    /// runs cannot be compared against a recorded one later.
    private static func digest(of text: String) -> UInt64 {
        text.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    /// What one lane measured.
    private struct LaneResult {
        let spent: WorkReading
        let encodedFrames: Int
        let screenDigest: UInt64
    }

    /// Replays every delivery through one freshly built surface.
    ///
    /// Each lane gets its own surface: replaying the same recording twice into
    /// one terminal would start the second lane on the first one's scrollback,
    /// and the two lanes would no longer be measuring the same work.
    ///
    /// - Returns: The lane's measured interval, or nil if it could not run.
    private static func runLane(
        named name: String,
        bytes: [CChar],
        deliveries: [Delivery],
        device: any MTLDevice,
        library: any MTLLibrary,
        frameCadence: Int
    ) -> LaneResult? {
        guard let surface = TerminalSurface(rows: rows, columns: columns) else {
            _ = failed("\(name): no surface session")
            return nil
        }
        guard
            let renderer = SurfaceRenderer(
                device: device,
                library: library,
                familyName: "Menlo",
                pointSize: 12
            )
        else {
            _ = failed("\(name): no surface renderer")
            return nil
        }
        surface.renderer = renderer
        // A layer this bench owns, never attached to a window: the frame lane
        // needs a target that can hand out a drawable, and nothing here needs
        // one that anybody sees.
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 2016, height: 1036)
        guard layer.device != nil else {
            _ = failed("\(name): the layer readied with no device, so it can hand out no drawable")
            return nil
        }

        var encodedFrames = 0
        var reusedFrames = 0
        var declinedFrames = 0
        var sinceLastFrame = 0
        let before = WorkReading.now()
        for delivery in deliveries {
            feed(surface.drive, bytes, delivery)
            surface.serviceIngestEvents()
            sinceLastFrame += 1
            if frameCadence > 0 && sinceLastFrame >= frameCadence {
                sinceLastFrame = 0
                if renderer.encodeFrame(for: surface, into: layer) {
                    encodedFrames += 1
                    if renderer.didReuseLastFrame {
                        reusedFrames += 1
                    }
                } else {
                    declinedFrames += 1
                }
            }
        }
        let spent = WorkReading.now().since(before)

        let count = Double(deliveries.count)
        let fed = deliveries.reduce(0) { $0 + $1.length }
        print(
            String(
                format:
                    "%@ deliveries=%d bytes=%d main_us=%.1f proc_us=%.1f wall_us=%.1f frames=%d reused=%d declined=%d",
                name,
                deliveries.count,
                fed,
                spent.threadCPUSeconds / count * 1e6,
                spent.processCPUSeconds / count * 1e6,
                spent.wallSeconds / count * 1e6,
                encodedFrames,
                reusedFrames,
                declinedFrames
            )
        )
        return LaneResult(
            spent: spent,
            encodedFrames: encodedFrames,
            screenDigest: digest(of: surface.gridTextForTesting())
        )
    }

    /// Feeds one recorded delivery's bytes to `drive`.
    ///
    /// The only place this file names a raw buffer, which is why it exists.
    /// RuntimeDrive offers a `Span` overload and an `UnsafeBufferPointer` one,
    /// and the Span overload is the one to reach for in general. A recorded
    /// delivery is a SLICE of one payload array, though, and a Span of a slice
    /// copies it — a copy that would land inside the measured interval and be
    /// charged to the terminal rather than to this bench. So the buffer
    /// overload is the correct one here, and naming it once keeps the raw
    /// spelling to a single site instead of one per lane.
    ///
    /// - Parameters:
    ///   - drive: The session to feed.
    ///   - bytes: The whole recorded payload.
    ///   - delivery: The record naming this delivery's slice of it.
    private static func feed(_ drive: RuntimeDrive, _ bytes: [CChar], _ delivery: Delivery) {
        bytes.withUnsafeBufferPointer { buffer in
            drive.feed(UnsafeBufferPointer(rebasing: buffer[delivery.offset..<(delivery.offset + delivery.length)]))
        }
    }

    /// Splits a timed recording into its delivery records.
    ///
    /// The format is record-stream.py's: the magic line, then a little-endian
    /// `<delay_us, length>` pair before each payload. A file that does not
    /// start with the magic is a raw capture with no delivery boundaries in
    /// it at all — this returns nil rather than inventing them, because
    /// chunking a raw file by a fixed size would measure that size and read
    /// as a per-delivery number.
    ///
    /// - Returns: The records, or nil if the file is not a timed recording.
    private static func parseTimedRecords(_ payload: Data) -> [Delivery]? {
        let magic = Array("UBQTSTREAM1\n".utf8)
        guard payload.count > magic.count, Array(payload.prefix(magic.count)) == magic else {
            return nil
        }
        var deliveries: [Delivery] = []
        var offset = magic.count
        let headerSize = 8
        payload.withUnsafeBytes { raw in
            while offset + headerSize <= raw.count {
                let delay = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let length = Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                offset += headerSize
                guard length > 0, offset + length <= raw.count else { break }
                deliveries.append(Delivery(offset: offset, length: length, delayMicroseconds: delay))
                offset += length
            }
        }
        return deliveries
    }

    /// Replays the recording against a link running at `hertz`, presenting
    /// only when a frame is owed, and reports the cost as cpu-seconds per
    /// second of recorded time.
    ///
    /// The owed gate is the point. A link fire with nothing owed returns
    /// before `encodeFrame` in the shipped app, so a lane that encoded on
    /// every boundary would charge the link rate for work the app skips and
    /// would make a rate drop look like a saving it is not.
    ///
    /// - Returns: Whether the lane ran.
    private static func runLinkLane(
        hertz: Int,
        bytes: [CChar],
        deliveries: [Delivery],
        device: any MTLDevice,
        library: any MTLLibrary
    ) -> Bool {
        guard let surface = TerminalSurface(rows: rows, columns: columns) else {
            return failed("link lane \(hertz): no surface session")
        }
        guard
            let renderer = SurfaceRenderer(
                device: device,
                library: library,
                familyName: "Menlo",
                pointSize: 12
            )
        else {
            return failed("link lane \(hertz): no surface renderer")
        }
        surface.renderer = renderer
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 2016, height: 1036)

        let period = 1.0 / Double(hertz)
        var simulatedNow = 0.0
        var nextPresent = period
        var isOwed = false
        var fires = 0
        var encodedFrames = 0
        var damagedFrames = 0
        var dirtyRowTotal = 0

        let before = WorkReading.now()
        for delivery in deliveries {
            simulatedNow += Double(delivery.delayMicroseconds) / 1e6
            while nextPresent <= simulatedNow {
                nextPresent += period
                fires += 1
                // The owed gate, exactly as the surface applies it.
                guard isOwed else { continue }
                isOwed = false
                if renderer.encodeFrame(for: surface, into: layer) {
                    encodedFrames += 1
                    if renderer.lastFrameDirtyRows > 0 {
                        damagedFrames += 1
                        dirtyRowTotal += renderer.lastFrameDirtyRows
                    }
                }
            }
            feed(surface.drive, bytes, delivery)
            surface.serviceIngestEvents()
            isOwed = true
        }
        let spent = WorkReading.now().since(before)

        let span = max(simulatedNow, 0.000001)
        let meanDirty = damagedFrames > 0 ? Double(dirtyRowTotal) / Double(damagedFrames) : 0
        print(
            String(
                format: "delivery_link hz=%d span=%.1fs fires/s=%.1f encoded/s=%.1f damaged/s=%.1f"
                    + " mean_dirty_rows=%.1f cpu_s_per_s_main=%.4f cpu_s_per_s_proc=%.4f",
                hertz,
                span,
                Double(fires) / span,
                Double(encodedFrames) / span,
                Double(damagedFrames) / span,
                meanDirty,
                spent.threadCPUSeconds / span,
                spent.processCPUSeconds / span
            )
        )
        return true
    }

    /// Encodes an unchanging surface repeatedly and reports the per-frame
    /// cost in microseconds.
    ///
    /// The recording is replayed first with no frames so the surface holds
    /// real content — a frame over a blank grid would flatter the floor. The
    /// first encode after that carries every row the replay dirtied, so it is
    /// excluded; the measured encodes follow it with nothing fed between them,
    /// so their damage set is empty.
    ///
    /// - Returns: Microseconds of main-thread CPU per zero-damage frame.
    private static func runFrameFloor(
        bytes: [CChar],
        deliveries: [Delivery],
        device: any MTLDevice,
        library: any MTLLibrary
    ) -> Double? {
        guard let surface = TerminalSurface(rows: rows, columns: columns) else {
            _ = failed("frame floor: no surface session")
            return nil
        }
        guard
            let renderer = SurfaceRenderer(
                device: device,
                library: library,
                familyName: "Menlo",
                pointSize: 12
            )
        else {
            _ = failed("frame floor: no surface renderer")
            return nil
        }
        surface.renderer = renderer
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 2016, height: 1036)

        for delivery in deliveries {
            feed(surface.drive, bytes, delivery)
            surface.serviceIngestEvents()
        }
        // The settling frame, which pays for everything the replay dirtied.
        guard renderer.encodeFrame(for: surface, into: layer) else {
            _ = failed("frame floor: the settling frame declined")
            return nil
        }

        let frames = 500
        var dirtiedFrames = 0
        let before = WorkReading.now()
        for _ in 0..<frames {
            guard renderer.encodeFrame(for: surface, into: layer) else {
                _ = failed("frame floor: a steady frame declined")
                return nil
            }
            if renderer.lastFrameDirtyRows > 0 {
                dirtiedFrames += 1
            }
        }
        let spent = WorkReading.now().since(before)
        // A floor measured over frames that were still rebuilding rows is not
        // a floor. The cursor blink alone can dirty a row, which is why this
        // is asserted rather than assumed.
        guard dirtiedFrames == 0 else {
            _ = failed(
                "frame floor: \(dirtiedFrames) of \(frames) frames still had dirty rows,"
                    + " so this is not a zero-damage measurement"
            )
            return nil
        }
        return spent.threadCPUSeconds / Double(frames) * 1e6
    }

    /// Reports a refusal on stderr and answers false, so callers read as a
    /// guard.
    @discardableResult
    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("delivery-bench: \(reason)\n".utf8))
        return false
    }
}

#endif
