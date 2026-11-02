// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ClassifyBench.swift — what bulk per-code-point work costs in C++, ordinary
// Swift and annotated Swift, with the loop inside each arm.
//
// Every arm sums the fused row-flag predicate over the same 4M-code-point
// stream; the harness takes each arm's fastest of nine trials and refuses the
// table when the arms' sums disagree, because an arm that skipped work would
// read as fast.
//
//   classify_bench
//

import ClassifyCppArm
import ClassifyFast
import ClassifySafe
import Darwin
import Foundation

/// `text` padded on the right to `width`, as printf's `%-Ns` pads.
func leftAligned(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// `text` padded on the left to `width`, as printf's `%Ns` pads.
func rightAligned(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

@main
struct ClassifyBench {
    static func main() {
        let unit = Array(
            ("The quick brown fox jumps over the lazy dog 0123456789 "
                + "const auto v = compute(x, y); // note file.cpp:42 ")
                .unicodeScalars.map(\.value)
        )
        var stream: [UInt32] = []
        while stream.count < 1 << 22 {
            stream.append(contentsOf: unit)
        }

        let swiftSafe = ClassifySafe.Classify()
        let swiftFast = ClassifyFast.Classify()
        let names = ["cpp_inline", "swift_safe", "swift_annotated"]
        let trials = 9
        var best = [Double](repeating: 1e18, count: names.count)
        var sums = [UInt64](repeating: 0, count: names.count)
        stream.withUnsafeBufferPointer { buffer in
            let codePoints = buffer.baseAddress!
            let count = buffer.count
            for _ in 0..<trials {
                for arm in 0..<names.count {
                    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let n: UInt64
                    switch arm {
                    case 0:
                        n = CppClassify.run(codePoints, count)
                    case 1:
                        n = swiftSafe.run(codePoints, count)
                    default:
                        n = swiftFast.run(codePoints, count)
                    }
                    let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
                    sums[arm] = n
                    best[arm] = min(best[arm], Double(elapsed) / Double(count))
                }
            }
        }
        for arm in 1..<names.count where sums[arm] != sums[0] {
            print("CHECKSUM MISMATCH \(names[arm]): \(sums[arm]) vs \(sums[0])")
            exit(2)
        }

        print("classify(): fused row-flag predicate, \(stream.count) codepoints/trial, \(trials) trials, min\n")
        print([leftAligned("arm", 18), rightAligned("ns/char", 12), rightAligned("vs cpp", 10)].joined(separator: " "))
        for arm in 0..<names.count {
            print(leftAligned(names[arm], 18) + String(format: " %12.3f %9.1f%%", best[arm], 100.0 * (best[arm] - best[0]) / best[0]))
        }
        print("\nchecksum \(sums[0]) (all arms)")
        print("parse_plain budget is 1.060 ns/byte total; today's shaping-only test is 0.238 ns")
    }
}
