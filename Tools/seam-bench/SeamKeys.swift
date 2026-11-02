// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SeamKeys.swift — the key stream, in Swift, for both Swift arms.
//
// Compiled into both Swift modules rather than passed in from C++: a buffer
// pointer at the boundary is the only unsafe construct either arm would
// otherwise need, and it would sit in the one place — the safe arm — whose
// whole claim is that it has none.
//
// This is a second implementation of the rule `buildKeyStream` applies in
// SeamCppArms.cpp, so the two can drift. They cannot drift SILENTLY: every arm
// folds a checksum over every UV it produces and the harness refuses to print a
// table unless all four agree, and a changed key stream moves the checksum on
// the first cell.
//

/// The keys one frame of ordinary terminal text asks for.
///
/// A small working set drawn many times, which is what makes the cache a cache;
/// a stream of distinct keys would measure eviction instead of the hit path the
/// seam actually runs.
func benchKeyStream(count: Int32) -> [UInt32] {
    let alphabet = Array(
        ("The quick brown fox jumps over the lazy dog 0123456789 "
            + "().,;:!?-_/\\[]{}<>=+*&^%$#@~`'\"|")
            .unicodeScalars
    )
    var keys: [UInt32] = []
    keys.reserveCapacity(Int(count))
    // Four styles and four subpixel phases, folded the way monoGlyphKey folds
    // them, so the working set is a few hundred distinct keys rather than one
    // per character.
    for i in 0..<Int(count) {
        let codePoint = alphabet[i % alphabet.count].value
        let face = UInt32((i / 97) & 3)
        let phase = UInt32(i & 3)
        keys.append((codePoint << 8) | (face << 4) | phase)
    }
    return keys
}
