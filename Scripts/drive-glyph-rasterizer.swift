// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-glyph-rasterizer.swift — a glyph reaches the coverage plane as ink.
//
// The rasteriser draws through a CoreGraphics context into bytes the atlas
// uploads as R8. Everything that can go wrong there produces a plane rather
// than an error: a context with the wrong colour space gives premultiplied
// values where coverage was wanted, a pen outside the slot draws nothing, and a
// missing clear leaves the previous glyph under the new one. All of it returns
// cleanly.
//
// So the bytes are read. The assertions are relative rather than absolute —
// `M` inks more than `i`, a space inks nothing — because absolute coverage is a
// property of the installed face and would pin this to one version of Menlo.
//
// The clear has its own case. A slot the cache reassigns still holds its last
// glyph, and a blank drawn over a heavy one has to leave the plane empty; the
// symptom otherwise is a character that shows its predecessor, which reads as a
// slot-mapping bug rather than a rasterisation one.

import CoreGraphics
import CoreText
import Foundation
import UbiquittyCore

@main
enum RasterDriver {
    static func main() {
        var failures = 0
        var checks = 0
        // A claim that holds is counted, not named: the closing line says how
        // many were made, and a reader acts on the ones that failed.
        func check(_ l: String, _ ok: Bool, _ d: String = "") {
            checks += 1
            if !ok {
                failures += 1
                print("  FAIL \(l) \(d)")
            }
        }
        guard let faces = FontFaces(family: "Menlo", size: 32.0, pixelsPerPoint: 1),
            let raster = GlyphRasterizer(width: 32, height: 40)
        else {
            print("drive-glyph-rasterizer: setup failed")
            exit(2)
        }
        let font = faces[Ubiquitty.Rendering.FontFace.Regular]

        func glyph(_ ch: UInt16) -> CGGlyph {
            var chars = [ch]
            var glyphs: [CGGlyph] = [0]
            _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
            return glyphs[0]
        }

        let inkedM = raster.rasterise(glyph: glyph(0x4D), in: font, at: CGPoint(x: 2, y: 8))
        let sumM = raster.coverage.reduce(into: 0) { (acc: inout Int, b: UInt8) in acc += Int(b) }
        check("'M' puts down ink", inkedM && sumM > 0, "coverage sum=\(sumM)")

        let inkedI = raster.rasterise(glyph: glyph(0x69), in: font, at: CGPoint(x: 2, y: 8))
        let sumI = raster.coverage.reduce(into: 0) { (acc: inout Int, b: UInt8) in acc += Int(b) }
        check("'i' inks less than 'M'", inkedI && sumI > 0 && sumI < sumM, "i=\(sumI) M=\(sumM)")

        let inkedSpace = raster.rasterise(glyph: glyph(0x20), in: font, at: CGPoint(x: 2, y: 8))
        let sumSpace = raster.coverage.reduce(into: 0) { (acc: inout Int, b: UInt8) in acc += Int(b) }
        check("space inks nothing", !inkedSpace && sumSpace == 0, "sum=\(sumSpace)")

        // The clear is the whole reason a reassigned slot does not show its
        // predecessor: draw a heavy glyph, then a blank, and the plane must be
        // empty rather than still carrying the first.
        _ = raster.rasterise(glyph: glyph(0x4D), in: font, at: CGPoint(x: 2, y: 8))
        _ = raster.rasterise(glyph: glyph(0x20), in: font, at: CGPoint(x: 2, y: 8))
        check("a blank clears the previous glyph", raster.coverage.allSatisfy { $0 == 0 })

        _ = raster.rasterise(glyph: glyph(0x4F), in: font, at: CGPoint(x: 2, y: 8))
        let edges = raster.coverage.filter { $0 > 0 && $0 < 255 }.count
        check("antialiasing produces partial coverage", edges > 0, "\(edges) edge pixel(s)")

        // Compare final slot bytes, including clipping, phases and optical
        // growth. An overhanging neighbor must never enter another tile.
        if let batched = GlyphRasterizer(width: 32, height: 40),
            let scalar = GlyphRasterizer(width: 32, height: 40)
        {
            var consumed = 0
            var mismatches = 0
            var requests = 0
            let batchFonts = [
                font, faces[Ubiquitty.Rendering.FontFace.BoldItalic], CTFontCreateWithName("PingFang SC" as CFString, 32, nil),
            ]
            for batchFont in batchFonts {
                let characters: [UInt16] = [0x4D, 0x69, 0x20, 0x66, 0x4E00, 0x4E8C, 0x4E09, 0x00E9]
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                _ = CTFontGetGlyphsForCharacters(batchFont, characters, &glyphs, characters.count)
                for tier in 0..<Ubiquitty.Rendering.rasterTierCount {
                    for (index, batchGlyph) in glyphs.enumerated() where batchGlyph != 0 {
                        for boost in [CGFloat(0), CGFloat(1.2)] {
                            let origin = CGPoint(x: 2 + CGFloat(index % 4) / 4, y: 8)
                            let style = GlyphRasterizer.Style(tier: tier)
                            scalar.rasterise(glyph: batchGlyph, in: batchFont, at: origin, boostCappedTo: boost, style: style)
                            let expected = scalar.coverage
                            batched.enqueue(glyph: batchGlyph, in: batchFont, at: origin, boostCappedTo: boost, style: style) { plane in
                                consumed += 1
                                if !plane.elementsEqual(expected) { mismatches += 1 }
                            }
                            requests += 1
                        }
                    }
                }
            }
            batched.flushBatch()
            check("every queued raster is consumed once", consumed == requests, "\(consumed)/\(requests)")
            check("batched glyphs preserve scalar coverage exactly", mismatches == 0, "\(mismatches) mismatches")
            check(
                "glyph draws are grouped",
                batched.batchDrawCount * 2 < batched.batchedGlyphCount,
                "\(batched.batchedGlyphCount) glyphs / \(batched.batchDrawCount) draws"
            )
            batched.flushBatch()
            check("an empty flush does not replay glyphs", consumed == requests)
        } else {
            check("batch rasterizers allocate", false)
        }

        if let limited = GlyphRasterizer(width: 4096, height: 4),
            let reference = GlyphRasterizer(width: 4096, height: 4)
        {
            let origin = CGPoint(x: -8, y: 0)
            reference.rasterise(glyph: glyph(0x4D), in: font, at: origin)
            let expected = reference.coverage
            var matched = false
            limited.enqueue(glyph: glyph(0x4D), in: font, at: origin, style: .heaviest) { pixels in
                matched = pixels.elementsEqual(expected)
            }
            limited.flushBatch()
            check("oversized batch tiles retain the scalar raster", matched && limited.batchDrawCount == 0)
        } else {
            check("oversized tile fixture allocates", false)
        }

        let variableURL = URL(fileURLWithPath: "Resources/fonts/MonaspaceNeonVar.ttf")
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(variableURL as CFURL, .process, &registrationError) {
            defer { CTFontManagerUnregisterFontsForURL(variableURL as CFURL, .process, nil) }
            let weightTag = UInt32(Ubiquitty.Rendering.variationAxisTagWeight)
            func weightCoordinate(_ font: CTFont) -> Double? {
                if let coordinate = (CTFontCopyVariation(font) as? [UInt32: Double])?[weightTag] {
                    return coordinate
                }
                let axis = (CTFontCopyVariationAxes(font) as? [[String: Any]] ?? [])
                    .first {
                        $0[kCTFontVariationAxisIdentifierKey as String] as? UInt32 == weightTag
                    }
                return axis?[kCTFontVariationAxisDefaultValueKey as String] as? Double
            }
            for (bodyWeight, boldWeight, expectedBold) in [(800, 0, 800), (250, 0, 700), (800, 600, 600)] {
                guard
                    let varied = FontFaces(
                        family: "Monaspace Neon Var",
                        size: 32,
                        pixelsPerPoint: 1,
                        weight: 900,
                        boldWeight: boldWeight,
                        variationSpec: "wght=\(bodyWeight)"
                    )
                else {
                    check("the variable family resolves its configured faces", false)
                    continue
                }
                check("the body variation overrides font.weight", weightCoordinate(varied[.Regular]) == Double(bodyWeight))
                check("bold uses the effective body floor or explicit weight", weightCoordinate(varied[.Bold]) == Double(expectedBold))
                if bodyWeight == expectedBold {
                    func coverage(_ face: Ubiquitty.Rendering.FontFace) -> [UInt8] {
                        var character: UInt16 = 0x7C
                        var glyph: CGGlyph = 0
                        let font = varied[face]
                        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
                            raster.rasterise(glyph: glyph, in: font, at: CGPoint(x: 2, y: 8))
                        else { return [] }
                        return raster.coverage
                    }
                    let regularCoverage = coverage(.Regular)
                    check(
                        "heavy body and default bold draw the same ink",
                        regularCoverage.contains(where: { $0 != 0 }) && regularCoverage == coverage(.Bold)
                    )
                }
            }
        } else {
            check("the bundled variable fixture registers", false, String(describing: registrationError?.takeRetainedValue()))
        }
        check("the static control has no variation axes", (CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []).isEmpty)
        if let plain = FontFaces(family: "Menlo", size: 32, pixelsPerPoint: 1, weight: 400),
            let varied = FontFaces(family: "Menlo", size: 32, pixelsPerPoint: 1, weight: 400, variationSpec: "wght=800")
        {
            for face in [Ubiquitty.Rendering.FontFace.Regular, .Bold] {
                check(
                    "an unsupported axis leaves the static member unchanged",
                    CTFontCopyPostScriptName(plain[face]) == CTFontCopyPostScriptName(varied[face])
                )
            }
        } else {
            check("the static control resolves its faces", false)
        }

        // A grown two-cell glyph keyed in its own pen grid's buckets is drawn as
        // CoreText draws it at the true pen, for every pen: the raster for the
        // bucket a pen floors into equals the raster at the pen itself. Keyed
        // at the page's count instead, a glyph that grows less than the cap —
        // or not at all — lands in a neighbouring bucket on part of the pens,
        // wherever its own grid and the page's differ.
        var differingGlyphs = 0
        var pageMismatches = 0
        var ownMismatches = 0
        let wideCap: CGFloat = 1.1
        for size in [11.0, 16.0, 32.0] {
            guard let primary = FontFaces(family: "Menlo", size: size, pixelsPerPoint: 1)?[Ubiquitty.Rendering.FontFace.Regular] else {
                check("the wide oracle's primary resolves", false, "\(size)")
                continue
            }
            var em: UInt16 = 0x4D
            var emGlyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(primary, &em, &emGlyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(primary, .horizontal, &emGlyph, &advance, 1)
            let margin = (size / 4).rounded(.up)
            let width = Int(2 * advance.width.rounded(.up) + 2 * margin)
            let height = Int((CTFontGetAscent(primary) + CTFontGetDescent(primary)).rounded(.up) + 2 * margin)
            guard let plane = GlyphRasterizer(width: width, height: height) else {
                check("the wide oracle's plane builds", false, "\(size)")
                continue
            }
            let pageCount = Int(Ubiquitty.Rendering.nativeSubpixelPhaseCount(Double(wideCap) * size))
            let penY = margin + CTFontGetDescent(primary)
            for codePoint: UInt16 in [0xFF5C, 0xFF3F, 0x3013, 0x4E00, 0x6771, 0xFF5B] {
                var character = codePoint
                let text = String(utf16CodeUnits: &character, count: 1) as CFString
                let font = CTFontCreateForString(primary, text, CFRangeMake(0, 1))
                var glyph: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { continue }
                let ownCount = plane.penGridPhaseCount(sizedBy: glyph, in: font, cappedTo: wideCap)
                if ownCount != pageCount { differingGlyphs += 1 }
                func coverage(atFraction fraction: CGFloat) -> [UInt8] {
                    plane.rasterise(glyph: glyph, in: font, at: CGPoint(x: margin + fraction, y: penY), boostCappedTo: wideCap)
                    return plane.coverage
                }
                for step in 0..<64 {
                    let fraction = CGFloat(step) / 64
                    let atPen = coverage(atFraction: fraction)
                    let ownBucket = (fraction * CGFloat(ownCount)).rounded(.down) / CGFloat(ownCount)
                    let pageBucket = (fraction * CGFloat(pageCount)).rounded(.down) / CGFloat(pageCount)
                    if coverage(atFraction: ownBucket) != atPen { ownMismatches += 1 }
                    if coverage(atFraction: pageBucket) != atPen { pageMismatches += 1 }
                }
            }
        }
        check(
            "the wide oracle reaches a glyph drawn on another grid than the page's",
            differingGlyphs > 0 && pageMismatches > 0,
            "\(differingGlyphs) glyph(s), \(pageMismatches) pen(s) off at the page's count"
        )
        check(
            "a two-cell glyph keyed at its own pen grid draws as CoreText does at every pen",
            ownMismatches == 0,
            "\(ownMismatches) pen(s) off"
        )

        print(
            failures == 0
                ? "drive-glyph-rasterizer: ok (\(checks) claim(s))"
                : "drive-glyph-rasterizer: FAILED \(failures) of \(checks)"
        )
        exit(failures == 0 ? 0 : 1)
    }
}
