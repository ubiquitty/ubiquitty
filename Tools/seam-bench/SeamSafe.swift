// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SeamSafe.swift — the glyph seam as ordinary Swift.
//
// This is the shape a person writes without being told there is a performance
// question: a `final class` owning its C++ cache as a stored property (the
// arrangement `GlyphAtlas.swift` uses), a Swift `Array` walked with
// `for-in`, and a method call per element.
//
// There is no `unsafe` anywhere in this file, and no pointer crosses into it.
// The Swift harness imports the module, so a `public final class` is the API —
// no `@_cdecl`, no opaque handle, no hand-managed allocation.
//
// SeamAnnotated.swift is this file with performance annotations added and
// nothing else changed. Everything here is a language default: no
// `@inline(__always)`, no `nonisolated`, no `-enforce-exclusivity=unchecked`,
// no `-Ounchecked`.
//

import UbiquittyCore

private let atlasColumns: Int32 = 128
private let atlasCapacity: Int32 = atlasColumns * 128

public final class SafeSeam {
    /// The C++ cache. Core imports it as a reference-counted foreign type and
    /// hands it out through `makeGlyphSlotCache`, the way `GlyphAtlas.swift`
    /// holds its own; a `var` keeps the stored-property access the language
    /// guards by default.
    private var cache: Ubiquitty.Rendering.GlyphSlotCache
    private let geometry: Ubiquitty.Rendering.GlyphSlotGeometry
    private let keys: [UInt32]

    public init(cellCount: Int32) {
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
    public func glyph(forKey key: UInt32) -> Ubiquitty.Rendering.GlyphUV {
        var isFresh = false
        let slot = cache.slotForKey(UInt64(key), &isFresh)
        if slot < 0 {
            return Ubiquitty.Rendering.GlyphUV(minU: 0, minV: 0, maxU: 0, maxV: 0)
        }
        return geometry.atlasRectForBuilder(slot, atlasCapacity)
    }

    /// The timed loop, folding the checksum every arm must agree on.
    public func run(reps: Int32) -> UInt64 {
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
