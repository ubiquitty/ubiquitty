// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RuntimeDrainBench.swift — the Swift drive under a flood, measured.
//
// The smoke proves bytes flow; this says how fast. A live child floods the
// PTY, the session's ingest thread drains it through the extracted loop, and
// the verdict is megabytes per second over the child's whole run, end to end.
//
// Two lanes, two flood shapes. The `yes` lane is parse-heavy and
// writer-limited: two-byte lines pay the pty line discipline per line on the
// producer side, so its ceiling is the writer's whatever the drain does.
// The bulk lane is `cat` of long lines — the shape the flood pipeline's
// constants were swept on, where the sequential loop's read/parse
// alternation is the bottleneck and the pipeline's overlap shows. Judge the
// pipeline on the bulk lane, against the same binary run with
// UBIQUITTY_SWIFT_FLOOD=0.

import Foundation
import UbiquittyCore

/// The bench's entry, which the application's entry point dispatches.
public final class SwiftDrainBenchEntry: NSObject {
    /// Runs one flood pass and prints the verdict line.
    ///
    /// - Returns: Whether the pass completed; the number is on standard out.
    public static func run() -> Bool {
        RuntimeDrainBench.run()
    }
}

/// Floods one session through the Swift drive and reports the drain rate.
enum RuntimeDrainBench {
    /// How many read-side bytes end the pass. Read-side, because the PTY's
    /// output processing turns the flood's two-byte lines into three on the
    /// master — counting what the drive drained is counting what it did.
    private static let targetDrainedBytes: UInt64 = 150 * 1024 * 1024

    /// How long to wait before calling the flood hung.
    private static let deadlineSeconds = 60.0

    /// How long each bulk line runs, chosen so the line discipline's per-line
    /// cost is amortised to noise and the flood is read/parse-bound.
    private static let bulkLineLength = 4096

    /// How many bulk lines the producer file holds (~200 MB).
    private static let bulkLineCount = 51_200

    /// Runs both lanes: the `yes` flood, then the bulk flood.
    ///
    /// - Returns: Whether both lanes completed.
    static func run() -> Bool {
        guard runLane(named: "swift_drain_sequential", command: "yes", targetBytes: targetDrainedBytes) else {
            return false
        }
        let bulkPath = NSTemporaryDirectory() + "ubiquitty-drain-bulk.txt"
        guard writeBulkProducerFile(atPath: bulkPath) else {
            FileHandle.standardError.write(Data("drain-bench: bulk file refused\n".utf8))
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: bulkPath) }
        // The child exits at end of file, so the lane ends on the exit event;
        // the byte target is a backstop above the file size plus the line
        // discipline's one added byte per line.
        let bulkBytes = UInt64(bulkLineCount * (bulkLineLength + 1))
        return runLane(named: "swift_drain_bulk", command: "cat '\(bulkPath)'", targetBytes: bulkBytes)
    }

    /// Floods one session with `command` and reports the lane's drain rate.
    ///
    /// The pass ends on the byte count or the child's exit rather than on a
    /// metering child's pace: a metering pipe stage sets the rate itself, and
    /// the number would belong to it rather than to the drive.
    ///
    /// - Parameters:
    ///   - name: The verdict line's lane name.
    ///   - command: The producer the shell runs.
    ///   - targetBytes: How many read-side bytes end the lane.
    /// - Returns: Whether the lane drained its flood within the deadline.
    private static func runLane(named name: String, command: String, targetBytes: UInt64) -> Bool {
        guard let drive = RuntimeDrive(rows: 24, columns: 80) else {
            FileHandle.standardError.write(Data("drain-bench: no session\n".utf8))
            return false
        }
        defer { drive.close() }
        guard drive.launchShellCommand(command) else {
            FileHandle.standardError.write(Data("drain-bench: launch refused\n".utf8))
            return false
        }
        let start = Date()
        guard drive.startIngest() else {
            FileHandle.standardError.write(Data("drain-bench: ingest refused to start\n".utf8))
            return false
        }
        var drained: UInt64 = 0
        var didFinish = false
        let deadline = Date(timeIntervalSinceNow: deadlineSeconds)
        while Date() < deadline {
            drained += drive.takeDrainedBytes()
            if drained >= targetBytes {
                didFinish = true
                break
            }
            if drive.takeEvents().contains(.exited) {
                // The producer ran out before the backstop target — the whole
                // file drained, which is this lane's normal ending.
                drained += drive.takeDrainedBytes()
                didFinish = drained > 0
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let elapsed = Date().timeIntervalSince(start)
        drive.stopIngest()
        drained += drive.takeDrainedBytes()
        guard didFinish else {
            FileHandle.standardError.write(Data("drain-bench: \(name) never finished; drained=\(drained)\n".utf8))
            return false
        }
        let megabytesPerSecond = Double(drained) / (1024.0 * 1024.0) / elapsed
        print(String(format: "%@ MB/s=%.1f drained=%llu elapsed=%.3fs", name, megabytesPerSecond, drained, elapsed))
        return true
    }

    /// Writes the bulk lane's producer file: long printable lines.
    ///
    /// - Parameter path: Where the file lands.
    /// - Returns: Whether the whole file was written.
    private static func writeBulkProducerFile(atPath path: String) -> Bool {
        guard FileManager.default.createFile(atPath: path, contents: nil),
            let handle = FileHandle(forWritingAtPath: path)
        else {
            return false
        }
        defer { try? handle.close() }
        // One line pattern, repeated: the flood measures transport and parse,
        // not content entropy, and a repeated line keeps the writer trivial.
        var line = [UInt8](repeating: UInt8(ascii: "a"), count: bulkLineLength)
        line.append(UInt8(ascii: "\n"))
        let block = Data((0..<64).flatMap { _ in line })
        let blockCount = bulkLineCount / 64
        for _ in 0..<blockCount {
            do {
                try handle.write(contentsOf: block)
            } catch {
                return false
            }
        }
        return true
    }
}
