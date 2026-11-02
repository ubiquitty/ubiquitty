// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SeamAnnotated.swift — SeamSafe.swift with performance annotations, and
// nothing else changed.
//
// Same `final class`, same owned C++ cache, same Swift `Array`, same `for-in`,
// same body, same checksum. No pointer, no `unsafe`, no manual allocation —
// stripping safety is a different axis and not the one under test here.
//
// `run.sh --attribute` builds this file four ways (neither flag, -Ounchecked,
// -enforce-exclusivity=unchecked, both), measures each, and counts the
// `swift_beginAccess` calls left in its loop.
//
// Dynamic exclusivity checking guards a stored property's modify access. Core
// imports `GlyphSlotCache` as a foreign reference type, so a probe is a method
// call through a reference the class only reads. Were the cache held as a
// value, the checks would surround each access, and this sweep is what shows
// their price. `-Ounchecked` implies the exclusivity relaxation, so this arm
// takes the narrower flag: it leaves precondition and overflow traps in place.
//
// That flag is why this is a separate FILE and a separate module. It is not
// something a declaration can opt into — it is a compilation-unit property, so
// a codebase adopting it for one hot seam adopts it for every file compiled
// beside that seam. Whatever it buys is bought at whole-module scope.
//
// The source annotations; `run.sh --disassemble` dumps this arm's loop beside
// the safe arm's, so what each leaves in it can be read off:
//
//   `@inline(__always)`  on `glyph(forKey:)`, the crossing `run` makes per key
//   `nonisolated`        states that nothing here is isolated
//   `final`              as on the safe arm
//

import UbiquittyCore

private let atlasColumns: Int32 = 128
private let atlasCapacity: Int32 = atlasColumns * 128

public final class AnnotatedSeam {
    private var cache: Ubiquitty.Rendering.GlyphSlotCache
    private let geometry: Ubiquitty.Rendering.GlyphSlotGeometry
    private let keys: [UInt32]

    public nonisolated init(cellCount: Int32) {
        self.keys = benchKeyStream(count: cellCount)
        self.cache = Ubiquitty.Rendering.makeGlyphSlotCache(
            atlasCapacity,
            Ubiquitty.Rendering.recommendedHashBuckets(atlasCapacity),
            atlasColumns
        )
        var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
        geometry.columns = atlasColumns
        geometry.slotWidthInPixels = 19
        geometry.slotHeightInPixels = 34
        geometry.glyphWidthInPixels = 17
        geometry.glyphMarginInPixels.width = 1
        geometry.glyphMarginInPixels.height = 1
        self.geometry = geometry
    }

    /// One seam crossing: probe the cache, divide the slot into a UV rect.
    @inline(__always)
    public nonisolated func glyph(forKey key: UInt32) -> Ubiquitty.Rendering.GlyphUV {
        var isFresh = false
        let slot = cache.slotForKey(UInt64(key), &isFresh)
        if slot < 0 {
            return Ubiquitty.Rendering.GlyphUV(minU: 0, minV: 0, maxU: 0, maxV: 0)
        }
        return geometry.atlasRectForBuilder(slot, atlasCapacity)
    }

    /// The timed loop, folding the checksum every arm must agree on.
    public nonisolated func run(reps: Int32) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<reps {
            cache.beginFrame()
            for key in keys {
                let uv = glyph(forKey: key)
                checksum = checksum &* 1_099_511_628_211 &+ UInt64(uv.minU.bitPattern)
                checksum = checksum &* 1_099_511_628_211 &+ UInt64(uv.maxV.bitPattern)
            }
        }
        return checksum
    }
}
