// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RuntimeFrameBench.swift — synchronized-frame contention, measured.
//
// The producer drains a PTY flood containing DECSET-2026 frame boundaries.
// Two otherwise identical lanes leave the captures pending or claim them at
// display cadence. Their throughput delta measures whether display-side frame
// acquisition throttles ingest; claim latency and the exchange counters say
// whether the same run remained responsive by dropping superseded frames.

import Foundation
import UbiquittyCore

/// The synchronized-frame bench's entry, which the application's entry point
/// dispatches.
public final class SwiftFrameBenchEntry: NSObject {
    /// Runs the unpolled and display-polled lanes and prints their verdicts.
    ///
    /// - Returns: Whether both lanes completed.
    public static func run() -> Bool {
        RuntimeFrameBench.run()
    }
}

/// Floods one session with synchronized frames while the display claims them.
enum RuntimeFrameBench {
    /// Bytes inside each synchronized frame. A boundary is large enough that
    /// capture cadence, not shell process creation, controls the lane.
    private static let framePayloadBytes = 64 * 1024

    /// The producer file is 150 MiB plus its boundary sequences.
    private static let frameCount = 2_400

    /// How long to wait before calling a lane hung.
    private static let deadlineSeconds = 60.0

    /// The upper display cadence shared with the frame publish throttle.
    private static let tickSeconds = 1.0 / 240.0

    /// One lane's complete measurement.
    private struct Result {
        let megabytesPerSecond: Double
        let drainedBytes: UInt64
        let elapsedSeconds: Double
        let claimMicros: [Double]
        let promotedFrames: UInt64
        let overwrittenFrames: UInt64
    }

    /// Runs matched unpolled and display-polled synchronized-frame floods.
    ///
    /// - Returns: Whether both floods completed and produced measurements.
    static func run() -> Bool {
        let producerPath = NSTemporaryDirectory() + "ubiquitty-frame-bench.txt"
        guard writeProducerFile(atPath: producerPath) else {
            return failed("producer file refused")
        }
        defer { try? FileManager.default.removeItem(atPath: producerPath) }

        guard let unpolled = runLane(producerPath: producerPath, pollsDisplay: false) else {
            return false
        }
        guard let polled = runLane(producerPath: producerPath, pollsDisplay: true) else {
            return false
        }

        printResult("swift_sync_frame_unpolled", unpolled)
        printResult("swift_sync_frame_polled", polled)
        let slowdown = (1.0 - polled.megabytesPerSecond / unpolled.megabytesPerSecond) * 100.0
        print(String(format: "swift_sync_frame_poll_slowdown percent=%.2f", slowdown))

        let sorted = polled.claimMicros.sorted()
        guard !sorted.isEmpty else {
            return failed("the display-polled lane recorded no claims")
        }
        print(
            String(
                format: "swift_sync_frame_claim_us samples=%d p50=%.1f p99=%.1f max=%.1f",
                sorted.count,
                sorted[sorted.count / 2],
                sorted[min(sorted.count - 1, (sorted.count * 99) / 100)],
                sorted[sorted.count - 1]
            )
        )
        return true
    }

    /// Runs one PTY flood, optionally claiming the newest frame every tick.
    ///
    /// - Parameters:
    ///   - producerPath: The synchronized-frame stream to send through the PTY.
    ///   - pollsDisplay: Whether a display-side consumer claims captures.
    /// - Returns: The complete lane result, or nil when the flood did not end.
    private static func runLane(producerPath: String, pollsDisplay: Bool) -> Result? {
        guard let drive = RuntimeDrive(rows: 24, columns: 80) else {
            return failedResult("no session")
        }
        defer { drive.close() }

        drive.setSyncFrameCaptureGeometry(Ubiquitty.Runtime.SyncFrameCaptureGeometry())
        guard drive.launchShellCommand("cat '\(producerPath)'") else {
            return failedResult("launch refused")
        }
        guard drive.startIngest() else {
            return failedResult("ingest refused to start")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let deadline = Date(timeIntervalSinceNow: deadlineSeconds)
        var drainedBytes: UInt64 = 0
        var didFinish = false
        var claimMicros: [Double] = []
        claimMicros.reserveCapacity(16_384)

        while Date() < deadline {
            drainedBytes += drive.takeDrainedBytes()
            if drive.takeEvents().contains(.exited) {
                didFinish = true
                break
            }
            if pollsDisplay {
                let requested = clock.now
                _ = drive.takeSyncFrame()
                claimMicros.append(microseconds(from: requested, to: clock.now))
            }
            Thread.sleep(forTimeInterval: tickSeconds)
        }

        drive.stopIngest()
        drainedBytes += drive.takeDrainedBytes()
        let elapsedSeconds = microseconds(from: start, to: clock.now) / 1_000_000.0
        guard didFinish, drainedBytes > 0 else {
            return failedResult("lane never finished; drained=\(drainedBytes)")
        }
        return Result(
            megabytesPerSecond: Double(drainedBytes) / (1024.0 * 1024.0) / elapsedSeconds,
            drainedBytes: drainedBytes,
            elapsedSeconds: elapsedSeconds,
            claimMicros: claimMicros,
            promotedFrames: drive.syncFramePromoteCount,
            overwrittenFrames: drive.syncFrameOverwriteCount
        )
    }

    /// Writes a stream of large synchronized-frame transactions.
    ///
    /// - Parameter path: Where the benchmark producer file lives.
    /// - Returns: Whether the whole file was written.
    private static func writeProducerFile(atPath path: String) -> Bool {
        guard FileManager.default.createFile(atPath: path, contents: nil),
            let handle = FileHandle(forWritingAtPath: path)
        else {
            return false
        }
        defer { try? handle.close() }

        var frame = Data("\u{1b}[?2026h".utf8)
        frame.append(Data(repeating: UInt8(ascii: "a"), count: framePayloadBytes))
        frame.append(Data("\u{1b}[?2026l".utf8))
        do {
            for _ in 0..<frameCount {
                try handle.write(contentsOf: frame)
            }
        } catch {
            return false
        }
        return true
    }

    /// Prints one lane in the benchmark result format.
    private static func printResult(_ name: String, _ result: Result) {
        print(
            String(
                format: "%@ MB/s=%.1f drained=%llu elapsed=%.3fs promoted=%llu overwritten=%llu",
                name,
                result.megabytesPerSecond,
                result.drainedBytes,
                result.elapsedSeconds,
                result.promotedFrames,
                result.overwrittenFrames
            )
        )
    }

    /// Reports a benchmark failure.
    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("frame-bench: \(reason)\n".utf8))
        return false
    }

    /// Reports a lane failure with an optional result.
    private static func failedResult(_ reason: String) -> Result? {
        FileHandle.standardError.write(Data("frame-bench: \(reason)\n".utf8))
        return nil
    }

    /// Returns the interval between two instants in microseconds.
    private static func microseconds(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Double {
        let duration = to - from
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000_000.0 + Double(attoseconds) / 1e12
    }
}
