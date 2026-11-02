// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GridCacheScrollBench.swift — what the retained grid keeps while
// ligature-heavy source code scrolls, on the Swift arm.
//
// The Linux frontend's --bench-gridcache-scroll measures the same workload:
// one line of Core's ligature-heavy code written at the bottom row per frame,
// so every frame scrolls by a row. Prints the share of frames that Loaded the
// retained target and the frame time, with the machine it ran on.

#if canImport(AppKit)
import AppKit
import Metal
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The bench's entry, which the application's entry point dispatches.
public final class GridCacheScrollBenchEntry: NSObject {
    /// Runs the bench.
    ///
    /// - Returns: Whether every frame was drawn.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            GridCacheScrollBench.run()
        }
    }
}

/// The measurement: a 120 x 40 surface, one line per frame.
@MainActor
enum GridCacheScrollBench {
    private static let rows = 40
    private static let columns = 120

    /// - Returns: Whether every frame was drawn.
    static func run() -> Bool {
        let arguments = CommandLine.arguments
        let frames =
            arguments.firstIndex(of: "--frames")
            .flatMap { index in
                index + 1 < arguments.count ? Int(arguments[index + 1]) : nil
            } ?? 600
        guard
            let capture = SurfaceSnapshot(
                rows: rows,
                columns: columns,
                contentScale: 2,
                configuration: Ubiquitty.Preferences.values().pointee
            )
        else {
            print("bench-grid-cache-scroll: FAIL: could not construct the surface")
            return false
        }
        var fill = ""
        for line in 0..<rows {
            fill += String(Ubiquitty.Diagnostics.RenderProfile.ligatureCodeLine(Int32(line))) + "\r\n"
        }
        capture.feed(std.string(fill))
        // Two warm frames: the first builds whole and the second settles the atlas.
        for _ in 0..<2 {
            guard capture.render() else { return false }
        }
        let partialBefore = capture.surface.frameRenderers.values.reduce(0) { $0 + $1.partialFrameCount }
        var milliseconds: [Double] = []
        milliseconds.reserveCapacity(frames)
        for frame in 0..<frames {
            capture.feed(std.string(String(Ubiquitty.Diagnostics.RenderProfile.ligatureCodeLine(Int32(rows + frame))) + "\r\n"))
            let start = CACurrentMediaTime()
            guard capture.render() else {
                print("bench-grid-cache-scroll: FAIL: frame \(frame) was not drawn")
                return false
            }
            milliseconds.append((CACurrentMediaTime() - start) * 1000)
        }
        let partial = capture.surface.frameRenderers.values.reduce(0) { $0 + $1.partialFrameCount } - partialBefore
        let sorted = milliseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(fraction * Double(sorted.count)))]
        }
        let mean = milliseconds.reduce(0, +) / Double(max(milliseconds.count, 1))
        print(
            String(
                format:
                    "bench-grid-cache-scroll: machine=\"%@ %@\" cpu=\"%@\" grid=%dx%d frames=%d partial=%d (%.1f%%) "
                    + "frame_ms mean=%.3f p50=%.3f p95=%.3f cache=%@",
                sysctlString("hw.model"),
                ProcessInfo.processInfo.operatingSystemVersionString,
                sysctlString("machdep.cpu.brand_string"),
                columns,
                rows,
                frames,
                partial,
                frames > 0 ? 100 * Double(partial) / Double(frames) : 0,
                mean,
                percentile(0.5),
                percentile(0.95),
                Ubiquitty.Rendering.isRetainedGridCacheEnabled() ? "on" : "off"
            )
        )
        return true
    }

    /// Reads one string-valued sysctl, for the machine line.
    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
