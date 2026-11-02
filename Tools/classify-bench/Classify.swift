// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The fused row classifier, in Swift. Same shape as the C++ arm: one branch on
// codePoint < 128 answers both flags, because nothing below U+0590 shapes and
// nothing at or above 128 is a ligature operator.
public final class Classify {
    static let lowMask: UInt64 = 0xfc00_ec6a_0000_0000
    static let highMask: UInt64 = 0x5000_0000_d000_0001

    @inline(__always)
    static func bits(_ codePoint: UInt32) -> (Bool, Bool) {
        if codePoint < 128 {
            let mask = codePoint < 64 ? lowMask : highMask
            return (false, ((mask >> UInt64(codePoint & 63)) & 1) != 0)
        }
        if codePoint < 0x0590 { return (false, false) }
        let shaping =
            codePoint <= 0x08FF
            || codePoint == 0x200C || codePoint == 0x200D
            || (codePoint >= 0xFB1D && codePoint <= 0xFEFF)
        return (shaping, false)
    }

    public init() {}

    /// Sums both flags over the stream, so neither can be optimised away.
    public func run(_ codePoints: UnsafePointer<UInt32>, _ count: Int) -> UInt64 {
        var n: UInt64 = 0
        for i in 0..<count {
            let (shaping, ligature) = Classify.bits(codePoints[i])
            n &+= (shaping ? 1 : 0) &+ (ligature ? 1 : 0)
        }
        return n
    }
}
