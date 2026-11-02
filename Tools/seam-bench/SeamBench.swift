// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SeamBench.swift — what one glyph-atlas seam crossing costs, per language and
// per call shape.
//
// `buildCellInstances` asks a backend for a glyph once per cell, so the seam is
// crossed once per cell every frame and its dispatch is paid at that rate. In
// the renderer a change costs a full app build and the answer arrives mixed
// with everything else the frame does. This runs the same crossing on its own.
//
// Every arm performs the IDENTICAL work — probe a `GlyphSlotCache`, divide the
// slot into a UV rect — over the identical key stream, against its own
// initially-empty cache. Only the call shape differs:
//
//   cpp_inline      a direct call the compiler may inline           (the floor)
//   cpp_virtual     through an abstract base, the virtual-dispatch alternative
//   swift_safe      ordinary Swift: a `final class` owning the cache, a Swift
//                   `Array` walked with `for-in`, every language default left
//                   where it was
//   swift_annotated the same Swift with performance annotations and nothing
//                   else changed — see SeamAnnotated.swift for the list
//
// Each arm returns a checksum folded from every UV it produced. They must all
// agree: identical caches fed identical keys assign identical slots, so a
// differing checksum means an arm is not doing the work the others are and its
// time is meaningless. The harness fails rather than printing the table. That
// gate is also what lets the Swift arms build the key stream in Swift instead
// of taking a buffer pointer across the boundary.
//
// Every arm times its own loop and nothing else. Construction is charged to no
// one: a `GlyphSlotCache` allocates and zeroes about a megabyte of vectors, and
// an arm that paid for that inside the clock would be reporting the allocator.
//
// Reported on `min` across trials, never the mean or p50: p50 across runs of
// one binary can spread wider than the effect being measured while min holds
// steady. The floor a piece of
// code can reach is a property of the code; every sample above it is a property
// of the machine that afternoon.
//
//   seam_bench [--cells N] [--reps N] [--trials N]
//

import Darwin
import Foundation
import SeamAnnotated
import SeamCppArms
import SeamSafe

/// One arm's timed loop: the seconds it took and the checksum it folded.
typealias ArmRun = (_ cells: Int32, _ reps: Int32) -> (seconds: Double, checksum: UInt64)

struct Arm {
    let name: String
    let run: ArmRun
}

/// Seconds on the clock the C++ arms read through `steady_clock`.
func now() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

// A Swift class arrives as a reference-counted value and frees its own
// storage. Construction builds the key stream and the cache, so it is outside
// the clock.
func runSwiftSafe(_ cells: Int32, _ reps: Int32) -> (seconds: Double, checksum: UInt64) {
    let seam = SafeSeam(cellCount: cells)
    let start = now()
    let checksum = seam.run(reps: reps)
    return (now() - start, checksum)
}

func runSwiftAnnotated(_ cells: Int32, _ reps: Int32) -> (seconds: Double, checksum: UInt64) {
    let seam = AnnotatedSeam(cellCount: cells)
    let start = now()
    let checksum = seam.run(reps: reps)
    return (now() - start, checksum)
}

/// `text` padded on the right to `width`, as printf's `%-Ns` pads.
func leftAligned(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// `text` padded on the left to `width`, as printf's `%Ns` pads.
func rightAligned(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

@main
struct SeamBench {
    static func main() {
        var cells: Int32 = 4000 // an 80x50 screen
        var reps: Int32 = 400
        var trials = 9
        let arguments = CommandLine.arguments
        var index = 1
        while index < arguments.count {
            let hasValue = index + 1 < arguments.count
            switch arguments[index] {
            case "--cells" where hasValue:
                index += 1
                cells = Int32(atoi(arguments[index]))
            case "--reps" where hasValue:
                index += 1
                reps = Int32(atoi(arguments[index]))
            case "--trials" where hasValue:
                index += 1
                trials = Int(atoi(arguments[index]))
            default:
                break
            }
            index += 1
        }
        let callsPerTrial = Int64(cells) * Int64(reps)

        let arms = [
            Arm(name: "cpp_inline") { cells, reps in
                let result = CppSeam.runCppInline(cells, reps)
                return (result.seconds, result.checksum)
            },
            Arm(name: "cpp_virtual") { cells, reps in
                let result = CppSeam.runCppVirtual(cells, reps)
                return (result.seconds, result.checksum)
            },
            Arm(name: "swift_safe", run: runSwiftSafe),
            Arm(name: "swift_annotated", run: runSwiftAnnotated),
        ]

        // One untimed pass per arm: the first trial pays page faults. Those
        // are real costs paid once per process, and this measures the per-call
        // steady state.
        var expected: UInt64 = 0
        var areChecksumsEqual = true
        for (position, arm) in arms.enumerated() {
            let checksum = arm.run(cells, 2).checksum
            if position == 0 {
                expected = checksum
            } else if checksum != expected {
                printError(
                    "seam_bench: \(arm.name) folded \(checksum) where \(arms[0].name) folded \(expected) — the arms are not doing\n"
                        + "  the same work, so their times are not comparable.\n"
                )
                areChecksumsEqual = false
            }
        }
        if !areChecksumsEqual {
            exit(1)
        }

        // Arms rotate within a trial rather than each running its trials
        // together: thermal state and scheduler noise drift over the run, and
        // an arm that owns a contiguous block of wall-clock inherits whatever
        // the machine was doing then as if it were a property of the code.
        var best = [Double](repeating: 1e30, count: arms.count)
        var full: UInt64 = 0
        for trial in 0..<trials {
            for (position, arm) in arms.enumerated() {
                let (elapsed, checksum) = arm.run(cells, reps)
                if position == 0 && trial == 0 {
                    full = checksum
                } else if checksum != full {
                    printError("seam_bench: \(arm.name) disagreed with \(arms[0].name) on the full run\n")
                    exit(1)
                }
                best[position] = min(best[position], elapsed)
            }
        }

        print("seam_bench: \(cells) cells x \(reps) reps = \(callsPerTrial) crossings per trial, \(trials) trials, min\n")
        print(
            [leftAligned("arm", 18), rightAligned("ns/crossing", 12), rightAligned("us/frame", 12), rightAligned("vs cpp", 10)]
                .joined(separator: " ")
        )
        for (position, arm) in arms.enumerated() {
            let seconds = best[position]
            let nanosecondsPerCall = seconds / Double(callsPerTrial) * 1e9
            print(
                leftAligned(arm.name, 18)
                    + String(
                        format: " %12.3f %12.2f %+9.1f%%",
                        nanosecondsPerCall,
                        nanosecondsPerCall * Double(cells) / 1000.0,
                        (seconds - best[0]) / best[0] * 100.0
                    )
            )
        }
        print("\nchecksum \(full) (all arms)")
    }
}
