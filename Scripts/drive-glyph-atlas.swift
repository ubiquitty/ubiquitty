// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-glyph-atlas.swift — slots are distinct, stable, and keyed per face.
//
// The atlas hands Core a slot index and turns it into an atlas rectangle. Every
// way that goes wrong yields a rectangle rather than an error: a cache keyed on
// the code point alone gives bold and regular the same slot, a key that collides
// gives two characters one image, and a slot-to-rect map with the wrong stride
// puts every glyph a row off. All of it draws.
//
// A count-based assertion cannot see any of it — a cache returning a constant
// satisfies "a slot was assigned" every time. So the checks are relational:
// distinct code points differ, one code point repeats, and the same code point
// in two faces differs.

import CoreText
import Metal
import UbiquittyCore

private func checkNativeStripCoverage(
    device: MTLDevice,
    faces: FontFaces,
    check: (String, Bool, String) -> Void
) {
    guard let queue = device.makeCommandQueue() else {
        check("native strip command queue", false, "")
        return
    }
    let uploader = AtlasUploader(queue: queue)
    let baseline = 4 + CTFontGetDescent(faces[.Regular])
    guard
        let sheet = LigatureSheet(
            device: device,
            uploader: uploader,
            faces: faces,
            slotWidthInPixels: 256,
            slotHeightInPixels: 32,
            marginXInPixels: 2,
            baselinePenInPixels: baseline,
            cellAdvanceInPixels: 16,
            worstCaseCellsOnScreen: 4096,
            featureSpec: "",
            doesLigate: false,
            maxTextureDimension: device.maximumTexture2DDimension
        )
    else {
        check("native strip sheet", false, "")
        return
    }
    let narrow = String(repeating: "i", count: 600)
    let wide = String(repeating: "i", count: 512) + String(repeating: "W", count: 88)
    let spaced = String(repeating: " i 𝄞 W ", count: 80)
    for face in [Ubiquitty.Rendering.FontFace.Regular, .Italic] {
        var previousFullWidthRaster: [UInt8] = []
        for text in [narrow, wide, spaced] {
            let codePoints = text.unicodeScalars.map(\.value)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): sheet.proportionalFont(forFace: face),
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ]
                )
            )
            let naturalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            for columns in [48, 1024] {
                for alignment: UInt8 in [0, 2, 3] {
                    sheet.cache.beginFrame()
                    let available = Double(columns * 16)
                    let imageWidth = columns * 16 + 4
                    let imageHeight = 32
                    let interior = text.trimmingCharacters(in: CharacterSet(charactersIn: " "))
                    let gaps = interior.unicodeScalars.filter { $0.value == 32 }.count
                    let gapExtra = alignment == 3 && gaps > 0 ? max(0, available - naturalWidth) / Double(gaps) : 0
                    let offset = alignment == 2 ? max(0, available - naturalWidth) / 2 : 0
                    guard
                        let reference = CGContext(
                            data: nil,
                            width: imageWidth,
                            height: imageHeight,
                            bitsPerComponent: 8,
                            bytesPerRow: imageWidth,
                            space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
                        )
                    else {
                        check("native strip reference", false, "")
                        continue
                    }
                    reference.setShouldAntialias(true)
                    reference.setFillColor(gray: GlyphRasterizer.fillGray(forTier: 0), alpha: 1)
                    reference.clip(
                        to: CGRect(
                            x: 0.375,
                            y: 0,
                            width: available + 2 + (naturalWidth <= available ? 2 : 0),
                            height: Double(imageHeight)
                        )
                    )
                    if gapExtra > 0 {
                        let utf16 = Array(text.utf16)
                        let firstInked = utf16.firstIndex(where: { $0 != 32 }) ?? utf16.count
                        let lastInked = utf16.lastIndex(where: { $0 != 32 }).map { $0 + 1 } ?? firstInked
                        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
                            let count = CTRunGetGlyphCount(run)
                            let attributes = CTRunGetAttributes(run) as NSDictionary
                            let font = attributes[kCTFontAttributeName] as! CTFont
                            var glyphs = [CGGlyph](repeating: 0, count: count)
                            var positions = [CGPoint](repeating: .zero, count: count)
                            var indices = [CFIndex](repeating: 0, count: count)
                            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
                            CTRunGetPositions(run, CFRangeMake(0, count), &positions)
                            CTRunGetStringIndices(run, CFRangeMake(0, count), &indices)
                            for index in 0..<count {
                                let boundary = min(max(indices[index], firstInked), lastInked)
                                let precedingGaps = utf16[firstInked..<boundary].filter { $0 == 32 }.count
                                positions[index] = positions[index].applying(CTFontGetMatrix(font))
                                positions[index].x += 2.375 + Double(precedingGaps) * gapExtra
                                positions[index].y += baseline
                            }
                            CTFontDrawGlyphs(font, &glyphs, &positions, count, reference)
                        }
                    } else {
                        reference.textPosition = CGPoint(x: 2.375 + offset, y: baseline)
                        // One unlimited CTLine draw is independent of the tile raster loop.
                        CTLineDraw(line, reference)
                    }
                    var tiles: [Ubiquitty.Rendering.ProportionalStripPlacement] = []
                    codePoints.withUnsafeBufferPointer { points in
                        let first = sheet.proportionalStrip(
                            points,
                            widthCells: columns,
                            horizontalAlign: alignment,
                            penResidualInPixels: 0.375,
                            face: face,
                            variant: 0,
                            tileIndex: 0
                        )
                        for index in 0..<Int(first.tileCount) {
                            tiles.append(
                                sheet.proportionalStrip(
                                    points,
                                    widthCells: columns,
                                    horizontalAlign: alignment,
                                    penResidualInPixels: 0.375,
                                    face: face,
                                    variant: 0,
                                    tileIndex: index
                                )
                            )
                        }
                    }
                    uploader.flush()
                    guard let completion = queue.makeCommandBuffer() else {
                        check("native strip upload completion", false, "")
                        continue
                    }
                    completion.commit()
                    completion.waitUntilCompleted()
                    var assembled = [UInt8](repeating: 0, count: imageWidth * imageHeight)
                    for tile in tiles {
                        let width = Int(tile.widthInPixels)
                        var pixels = [UInt8](repeating: 0, count: width * imageHeight)
                        pixels.withUnsafeMutableBytes {
                            sheet.texture.getBytes(
                                $0.baseAddress!,
                                bytesPerRow: width,
                                from: MTLRegionMake2D(Int(tile.strip.minUV.x), Int(tile.strip.minUV.y), width, imageHeight),
                                mipmapLevel: 0
                            )
                        }
                        let left = Int(tile.leftInPixels) + 2
                        for row in 0..<imageHeight {
                            for column in 0..<width where left + column >= 0 && left + column < imageWidth {
                                assembled[row * imageWidth + left + column] = pixels[row * width + column]
                            }
                        }
                    }
                    let expected = Array(Data(bytes: reference.data!, count: imageWidth * imageHeight))
                    let differences = zip(assembled, expected).filter { $0 != $1 }.count
                    let label =
                        "native \(codePoints.count)-character tiles columns=\(columns) h=\(alignment) text=\(text == spaced ? "spaced supplementary" : text == narrow ? "i" : "W")"
                    check(
                        label,
                        completion.error == nil && tiles.count > 1 && tiles.allSatisfy { $0.strip.present }
                            && differences == 0 && expected.contains(where: { $0 > 0 }),
                        "face=\(face) tiles=\(tiles.count) differing coverage bytes=\(differences)"
                    )
                    if columns == 1024 && alignment == 0 && text != spaced {
                        if !previousFullWidthRaster.isEmpty {
                            check(
                                "native cache retains the distinct tail after the shared 512-character prefix",
                                assembled != previousFullWidthRaster,
                                ""
                            )
                        }
                        previousFullWidthRaster = assembled
                    }
                }
            }
        }
    }
}

@main
enum GlyphAtlasDriver {
    private static func checkConfiguredFontRoutes(faces: FontFaces, symbolFontPath: String, check: (String, Bool, String) -> Void) {
        func makeRouter(_ configuration: Ubiquitty.Preferences.Values, cjkFamily: String = "", language: String = "") -> FontRouter {
            FontRouter(
                primary: faces,
                cjkFamilyName: cjkFamily,
                cjkLanguage: language,
                symbolFamilyName: "",
                symbolFontPath: symbolFontPath,
                configuration: configuration
            )
        }
        func routedFamily(_ router: FontRouter, _ codePoint: UInt32) -> String? {
            router.routedFont(for: codePoint, face: .Regular, variableWeight: 0, wantsEmoji: false)
                .map { CTFontCopyFamilyName($0) as String }
        }
        func range(_ first: UInt32, _ last: UInt32, _ family: String) -> Ubiquitty.Preferences.RangeMapEntry {
            var entry = Ubiquitty.Preferences.RangeMapEntry()
            entry.firstCodePoint = first
            entry.lastCodePoint = last
            entry.family = std.string(family)
            return entry
        }
        let defaultRouter = makeRouter(Ubiquitty.Preferences.Values())
        for codePoint: UInt32 in [0xE000, 0xE200, 0xE700, 0xEA60, 0xF000, 0xF300, 0xF400, 0xF500, 0xF0001, 0xF02D1, 0xF1AF0] {
            let selected = defaultRouter.routedFont(for: codePoint, face: .Regular, variableWeight: 0, wantsEmoji: false)
            check(
                "bundled Nerd Font supplies private-use ranges",
                selected.map { defaultRouter.isSymbolFallbackFace($0) } == true,
                "U+\(String(codePoint, radix: 16, uppercase: true)) -> \(selected.map { CTFontCopyFamilyName($0) as String } ?? "missing")"
            )
        }
        for codePoint: UInt32 in [0x41, 0xE9, 0x3A9] {
            check("ordinary text stays primary", routedFamily(defaultRouter, codePoint) == "Menlo", "U+\(String(codePoint, radix: 16))")
        }
        for face in [Ubiquitty.Rendering.FontFace.Regular, .Bold, .Italic, .BoldItalic] {
            let selected = defaultRouter.routedFont(for: 0xE0B0, face: face, variableWeight: 0, wantsEmoji: false)
            check(
                "styled Nerd fallback retains symbol positioning and size",
                selected.map { defaultRouter.isSymbolFallbackFace($0) && CTFontGetSize($0) == faces.size } == true,
                "\(face)"
            )
        }

        let han = "東" as CFString
        let japanese = CTFontCreateForStringWithLanguage(faces[.Regular], han, CFRangeMake(0, 1), "ja" as CFString)
        let chinese = CTFontCreateForStringWithLanguage(faces[.Regular], han, CFRangeMake(0, 1), "zh-Hans" as CFString)
        let japaneseFamily = CTFontCopyFamilyName(japanese) as String
        let chineseFamily = CTFontCopyFamilyName(chinese) as String
        check("range controls use distinct available Han families", japaneseFamily != chineseFamily, "\(japaneseFamily), \(chineseFamily)")
        for firstFamily in [japaneseFamily, chineseFamily] {
            var configuration = Ubiquitty.Preferences.Values()
            configuration.rangeMap.push_back(range(0x6771, 0x6773, firstFamily))
            configuration.rangeMap.push_back(range(0x6771, 0x6773, firstFamily == japaneseFamily ? chineseFamily : japaneseFamily))
            let router = makeRouter(configuration, cjkFamily: chineseFamily)
            for codePoint: UInt32 in [0x6771, 0x6772, 0x6773] {
                check(
                    "the first overlapping range wins, including both endpoints",
                    routedFamily(router, codePoint) == firstFamily,
                    "U+\(String(codePoint, radix: 16)), \(firstFamily)"
                )
            }
            for codePoint: UInt32 in [0x6770, 0x6774] {
                check(
                    "outside a range the CJK fallback applies",
                    routedFamily(router, codePoint) == chineseFamily,
                    "U+\(String(codePoint, radix: 16))"
                )
            }
        }
        for unavailableFamily in ["Ubiquitty Missing Font Fixture", "Symbols Nerd Font Mono"] {
            var configuration = Ubiquitty.Preferences.Values()
            configuration.rangeMap.push_back(range(0x6771, 0x6771, unavailableFamily))
            configuration.rangeMap.push_back(range(0x6771, 0x6771, japaneseFamily))
            let router = makeRouter(configuration, cjkFamily: chineseFamily)
            check(
                "an unavailable first range resumes the fallback ladder",
                routedFamily(router, 0x6771) == chineseFamily,
                unavailableFamily
            )
        }
        var primaryConfiguration = Ubiquitty.Preferences.Values()
        primaryConfiguration.rangeMap.push_back(range(0x41, 0x41, "Helvetica"))
        check("a primary glyph precedes range fallback", routedFamily(makeRouter(primaryConfiguration), 0x41) == "Menlo", "")

        var languageConfiguration = Ubiquitty.Preferences.Values()
        for (language, family) in [("*", chineseFamily), ("ja", japaneseFamily), ("zh-Hant", japaneseFamily)] {
            var entry = Ubiquitty.Preferences.LanguageFallbackEntry()
            entry.script = std.string("han")
            entry.language = std.string(language)
            entry.family = std.string(family)
            languageConfiguration.languageFallbacks.push_back(entry)
        }
        for (language, expectedFamily) in [
            ("ja", japaneseFamily), ("JA", japaneseFamily), ("zh-hANT", japaneseFamily), ("ja-JP", chineseFamily),
            ("zh-Hant-TW", chineseFamily), ("zh-Hans", chineseFamily), ("", chineseFamily),
        ] {
            let router = makeRouter(languageConfiguration, language: language)
            check(
                "native Han configuration matches exact language or script default",
                routedFamily(router, 0x6771) == expectedFamily,
                language
            )
        }
    }

    private static func checkColorFontRouting(device: MTLDevice, fontDirectory: URL, check: (String, Bool, String) -> Void) {
        let fixtureURL = fontDirectory.appendingPathComponent("NotoColorEmoji-COLRv1.ttf")
        var registrationError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(fixtureURL as CFURL, .process, &registrationError) else {
            check("emoji routing fixture registers", false, String(describing: registrationError?.takeRetainedValue()))
            return
        }
        defer { CTFontManagerUnregisterFontsForURL(fixtureURL as CFURL, .process, nil) }
        guard let faces = FontFaces(family: "Menlo", size: 24, pixelsPerPoint: 1) else {
            check("emoji primary fixture resolves", false, "")
            return
        }
        let side = 48
        let points: [UInt32] = [0x1F600]
        // The window of a cluster drawn once at its block's size: the master is the
        // square Core names, whole pixels, and the window is the slot-sized square
        // that many slots across and down, which is Core's cut. CoreText rounds a
        // vector emoji's coverage by a level or two differently when it is clipped
        // to a smaller plane, so the master is drawn as the atlas draws it.
        func reference(_ family: String, scale: CGFloat, band: Int, tile: Int) -> [UInt8] {
            let masterSide = Int((CGFloat(side) * scale).rounded(.up))
            let layout = CGFloat(masterSide)
            let font = CTFontCreateWithName(family as CFString, layout * 0.92, nil)
            var characters = Array("😀".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), glyphs[0] != 0,
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: masterSide,
                    height: masterSide,
                    bitsPerComponent: 8,
                    bytesPerRow: masterSide * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return [] }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(true)
            var glyph = glyphs[0]
            var box = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &box, 1)
            var position = CGPoint(
                x: ((layout - box.width) * 0.5 - box.minX).rounded(),
                y: ((layout - box.height) * 0.5 - box.minY).rounded()
            )
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            let master = Array(Data(bytes: context.data!, count: masterSide * masterSide * 4))
            var window = [UInt8](repeating: 0, count: side * side * 4)
            for row in 0..<side where band * side + row < masterSide {
                for column in 0..<side where tile * side + column < masterSide {
                    let from = ((band * side + row) * masterSide + tile * side + column) * 4
                    let to = (row * side + column) * 4
                    window.replaceSubrange(to..<(to + 4), with: master[from..<(from + 4)])
                }
            }
            return window
        }
        func pixels(_ texture: MTLTexture, x: Int = 0, y: Int = 0) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: side * 4, from: MTLRegionMake2D(x, y, side, side), mipmapLevel: 0)
            }
            return bytes
        }
        let nativePixels = reference("Apple Color Emoji", scale: 1, band: 0, tile: 0)
        let configuredPixels = reference("Noto Color Emoji", scale: 1, band: 0, tile: 0)
        check(
            "emoji family control produces distinct nonblank pixels",
            nativePixels.contains(where: { $0 != 0 }) && configuredPixels.contains(where: { $0 != 0 }) && nativePixels != configuredPixels,
            ""
        )
        for useRangeMap in [false, true] {
            var configuration = Ubiquitty.Preferences.Values()
            configuration.emojiFallbackFont = .init(std.string(useRangeMap ? "Apple Color Emoji" : "Noto Color Emoji"))
            if useRangeMap {
                for lead in [points[0], 0x2764, 0x1F469, 0x31] {
                    var range = Ubiquitty.Preferences.RangeMapEntry()
                    range.firstCodePoint = lead
                    range.lastCodePoint = lead
                    range.family = std.string("Noto Color Emoji")
                    configuration.rangeMap.push_back(range)
                }
            }
            let router = FontRouter(
                primary: faces,
                cjkFamilyName: "",
                cjkLanguage: "",
                symbolFamilyName: "",
                symbolFontPath: "",
                configuration: configuration
            )
            var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
            geometry.columns = 4
            geometry.slotWidthInPixels = 28
            geometry.slotHeightInPixels = 52
            geometry.glyphWidthInPixels = 24
            geometry.glyphMarginInPixels.width = 2
            geometry.glyphMarginInPixels.height = 2
            geometry.referenceAdvanceInPixels = 24
            geometry.referenceLineHeightInPixels = 48
            guard
                let atlas = GlyphAtlas(
                    device: device,
                    faces: faces,
                    geometry: geometry,
                    slotCapacity: 16,
                    baselinePenInPixels: 10,
                    wideGlyphBoostCap: 1,
                    unifontScale: 0,
                    router: router
                ), let texture = atlas.colorTexture
            else {
                check("routed color atlas builds", false, "")
                continue
            }
            atlas.beginFrame()
            points.withUnsafeBufferPointer { buffer in
                let cluster = Ubiquitty.Rendering.ClusterSpan(buffer)
                let routed = router.routedFont(for: buffer.span, face: .Regular, variableWeight: 0, wantsEmoji: true)
                check("emoji rule resolves its named family", routed.map { CTFontCopyFamilyName($0) as String } == "Noto Color Emoji", "")
                check(
                    "normal emoji raster follows the rule",
                    atlas.rasteriseColorGlyph(cluster, slot: 0) && pixels(texture) == configuredPixels,
                    "range=\(useRangeMap)"
                )
                for band: UInt8 in 0..<2 {
                    for tileColumn: UInt8 in 0..<2 {
                        var tile = Ubiquitty.Rendering.SizedTile()
                        tile.scale = 2
                        tile.band = band
                        tile.tile = tileColumn
                        let glyph = atlas.sizedColorGlyph(cluster, tile: tile)
                        let expected = reference("Noto Color Emoji", scale: 2, band: Int(band), tile: Int(tileColumn))
                        check(
                            "sized emoji raster follows the rule",
                            glyph.present && pixels(texture, x: Int(glyph.minUV.x), y: Int(glyph.minUV.y)) == expected,
                            "range=\(useRangeMap) band=\(band) tile=\(tileColumn)"
                        )
                        // A fraction is drawn at its own size, three halves of a
                        // square here, never the whole-scale raster resampled.
                        var fractional = tile
                        fractional.scale = 3
                        fractional.fractionNumerator = 1
                        fractional.fractionDenominator = 2
                        let fractionalGlyph = atlas.sizedColorGlyph(cluster, tile: fractional)
                        let fractionalExpected = reference("Noto Color Emoji", scale: 1.5, band: Int(band), tile: Int(tileColumn))
                        check(
                            "fractional emoji raster is drawn at its drawn size",
                            fractionalGlyph.present
                                && pixels(texture, x: Int(fractionalGlyph.minUV.x), y: Int(fractionalGlyph.minUV.y)) == fractionalExpected,
                            "range=\(useRangeMap) band=\(band) tile=\(tileColumn)"
                        )
                    }
                }
            }
            for cluster in [[UInt32(0x2764), 0xFE0F], [0x1F469, 0x200D, 0x1F680], [0x31, 0xFE0F, 0x20E3]] {
                cluster.withUnsafeBufferPointer {
                    let selected = router.routedFont(for: $0.span, face: .Regular, variableWeight: 0, wantsEmoji: true)
                    let selectedFamily = selected.map { CTFontCopyFamilyName($0) as String }
                    check(
                        "emoji cluster routing respects its configured family",
                        selectedFamily == "Noto Color Emoji",
                        "\(cluster) -> \(selectedFamily ?? "missing")"
                    )
                    check(
                        "the color route retains complete variation and joined clusters",
                        atlas.rasteriseColorGlyph(Ubiquitty.Rendering.ClusterSpan($0), slot: 0)
                            && pixels(texture).contains(where: { $0 != 0 }),
                        "\(cluster)"
                    )
                }
            }
            let textHeart: [UInt32] = [0x2764, 0xFE0E]
            let selectedText = router.routedFont(for: textHeart.span, face: .Regular, variableWeight: 0, wantsEmoji: false)
            check("VS15 keeps the primary text face", selectedText.map { CTFontCopyFamilyName($0) as String } == "Menlo", "")
        }
    }

    /// SF Pro as a proportional grid face: a digit-wide cell, and the letter
    /// layout's shaper placing the specimen rows where CoreText's own line
    /// puts them, with the ink gaps that packing leaves measured.
    ///
    /// The answer is the atlas's own chain — Core's pitch and cell,
    /// ``PrimaryRunShaper`` over the grid's faces — compared with the line
    /// CoreText lays out for the same text, on the outlines rather than on a
    /// rendered row, so a failure names the letter that moved or the pair
    /// that touched.
    private static func checkProportionalRunLayout(device: MTLDevice, check: (String, Bool, String) -> Void) {
        let family = "SF Pro"
        guard
            let geometry = FontGeometry(
                familyName: family,
                pointSize: 14,
                atlasScale: 2,
                maxTextureDimension: device.maximumTexture2DDimension
            ),
            CTFontCopyFamilyName(geometry.faces[.Regular]) as String == family
        else {
            // SF Pro ships with macOS alone; another host has nothing to measure.
            return
        }
        let faces = geometry.faces
        let regular = faces[.Regular]
        func advance(_ character: Character, in font: CTFont) -> Double {
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
            return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, 1)
        }
        check("SF Pro is a proportional face", FontGeometry.facePitch(of: regular) == .Proportional, "")
        check(
            "its cell is the advance of 0",
            abs(Double(geometry.geometry.referenceAdvanceInPixels) - advance("0", in: regular)) < 0.001,
            "\(geometry.geometry.referenceAdvanceInPixels) against \(advance("0", in: regular))"
        )
        check(
            "which is narrower than its widest letter",
            Double(geometry.geometry.referenceAdvanceInPixels) < advance("W", in: regular),
            ""
        )
        let shaper = PrimaryRunShaper(faces: faces)
        let rows = [
            "The quick brown fox jumps over the lazy dog",
            "plain Hamburg 0123 WWW iii",
            "user@host ~/Projects/ubiquitty % ls -l",
            "-rw-r--r--  1 user  staff  4096 Oct 20 23:41 README.md",
            "drwxr-xr-x  9 user  staff   288 Oct 20 23:40 Source",
        ]
        var narrowest = Double.infinity
        var narrowestPair = ""
        var widestMisplacement = 0.0
        var misplaced = ""
        for row in rows {
            let codePoints = row.unicodeScalars.map { UInt32($0.value) }
            let shaped = codePoints.withUnsafeBufferPointer { text in
                shaper.shape(Ubiquitty.Rendering.ClusterSpan(text), face: .Regular, weight: 0)
            }
            check(
                "\(row.prefix(12))… shapes one glyph per letter",
                shaped.count == codePoints.count,
                "\(shaped.count) for \(codePoints.count)"
            )
            guard shaped.count == codePoints.count else { continue }
            // CoreText's own line for the same text: where it puts each glyph
            // is where the layout's pens must land.
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): regular,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: row, attributes: attributes))
            var linePositions: [Double] = []
            for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
                let count = CTRunGetGlyphCount(run)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRangeMake(0, count), &positions)
                linePositions.append(contentsOf: positions.map { Double($0.x) })
            }
            var pen = 0.0
            var previous: (right: Double, character: Character)?
            for (index, character) in row.enumerated() {
                let glyph = shaped[index]
                if index < linePositions.count {
                    let misplacement = abs(pen + Double(glyph.offsetXInPixels) - linePositions[index])
                    if misplacement > widestMisplacement {
                        widestMisplacement = misplacement
                        misplaced = "\(character) in \(row.prefix(12))…"
                    }
                }
                var measured = CGGlyph(truncatingIfNeeded: glyph.glyph)
                let ink = CTFontGetBoundingRectsForGlyphs(regular, .horizontal, &measured, nil, 1)
                if character != " ", !ink.isNull, ink.width > 0 {
                    if let previous {
                        let gap = pen + Double(ink.minX) - previous.right
                        if gap < narrowest {
                            narrowest = gap
                            narrowestPair = "\(previous.character)\(character)"
                        }
                    }
                    previous = (pen + Double(ink.maxX), character)
                } else if character == " " {
                    previous = nil
                }
                pen += Double(glyph.advanceInPixels)
            }
        }
        check(
            "the layout's pens are CoreText's own positions",
            widestMisplacement < 1.0 / 64.0,
            "\(misplaced) off by \(widestMisplacement) px"
        )
        // Kerning may bring a pair's ink together; it never crosses it in
        // SF Pro's specimen rows, so a negative gap is a letter drawn at the
        // wrong pen rather than the face's design.
        check("no two letters' ink overlaps", narrowest >= 0, "\(narrowestPair) at \(narrowest) px")
    }

    private static func checkFallbackBoxStrokeProfile(device: MTLDevice, check: (String, Bool, String) -> Void) {
        // Times has no box rules; Helvetica carries straight rules but no rounded corners.
        // The profile must describe the fallback pixels actually uploaded for the rules.
        guard let faces = FontFaces(family: "Times", size: 24, pixelsPerPoint: 1) else {
            check("fallback box fixture", false, "")
            return
        }
        let router = FontRouter(
            primary: faces,
            cjkFamilyName: "",
            cjkLanguage: "",
            symbolFamilyName: "Helvetica",
            symbolFontPath: "",
            configuration: Ubiquitty.Preferences.Values()
        )
        check("primary lacks the reference rule", GlyphAtlas.glyphIdentifier(for: 0x2500, in: faces[.Regular]) == nil, "")
        var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
        geometry.columns = 16
        geometry.slotWidthInPixels = 20
        geometry.slotHeightInPixels = 40
        geometry.glyphWidthInPixels = 16
        geometry.glyphMarginInPixels.width = 2
        geometry.glyphMarginInPixels.height = 4
        guard
            let atlas = GlyphAtlas(
                device: device,
                faces: faces,
                geometry: geometry,
                slotCapacity: 256,
                baselinePenInPixels: 4 + CTFontGetDescent(faces[.Regular]),
                wideGlyphBoostCap: 1,
                unifontScale: 0,
                router: router
            )
        else {
            check("fallback box atlas", false, "")
            return
        }
        atlas.beginFrame()
        check("rounded corners require geometry", !atlas.boxGlyph(0x256D, face: .Regular).present, "")
        let profile = atlas.slotGeometry.boxStrokeProfile
        for codePoint: UInt32 in [0x2500, 0x2502] {
            let glyph = atlas.boxGlyph(codePoint, face: .Regular)
            check("fallback rule is font drawn", glyph.present, "")
            guard glyph.present else { continue }
            atlas.flushStagedUploads()
            let width = Int(glyph.maxUV.x - glyph.minUV.x)
            let height = Int(glyph.maxUV.y - glyph.minUV.y)
            let rowBytes = 256
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                let commands = atlas.commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
            else {
                check("fallback rule readback", false, "")
                continue
            }
            blit.copy(
                from: atlas.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(glyph.minUV.x), y: Int(glyph.minUV.y), z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: rowBytes,
                destinationBytesPerImage: rowBytes * height
            )
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            var pixels = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width { pixels[y * width + x] = bytes[y * rowBytes + x] }
            }
            var measured = Ubiquitty.Rendering.BoxDrawing.BoxStrokeProfile()
            pixels.withUnsafeBufferPointer {
                Ubiquitty.Rendering.BoxDrawing.foldBoxReferenceScan(
                    &measured,
                    codePoint,
                    $0.baseAddress!,
                    Int32($0.count),
                    Int32(width),
                    Int32(height)
                )
            }
            let expected = codePoint == 0x2500 ? measured.lightHorizontal : measured.lightVertical
            let actual = codePoint == 0x2500 ? profile.lightHorizontal : profile.lightVertical
            check(
                "fallback stroke profile matches uploaded rule",
                actual.isValid && expected.isValid
                    && abs(actual.centerInCell - expected.centerInCell) < 0.0001
                    && abs(actual.thicknessInCell - expected.thicknessInCell) < 0.0001,
                "code \(codePoint): center \(actual.centerInCell)/\(expected.centerInCell), width \(actual.thicknessInCell)/\(expected.thicknessInCell)"
            )
        }
    }

    private static func checkConfigurationSharing(
        device: MTLDevice,
        symbolFontPath: String,
        check: (String, Bool, String) -> Void
    ) {
        func key(_ font: FontGeometry, family: String, weight: Int32 = 0, boldWeight: Int32 = 0, width: Double = 0) -> String? {
            GlyphAtlas.sheetKey(
                device: device,
                familyName: family,
                pointSize: 16,
                pixelsPerPoint: 1,
                geometry: font.geometry,
                slotCapacity: 256,
                baselinePenInPixels: font.baselinePenInPixels,
                wideGlyphBoostCap: 1,
                unifontScale: 0,
                cjkFallbackFamily: "",
                cjkFallbackLanguage: "",
                symbolFamilyName: "",
                symbolFontPath: symbolFontPath,
                ligatureFeatureSpec: "",
                userFeatureSpec: "",
                userVariationSpec: "",
                fontWeight: weight,
                boldFontWeight: boldWeight,
                fontWidthPercent: width,
                fontLigates: true,
                wantsLigatures: true
            )
        }
        func shared(_ key: String?, font: FontGeometry, faces: FontFaces? = nil) -> GlyphAtlas? {
            guard let key else { return nil }
            return GlyphAtlas.shared(
                key: key,
                device: device,
                faces: faces ?? font.faces,
                geometry: font.geometry,
                slotCapacity: 256,
                baselinePenInPixels: font.baselinePenInPixels,
                wideGlyphBoostCap: 1,
                unifontScale: 0,
                router: nil,
                ligatureFeatureSpec: "",
                fontLigates: true
            )
        }
        func atlasCoverage(_ atlas: GlyphAtlas, face: Ubiquitty.Rendering.FontFace) -> [UInt8] {
            atlas.beginFrame()
            let glyph = atlas.monoGlyph(0x4D, face: face, weight: 0, variant: 0)
            guard glyph.present else { return [] }
            atlas.flushStagedUploads()
            let width = Int(glyph.maxUV.x - glyph.minUV.x)
            let height = Int(glyph.maxUV.y - glyph.minUV.y)
            let rowBytes = ((width + 255) / 256) * 256
            guard width > 0, height > 0,
                let readback = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                let commands = atlas.commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
            else { return [] }
            blit.copy(
                from: atlas.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(glyph.minUV.x), y: Int(glyph.minUV.y), z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: readback,
                destinationOffset: 0,
                destinationBytesPerRow: rowBytes,
                destinationBytesPerImage: rowBytes * height
            )
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            guard commands.status == .completed else { return [] }
            return withExtendedLifetime(readback) {
                let bytes = Span(_unsafeStart: readback.contents().assumingMemoryBound(to: UInt8.self), count: readback.length)
                var result: [UInt8] = []
                result.reserveCapacity(width * height)
                for row in 0..<height {
                    for column in 0..<width {
                        result.append(bytes[row * rowBytes + column])
                    }
                }
                return result
            }
        }
        guard
            let plain = FontGeometry(
                familyName: "Menlo",
                pointSize: 16,
                atlasScale: 1,
                maxTextureDimension: device.maximumTexture2DDimension
            ),
            let tracked = FontGeometry(
                familyName: "Menlo",
                pointSize: 16,
                atlasScale: 1,
                maxTextureDimension: device.maximumTexture2DDimension,
                characterSpacingPoints: 2
            )
        else {
            check("tracking fixtures resolve", false, "")
            return
        }
        check(
            "tracking preserves the mono slot",
            plain.geometry.slotWidthInPixels == tracked.geometry.slotWidthInPixels
                && plain.geometry.slotHeightInPixels == tracked.geometry.slotHeightInPixels
                && plain.geometry.referenceAdvanceInPixels == tracked.geometry.referenceAdvanceInPixels,
            ""
        )
        check(
            "tracking changes the real strip canvas",
            plain.geometry.ligatureSlotWidthInPixels != tracked.geometry.ligatureSlotWidthInPixels,
            "\(plain.geometry.ligatureSlotWidthInPixels) vs \(tracked.geometry.ligatureSlotWidthInPixels)"
        )
        let plainKey = key(plain, family: "Menlo")
        let trackedKey = key(tracked, family: "Menlo")
        check("tracking configurations have distinct keys", plainKey != trackedKey, "")
        guard let plainAtlas = shared(plainKey, font: plain), let trackedAtlas = shared(trackedKey, font: tracked) else {
            check("tracking atlases build", false, "")
            return
        }
        check("tracking configurations retain independent atlases", plainAtlas !== trackedAtlas, "")
        check(
            "tracking atlas keeps its own strip canvas",
            trackedAtlas.slotGeometry.ligatureSlotWidthInPixels == tracked.geometry.ligatureSlotWidthInPixels,
            ""
        )
        check("equivalent configurations deliberately share", shared(plainKey, font: plain) === plainAtlas, "")

        let variableURL = URL(fileURLWithPath: symbolFontPath).deletingLastPathComponent().appendingPathComponent("MonaspaceNeonVar.ttf")
        var registrationError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(variableURL as CFURL, .process, &registrationError) else {
            check("variable fixture registers", false, String(describing: registrationError?.takeRetainedValue()))
            return
        }
        defer { CTFontManagerUnregisterFontsForURL(variableURL as CFURL, .process, nil) }
        let family = "Monaspace Neon Var"
        guard
            let variable = FontGeometry(
                familyName: family,
                pointSize: 16,
                atlasScale: 1,
                maxTextureDimension: device.maximumTexture2DDimension
            ), let baseFaces = FontFaces(family: family, size: 16, pixelsPerPoint: 1, weight: 400, boldWeight: 700, widthPercent: 100)
        else {
            check("variable fixture resolves", false, "")
            return
        }
        func coverage(_ faces: FontFaces, face: Ubiquitty.Rendering.FontFace) -> [UInt8] {
            guard let rasterizer = GlyphRasterizer(width: 96, height: 64) else { return [] }
            var character: UInt16 = 0x4D
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(faces[face], &character, &glyph, 1), glyph != 0,
                rasterizer.rasterise(glyph: glyph, in: faces[face], at: CGPoint(x: 16, y: 16))
            else { return [] }
            return rasterizer.coverage
        }
        let baseKey = key(variable, family: family, weight: 400, boldWeight: 700, width: 100)
        guard let baseAtlas = shared(baseKey, font: variable, faces: baseFaces) else {
            check("variable base atlas builds", false, "")
            return
        }
        let originalRegularPixels = atlasCoverage(baseAtlas, face: .Regular)
        let originalBoldPixels = atlasCoverage(baseAtlas, face: .Bold)
        check(
            "variable atlas contains real regular and bold pixels",
            originalRegularPixels.contains(where: { $0 != 0 })
                && originalBoldPixels.contains(where: { $0 != 0 }),
            ""
        )
        for (label, weight, boldWeight, width, face) in [
            ("regular weight", 800, 700, 100.0, Ubiquitty.Rendering.FontFace.Regular),
            ("bold weight", 400, 900, 100.0, Ubiquitty.Rendering.FontFace.Bold),
            ("width", 400, 700, 125.0, Ubiquitty.Rendering.FontFace.Regular),
        ] {
            guard
                let changedFaces = FontFaces(
                    family: family,
                    size: 16,
                    pixelsPerPoint: 1,
                    weight: weight,
                    boldWeight: boldWeight,
                    widthPercent: width
                )
            else {
                check("\(label) fixture resolves", false, "")
                continue
            }
            let originalCoverage = coverage(baseFaces, face: face)
            let changedCoverage = coverage(changedFaces, face: face)
            var character: UInt16 = 0x4D
            var glyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(changedFaces[face], &character, &glyph, 1)
            let bounds = CTFontGetBoundingRectsForGlyphs(changedFaces[face], .horizontal, &glyph, nil, 1)
                .offsetBy(dx: CGFloat(variable.geometry.glyphMarginInPixels.width), dy: variable.baselinePenInPixels)
            check(
                "\(label) fixture fits the common slot",
                bounds.minX >= 0 && bounds.minY >= 0
                    && bounds.maxX <= Double(variable.geometry.slotWidthInPixels)
                    && bounds.maxY <= Double(variable.geometry.slotHeightInPixels),
                "\(bounds)"
            )
            check(
                "\(label) changes actual native coverage",
                originalCoverage.contains(where: { $0 != 0 })
                    && changedCoverage.contains(where: { $0 != 0 }) && originalCoverage != changedCoverage,
                ""
            )
            let changedKey = key(variable, family: family, weight: Int32(weight), boldWeight: Int32(boldWeight), width: width)
            check("\(label) changes the key", changedKey != baseKey, "")
            guard let changedAtlas = shared(changedKey, font: variable, faces: changedFaces) else {
                check("\(label) atlas builds", false, "")
                continue
            }
            check("\(label) gets an independent atlas", changedAtlas !== baseAtlas, "")
            let changedPixels = atlasCoverage(changedAtlas, face: face)
            let originalPixels = face == .Regular ? originalRegularPixels : originalBoldPixels
            check(
                "\(label) changes uploaded native pixels",
                changedPixels.contains(where: { $0 != 0 }) && changedPixels != originalPixels,
                ""
            )
            check("\(label) replacement preserves retained atlas pixels", atlasCoverage(baseAtlas, face: face) == originalPixels, "")
        }
        let equivalentFaces = FontFaces(family: family, size: 16, pixelsPerPoint: 1, weight: 400, boldWeight: 700, widthPercent: 100)
        check(
            "equivalent independently resolved variable facts deliberately share",
            equivalentFaces != nil
                && shared(key(variable, family: family, weight: 400, boldWeight: 700, width: 100), font: variable, faces: equivalentFaces)
                    === baseAtlas,
            ""
        )
    }

    /// A sized window is the block's geometry, not the master's: it is cut by the
    /// face's own advance, and the glyph stands where its advance, centred in the
    /// extent the windows step across, and the anchor's subpixel pen put it.
    ///
    /// Two blocks are drawn at seven times the size and read back window by window.
    /// A bar, whose ink is the middle of the block either way it is cut, shows the
    /// pen's phase: drawn without it the bar stands half a pixel from where the
    /// pen says. A bracket in cells that advance four pixels less than the box
    /// shows the step: cut a whole box along, each window begins four pixels late
    /// and the glyph, centred in a longer extent, stands further along, so the
    /// bracket's ends land six pixels from where the pen puts them. Its two ends
    /// are read and not its centre, because a centre is where the two displacements
    /// cancel.
    private static func checkSizedWindowGeometry(device: MTLDevice, check: (String, Bool, String) -> Void) {
        guard let faces = FontFaces(family: "Menlo", size: 26, pixelsPerPoint: 1) else {
            check("sized window face resolves", false, "")
            return
        }
        let font = faces[Ubiquitty.Rendering.FontFace.Regular]
        let scale = 7
        let marginX = 2
        let marginY = 4
        func geometry(step: Float, line: Float = 0) -> Ubiquitty.Rendering.GlyphSlotGeometry {
            var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
            geometry.columns = 8
            geometry.slotWidthInPixels = 20
            geometry.slotHeightInPixels = 32
            geometry.glyphWidthInPixels = 16
            geometry.glyphMarginInPixels.width = Int32(marginX)
            geometry.glyphMarginInPixels.height = Int32(marginY)
            geometry.referenceAdvanceInPixels = step
            geometry.referenceLineHeightInPixels = line
            return geometry
        }
        /// The span of a window's cell box that holds ink, in block pixels.
        func cellBox(
            atlas: GlyphAtlas,
            geometry: Ubiquitty.Rendering.GlyphSlotGeometry,
            codePoint: UInt32,
            phase: UInt32,
            window: Int,
            band: Int,
            step: Double,
            pass: Ubiquitty.Rendering.GlyphPass = .Subpixel
        ) -> ClosedRange<Double>? {
            var tile = Ubiquitty.Rendering.SizedTile()
            tile.scale = UInt8(scale)
            tile.tile = UInt8(window)
            tile.band = UInt8(band)
            if pass == .CellBaked {
                tile.step = .CellBox
            }
            atlas.beginFrame()
            let glyph = atlas.sizedGlyph(codePoint, face: .Regular, weight: 0, phase: phase, pass: pass, tile: tile)
            atlas.flushStagedUploads()
            guard glyph.present else { return nil }
            let width = Int(geometry.slotWidthInPixels)
            let height = Int(geometry.slotHeightInPixels)
            let rowBytes = (width + 255) / 256 * 256
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                let commands = atlas.commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
            else { return nil }
            blit.copy(
                from: atlas.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(glyph.minUV.x) - marginX, y: Int(glyph.minUV.y) - marginY, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: rowBytes,
                destinationBytesPerImage: rowBytes * height
            )
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            var extent: ClosedRange<Double>?
            for y in marginY..<(height - marginY) {
                // The window's own cell: where the block's pixel is its column's,
                // and not the margin the neighbouring window shows as well.
                for x in marginX..<(marginX + Int(step.rounded(.up))) {
                    let position = Double(window) * step + Double(x - marginX)
                    if position >= Double(window + 1) * step || bytes[y * rowBytes + x] < 128 { continue }
                    extent = min(extent?.lowerBound ?? position, position)...max(extent?.upperBound ?? position, position + 1)
                }
            }
            return extent
        }
        func glyphFacts(_ codePoint: UInt32) -> (advance: Double, minInk: Double, maxInk: Double)? {
            var character = UInt16(codePoint)
            var glyph = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return nil }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            var ink = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &ink, 1)
            return (Double(advance.width), Double(ink.minX), Double(ink.maxX))
        }
        for (name, codePoint, step) in [("bar", UInt32(0x7C), nil as Double?), ("bracket", UInt32(0x5B), 12.0)] {
            guard let facts = glyphFacts(codePoint) else {
                check("sized window \(name) resolves", false, "")
                continue
            }
            let drawnStep = step ?? facts.advance
            let blockGeometry = geometry(step: Float(drawnStep))
            guard
                let atlas = GlyphAtlas(
                    device: device,
                    faces: faces,
                    geometry: blockGeometry,
                    slotCapacity: 64,
                    baselinePenInPixels: Double(marginY) + CTFontGetDescent(font),
                    wideGlyphBoostCap: 1.0,
                    unifontScale: 0
                )
            else {
                check("sized window atlas builds", false, "")
                continue
            }
            for phase: UInt32 in [0, 4] {
                var extent: ClosedRange<Double>?
                for band in 0..<scale {
                    for window in 0..<scale {
                        guard
                            let cell = cellBox(
                                atlas: atlas,
                                geometry: blockGeometry,
                                codePoint: codePoint,
                                phase: phase,
                                window: window,
                                band: band,
                                step: drawnStep
                            )
                        else { continue }
                        extent =
                            min(
                                extent?.lowerBound ?? cell.lowerBound,
                                cell.lowerBound
                            )...max(extent?.upperBound ?? cell.upperBound, cell.upperBound)
                    }
                }
                // The glyph's advance, magnified, centred in the extent the windows
                // step across, then the anchor's subpixel pen.
                let pen =
                    Double(phase) / Double(Ubiquitty.Rendering.subpixelPhaseCount)
                    + Double(scale) * (drawnStep - facts.advance) / 2
                let expectedLeft = pen + Double(scale) * facts.minInk
                let expectedRight = pen + Double(scale) * facts.maxInk
                // CoreText places a pen this large on whole pixels, so each end of the
                // ink is within a pixel and a half of the pen's own place. Both ends
                // are read, as a centre cancels: a window cut a box too far along
                // moves the ink one way and the glyph, centred in a longer extent,
                // moves it the other.
                check(
                    "the sized \(name) stands where the block's pen puts it",
                    extent.map { abs($0.lowerBound - expectedLeft) <= 1.5 && abs($0.upperBound - expectedRight) <= 1.5 } ?? false,
                    "phase \(phase): ink \(extent.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none") expected \(expectedLeft)...\(expectedRight)"
                )
            }
        }

        // A window a grid cell maps texel for texel is cut at the cell box, whatever
        // the face's advance. The same bracket, in cells that advance four pixels
        // less than the box, is read on the cell-baked pass: its quad takes the
        // whole 16-pixel box, so the windows step the box and the glyph, centred in
        // the longer extent they step across, stands at the 1x cell's centring
        // scaled. Cut at the advance and drawn on the cell, it would be stretched.
        if let facts = glyphFacts(0x5B) {
            let boxStep = 16.0
            // A column of subpixel headroom past the box, as the app's slots carry:
            // the canvas less its margins is 17 wide over the 16 pixel cell box.
            var blockGeometry = geometry(step: 12.0)
            blockGeometry.slotWidthInPixels = 21
            if let atlas = GlyphAtlas(
                device: device,
                faces: faces,
                geometry: blockGeometry,
                slotCapacity: 64,
                baselinePenInPixels: Double(marginY) + CTFontGetDescent(font),
                wideGlyphBoostCap: 1.0,
                unifontScale: 0
            ) {
                var tile = Ubiquitty.Rendering.SizedTile()
                tile.scale = UInt8(scale)
                tile.step = .CellBox
                atlas.beginFrame()
                let rect = atlas.sizedGlyph(0x5B, face: .Regular, weight: 0, phase: 0, pass: .CellBaked, tile: tile)
                check(
                    "a cell-baked sized window names the whole cell box",
                    rect.present && abs(Double(rect.maxUV.x - rect.minUV.x) - boxStep) < 0.001,
                    "\(rect.maxUV.x - rect.minUV.x) wide, wanting \(boxStep)"
                )
                var extent: ClosedRange<Double>?
                for band in 0..<scale {
                    for window in 0..<scale {
                        guard
                            let cell = cellBox(
                                atlas: atlas,
                                geometry: blockGeometry,
                                codePoint: 0x5B,
                                phase: 0,
                                window: window,
                                band: band,
                                step: boxStep,
                                pass: .CellBaked
                            )
                        else { continue }
                        extent =
                            min(
                                extent?.lowerBound ?? cell.lowerBound,
                                cell.lowerBound
                            )...max(extent?.upperBound ?? cell.upperBound, cell.upperBound)
                    }
                }
                let pen = Double(scale) * (boxStep - facts.advance) / 2
                let expectedLeft = pen + Double(scale) * facts.minInk
                let expectedRight = pen + Double(scale) * facts.maxInk
                check(
                    "the cell-baked sized bracket stands where the cell's centring puts it",
                    extent.map { abs($0.lowerBound - expectedLeft) <= 1.5 && abs($0.upperBound - expectedRight) <= 1.5 } ?? false,
                    "ink \(extent.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none") expected \(expectedLeft)...\(expectedRight)"
                )
            }
        }

        // The block begins at the line's top, where the glyph's ascent says. The
        // slot's box is a pixel taller than the line, with the spare row above, and
        // a glyph stood on the box's bottom would stand that row, at seven times
        // the size, low: a flat-bottomed X's foot is the block's seven ascents down.
        let line: Float = 23.3
        let lineGeometry = geometry(step: 15.0, line: line)
        if let atlas = GlyphAtlas(
            device: device,
            faces: faces,
            geometry: lineGeometry,
            slotCapacity: 64,
            baselinePenInPixels: Double(marginY) + CTFontGetDescent(font),
            wideGlyphBoostCap: 1.0,
            unifontScale: 0
        ) {
            var foot: Double?
            for band in 0..<scale {
                for window in 0..<scale {
                    var tile = Ubiquitty.Rendering.SizedTile()
                    tile.scale = UInt8(scale)
                    tile.tile = UInt8(window)
                    tile.band = UInt8(band)
                    atlas.beginFrame()
                    let glyph = atlas.sizedGlyph(0x58, face: .Regular, weight: 0, phase: 0, pass: .Subpixel, tile: tile)
                    atlas.flushStagedUploads()
                    let width = Int(lineGeometry.slotWidthInPixels)
                    let height = Int(lineGeometry.slotHeightInPixels)
                    let rowBytes = (width + 255) / 256 * 256
                    guard glyph.present,
                        let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                        let commands = atlas.commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
                    else { continue }
                    blit.copy(
                        from: atlas.texture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: Int(glyph.minUV.x) - marginX, y: Int(glyph.minUV.y) - marginY, z: 0),
                        sourceSize: MTLSize(width: width, height: height, depth: 1),
                        to: buffer,
                        destinationOffset: 0,
                        destinationBytesPerRow: rowBytes,
                        destinationBytesPerImage: rowBytes * height
                    )
                    blit.endEncoding()
                    commands.commit()
                    commands.waitUntilCompleted()
                    let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
                    for y in marginY..<(height - marginY) {
                        let position = Double(band) * Double(line) + Double(y - marginY) + 1
                        if position > Double(band + 1) * Double(line) { continue }
                        for x in marginX..<(width - marginX) where bytes[y * rowBytes + x] >= 128 {
                            foot = max(foot ?? position, position)
                        }
                    }
                }
            }
            let expected = Double(scale) * (Double(line) - CTFontGetDescent(font))
            check(
                "the sized X's foot stands the block's ascents from its top",
                foot.map { abs($0 - expected) <= 1.5 } ?? false,
                "foot \(foot.map { String($0) } ?? "none") expected \(expected)"
            )
        } else {
            check("sized window line atlas builds", false, "")
        }
    }

    private static func checkFallbackTextPlacement(device: MTLDevice, check: (String, Bool, String) -> Void) {
        for size in [13.0, 26.0, 48.0] {
            guard
                let font = FontGeometry(
                    familyName: "Menlo",
                    pointSize: size,
                    atlasScale: 1,
                    maxTextureDimension: device.maximumTexture2DDimension
                )
            else {
                check("fallback placement font", false, "")
                continue
            }
            let router = FontRouter(
                primary: font.faces,
                cjkFamilyName: "",
                cjkLanguage: "",
                symbolFamilyName: "",
                symbolFontPath: "",
                configuration: Ubiquitty.Preferences.Values()
            )
            guard
                let atlas = GlyphAtlas(
                    device: device,
                    faces: font.faces,
                    geometry: font.geometry,
                    slotCapacity: 256,
                    baselinePenInPixels: font.baselinePenInPixels,
                    wideGlyphBoostCap: 1,
                    unifontScale: 0,
                    router: router
                )
            else {
                check("fallback placement atlas", false, "")
                continue
            }
            for face in [Ubiquitty.Rendering.FontFace.Regular, .Bold, .Italic, .BoldItalic] {
                atlas.beginFrame()
                _ = atlas.rasteriseMonoGlyph(0x2426, face: face, variant: 0, slot: 0)
                _ = atlas.rasteriseMonoGlyph(0x42, face: face, variant: 0, slot: 1)
                atlas.flushStagedUploads()
                var binding = Ubiquitty.Rendering.MonoAtlasBinding()
                atlas.bindMonoAtlas(into: &binding)
                guard let ink = binding.inkBoxForSlot else { continue }
                let substitute = ink[0]
                let letter = ink[1]
                let height = Double(substitute.maxInPixels.y - substitute.minInPixels.y)
                let letterHeight = Double(letter.maxInPixels.y - letter.minInPixels.y)
                let centre = Double(substitute.minInPixels.x + substitute.maxInPixels.x) / 2
                let cellCentre = Double(font.geometry.glyphMarginInPixels.width) + Double(font.geometry.glyphWidthInPixels) / 2
                let detail = "size=\(size) face=\(face) height=\(height)/\(letterHeight) centre=\(centre)/\(cellCentre)"
                check("SUB fallback has surrounding text height", abs(height - letterHeight) <= max(2, letterHeight * 0.15), detail)
                check("SUB fallback is centred in its cell", abs(centre - cellCentre) <= 1, detail)
                check(
                    "SUB fallback shares the text baseline",
                    abs(Double(substitute.maxInPixels.y) - Double(letter.maxInPixels.y)) <= 1,
                    detail
                )
            }
        }
    }

    static func main() {
        var failures = 0
        var checks = 0
        // A claim that holds is counted, not named: the closing line says how
        // many were made, and a reader acts on the ones that failed.
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            checks += 1
            if !ok {
                failures += 1
                print("  FAIL \(label) \(detail)")
            }
        }

        guard CommandLine.arguments.count == 2 else {
            print("drive-glyph-atlas: expected the bundled symbol-font path")
            exit(2)
        }
        let symbolFontPath = CommandLine.arguments[1]
        guard let device = MTLCreateSystemDefaultDevice(),
            let faces = FontFaces(family: "Menlo", size: 24.0, pixelsPerPoint: 1)
        else {
            print("drive-glyph-atlas: no Metal device or font")
            exit(2)
        }
        let router = FontRouter(
            primary: faces,
            cjkFamilyName: "",
            cjkLanguage: "",
            symbolFamilyName: "",
            symbolFontPath: symbolFontPath,
            configuration: Ubiquitty.Preferences.Values()
        )

        var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
        geometry.columns = 16
        geometry.slotWidthInPixels = 20
        geometry.slotHeightInPixels = 32
        geometry.glyphWidthInPixels = 16
        geometry.glyphMarginInPixels.width = 2
        geometry.glyphMarginInPixels.height = 4

        guard
            let atlas = GlyphAtlas(
                device: device,
                faces: faces,
                geometry: geometry,
                slotCapacity: 256,
                baselinePenInPixels: Double(geometry.glyphMarginInPixels.height) + CTFontGetDescent(faces[.Regular]),
                // No boost: this geometry publishes no wide slot, so the sheet
                // the cap belongs to is not built at all.
                wideGlyphBoostCap: 1.0,
                unifontScale: 0,
                router: router
            )
        else {
            print("drive-glyph-atlas: atlas would not build")
            exit(2)
        }
        let preparedRouter = router.preparationCopy()
        let preparedHan = preparedRouter.routedFont(for: 0x4E2D, face: .Regular, variableWeight: 0, wantsEmoji: false)
        let preparedMissing = preparedRouter.routedFont(for: 0x10FFFF, face: .Regular, variableWeight: 0, wantsEmoji: false)
        let preparedEmoji = preparedRouter.routedFont(for: 0x2615, face: .Regular, variableWeight: 0, wantsEmoji: true)
        router.adoptPreparedCascades(from: preparedRouter)
        let routeMissesBefore = router.scalarRouteMissCount
        let adoptedHan = router.routedFont(for: 0x4E2D, face: .Regular, variableWeight: 0, wantsEmoji: false)
        let adoptedMissing = router.routedFont(for: 0x10FFFF, face: .Regular, variableWeight: 0, wantsEmoji: false)
        let emojiPoints: [UInt32] = [0x2615]
        let adoptedEmoji = router.routedFont(for: emojiPoints.span, face: .Regular, variableWeight: 0, wantsEmoji: true)
        check(
            "prepared scalar fallback reaches the live route cache",
            preparedHan != nil && adoptedHan != nil && CFEqual(preparedHan, adoptedHan),
            ""
        )
        check(
            "prepared missing scalar reaches the live negative cache",
            preparedMissing == nil && adoptedMissing == nil && router.scalarRouteMissCount == routeMissesBefore,
            ""
        )
        check(
            "single-scalar clusters consume prepared emoji routes",
            preparedEmoji != nil && adoptedEmoji != nil && CFEqual(preparedEmoji, adoptedEmoji)
                && router.scalarRouteMissCount == routeMissesBefore,
            ""
        )

        atlas.beginFrame()
        checkFallbackBoxStrokeProfile(device: device, check: check)
        checkFallbackTextPlacement(device: device, check: check)
        checkSizedWindowGeometry(device: device, check: check)
        checkConfiguredFontRoutes(faces: faces, symbolFontPath: symbolFontPath, check: check)
        checkColorFontRouting(device: device, fontDirectory: URL(fileURLWithPath: symbolFontPath).deletingLastPathComponent(), check: check)

        check(
            "the sheet is sized to the grid",
            atlas.texture.width == 16 * 20 && atlas.texture.height == 16 * 32,
            "\(atlas.texture.width)x\(atlas.texture.height)"
        )

        let regular = Ubiquitty.Rendering.FontFace.Regular
        let bold = Ubiquitty.Rendering.FontFace.Bold
        let a = atlas.monoGlyph(0x41, face: regular, weight: 0, variant: 0)
        let b = atlas.monoGlyph(0x42, face: regular, weight: 0, variant: 0)
        let aAgain = atlas.monoGlyph(0x41, face: regular, weight: 0, variant: 0)
        let aBold = atlas.monoGlyph(0x41, face: bold, weight: 0, variant: 0)

        // Menlo carries none of these. Every assigned code point in the
        // original Powerline and Powerline Extra sets must therefore resolve
        // through the bundled Symbols Nerd Font, so a user does not need a
        // patched primary face. The holes are unassigned upstream and are not
        // included in this list.
        let powerlineCodePoints = (UInt32(0xE0A0)...UInt32(0xE0D7))
            .filter {
                Ubiquitty.Rendering.BoxDrawing.isPowerlineGlyph($0)
            }
        var missingPowerline: [String] = []
        for codePoint in powerlineCodePoints {
            guard
                let font = router.routedFont(
                    for: codePoint,
                    face: regular,
                    variableWeight: 0,
                    wantsEmoji: false
                )
            else {
                missingPowerline.append("U+" + String(codePoint, radix: 16, uppercase: true))
                continue
            }
            var character = UInt16(codePoint)
            var glyph: CGGlyph = 0
            if !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) || glyph == 0 {
                missingPowerline.append("U+" + String(codePoint, radix: 16, uppercase: true))
            }
        }
        check(
            "the bundled symbol font carries every assigned Powerline glyph",
            missingPowerline.isEmpty,
            missingPowerline.joined(separator: ", ")
        )

        check("'A' has a slot", a.present, "uv=(\(a.minUV.x), \(a.minUV.y))")
        check("'A' and 'B' land in different slots", a.minUV.x != b.minUV.x || a.minUV.y != b.minUV.y)
        check(
            "'A' twice is the same slot",
            a.minUV.x == aAgain.minUV.x && a.minUV.y == aAgain.minUV.y
        )
        check(
            "'A' bold differs from 'A' regular",
            a.minUV.x != aBold.minUV.x || a.minUV.y != aBold.minUV.y
        )

        // A shaped glyph is keyed and slotted by Core, which hands the atlas a
        // slot to draw into and then reads that slot's ink entry for the
        // healed letterform's quad and for an underline that follows its ink.
        // The atlas's whole share is the raster and the entry, so the entry is
        // what is held here: a raster that left the previous occupant's box,
        // or none, puts the rule at the cell edge while the letter runs on.
        var shapedBinding = Ubiquitty.Rendering.MonoAtlasBinding()
        atlas.bindMonoAtlas(into: &shapedBinding)
        let shapedSlot = shapedBinding.slotCapacity - 1
        let didDrawShaped = atlas.rasteriseShapedGlyph(36, face: regular, variant: 0, slot: shapedSlot)
        check("a shaped glyph draws into the slot it is handed", didDrawShaped)
        if let inkTable = shapedBinding.inkBoxForSlot {
            let shapedInk = inkTable[Int(shapedSlot)]
            check(
                "and leaves that slot's ink entry measured",
                shapedInk.minInPixels.x < shapedInk.maxInPixels.x && shapedInk.minInPixels.y < shapedInk.maxInPixels.y,
                "ink=(\(shapedInk.minInPixels.x), \(shapedInk.minInPixels.y))-(\(shapedInk.maxInPixels.x), \(shapedInk.maxInPixels.y))"
            )
        } else {
            check("the mono binding carries an ink table", false, "")
        }

        // A rect that runs past the sheet is a stride error, and it reads as a
        // glyph drawn from the wrong row rather than as an out-of-range index.
        check(
            "the rect stays inside the sheet",
            a.maxUV.x <= Float(atlas.texture.width) && a.maxUV.y <= Float(atlas.texture.height)
                && a.minUV.x >= 0.0 && a.minUV.y >= 0.0,
            "max=(\(a.maxUV.x), \(a.maxUV.y))"
        )

        // No atlasRectForBuilder agreement check here. Written as a loop over slot
        // indices it compares monoGlyph's rect against atlasRectForBuilder(slot), but
        // monoGlyph returns the rect for whatever slot the cache assigned, and
        // the loop index is a different slot — two populations, and every
        // disagreement it reports is the comparison's own. The check needs the
        // slot the cache chose, which this type does not expose, and an
        // accessor existing only for a test is a seam nothing else asks for.

        // The key the atlas probes with must be the key the builder probes with.
        // Core's builder runs the hit path itself against this same cache, so a
        // packing derived here instead would send monoGlyph to a slot the builder
        // never filled — and the neighbouring glyph draws, which no count sees.
        var keysAgree = true
        for (codePoint, weight, phase) in [
            (UInt32(0x41), UInt32(0), UInt32(0)),
            (UInt32(0x41), UInt32(3), UInt32(0)),
            (UInt32(0x41), UInt32(0), UInt32(2)),
            (UInt32(0x4E2D), UInt32(0), UInt32(0)),
        ] {
            let core = Ubiquitty.Rendering.monoGlyphKey(codePoint, weight, regular, phase)
            let plain = Ubiquitty.Rendering.monoGlyphKey(codePoint, 0, regular, 0)
            if (weight != 0 || phase != 0) && core == plain {
                keysAgree = false
                print("       weight/phase does not change the key for \(codePoint)")
            }
        }
        check("weight and phase are in the key", keysAgree)
        check(
            "CoreText UTF-16 clusters preserve supplementary characters",
            LigatureSheet.proportionalUTF16SourceIndices([0x41, 0x1F600, 0x42]) == [0, 1, 1, 2, 3]
        )

        // The wide sheet, both ways round. A one-armed check here would pass on
        // an atlas that never builds the sheet and on one that always does, so
        // the zero geometry is asserted too — Core reads a zero wide slot as
        // "leave a two-cell glyph on its own cell", and a backend that bound a
        // sheet anyway would draw a pass Core emits nothing into.
        var wideGeometry = geometry
        wideGeometry.wideSlotWidthInPixels = geometry.slotWidthInPixels * 2
        wideGeometry.wideSlotHeightInPixels = geometry.slotHeightInPixels
        wideGeometry.referenceAdvanceInPixels = Float(geometry.glyphWidthInPixels)
        wideGeometry.referenceLineHeightInPixels = Float(geometry.slotHeightInPixels)
        wideGeometry.ligatureSlotWidthInPixels = geometry.slotWidthInPixels * 16
        wideGeometry.ligatureSlotHeightInPixels = geometry.slotHeightInPixels
        if let wideAtlas = GlyphAtlas(
            device: device,
            faces: faces,
            geometry: wideGeometry,
            slotCapacity: 256,
            baselinePenInPixels: Double(wideGeometry.glyphMarginInPixels.height) + CTFontGetDescent(faces[.Regular]),
            // Above 1, so the wide sheet this geometry does publish is built with
            // the boost live rather than with the one value that disables it.
            wideGlyphBoostCap: 1.1,
            unifontScale: 0
        ) {
            var binding = Ubiquitty.Rendering.WideAtlasBinding()
            wideAtlas.bindWideAtlas(into: &binding)
            check("a wide geometry binds a wide sheet", binding.cache != nil)
            check(
                "the wide slot is two cells across",
                binding.slotWidthInPixels == geometry.slotWidthInPixels * 2,
                "\(binding.slotWidthInPixels) vs \(geometry.slotWidthInPixels * 2)"
            )
            check("the wide sheet has a texture", wideAtlas.wideTexture != nil)
            // A fractional two-cell window is drawn at its drawn size and keyed
            // apart from every whole-scale window: three halves of the glyph,
            // window by window, is a raster of its own.
            wideAtlas.beginFrame()
            var wholeTile = Ubiquitty.Rendering.SizedTile()
            wholeTile.scale = 2
            var fractionalTile = Ubiquitty.Rendering.SizedTile()
            fractionalTile.scale = 3
            fractionalTile.fractionNumerator = 1
            fractionalTile.fractionDenominator = 2
            let wholeWindow = wideAtlas.sizedWideGlyph(0x6771, face: regular, variant: 0, tile: wholeTile)
            let fractionalWindow = wideAtlas.sizedWideGlyph(0x6771, face: regular, variant: 0, tile: fractionalTile)
            let repeatedWindow = wideAtlas.sizedWideGlyph(0x6771, face: regular, variant: 0, tile: fractionalTile)
            // Read back through a blit, after the staged uploads land: the
            // sheet's texture may live where the CPU cannot read it.
            wideAtlas.flushStagedUploads()
            func widePixels(_ glyph: Ubiquitty.Rendering.AtlasGlyph) -> [UInt8] {
                guard let texture = wideAtlas.wideTexture, glyph.present else { return [] }
                let width = Int(wideGeometry.wideSlotWidthInPixels)
                let height = Int(wideGeometry.wideSlotHeightInPixels)
                let rowBytes = (width + 255) / 256 * 256
                guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                    let commands = wideAtlas.commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
                else { return [] }
                blit.copy(
                    from: texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: Int(glyph.minUV.x), y: Int(glyph.minUV.y), z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: buffer,
                    destinationOffset: 0,
                    destinationBytesPerRow: rowBytes,
                    destinationBytesPerImage: rowBytes * height
                )
                blit.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
                let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
                var pixels = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    for x in 0..<width { pixels[y * width + x] = bytes[y * rowBytes + x] }
                }
                return pixels
            }
            check("a fractional two-cell window is answered", fractionalWindow.present)
            check(
                "it holds ink, its own, apart from the whole-scale window",
                widePixels(fractionalWindow).contains(where: { $0 != 0 }) && widePixels(fractionalWindow) != widePixels(wholeWindow)
            )
            check(
                "and the same fractional window keeps its slot",
                fractionalWindow.minUV.x == repeatedWindow.minUV.x && fractionalWindow.minUV.y == repeatedWindow.minUV.y
            )
            var proportionalBinding = Ubiquitty.Rendering.ProportionalAtlasBinding()
            wideAtlas.bindProportionalAtlas(into: &proportionalBinding)
            check("a native face binds a proportional sheet", proportionalBinding.cache != nil)
            if let proportionalCache = proportionalBinding.cache, let wideCache = binding.cache {
                let wideEntries = wideCache.used()
                var isFresh = false
                let slot = proportionalCache.slotForKey(0x4100, &isFresh)
                check(
                    "the proportional cache grows without consuming the wide cache",
                    slot >= 0 && isFresh && wideCache.used() == wideEntries
                )
            }
            check(
                "the proportional texture is independent of the wide texture",
                wideAtlas.proportionalTexture != nil
                    && wideAtlas.proportionalTexture !== wideAtlas.wideTexture
            )
            check(
                "the proportional texture is independent of the mono texture",
                wideAtlas.proportionalTexture !== wideAtlas.texture
            )
            check(
                "the proportional strip texture is independent of the proportional glyph texture",
                wideAtlas.proportionalStripTexture != nil
                    && wideAtlas.proportionalStripTexture !== wideAtlas.proportionalTexture
            )
            check(
                "the proportional strip texture is independent of the ligature texture",
                wideAtlas.proportionalStripTexture !== wideAtlas.ligatureTexture
            )
            check(
                "the proportional binding carries rendering geometry",
                proportionalBinding.slotWidthInPixels == wideGeometry.wideSlotWidthInPixels
                    && proportionalBinding.slotHeightInPixels == wideGeometry.wideSlotHeightInPixels
                    && proportionalBinding.marginInPixels.width == wideGeometry.glyphMarginInPixels.width
                    && proportionalBinding.phaseCount > 0
            )
            let label: [UInt32] = [0x41, 0x42]
            let shaped = label.withUnsafeBufferPointer {
                wideAtlas.shapeProportionalRun(Ubiquitty.Rendering.ClusterSpan($0), face: regular, weight: 0)
            }
            check("the proportional face shapes a mixed-sheet label", shaped.count == 2)
            if let first = shaped.first {
                check(
                    "the dedicated sheet rasterises a shaped identity",
                    wideAtlas.rasteriseProportionalGlyph(
                        first.glyph,
                        face: regular,
                        weight: 0,
                        variant: 0,
                        slot: 0
                    )
                )
            }
            func tiledWidth(_ text: [UInt32]) -> Float {
                text.withUnsafeBufferPointer { points in
                    let run = Ubiquitty.Rendering.ClusterSpan(points)
                    let first = wideAtlas.proportionalStrip(
                        run,
                        widthCells: 1024,
                        horizontalAlign: 0,
                        penResidualInPixels: 0.375,
                        face: regular,
                        weight: 0,
                        variant: 0,
                        tileIndex: 0,
                        size: Ubiquitty.Rendering.SizedTile()
                    )
                    guard first.strip.present, first.tileCount > 1 else { return 0 }
                    var width: Float = 0
                    for index in 0..<first.tileCount {
                        let tile = wideAtlas.proportionalStrip(
                            run,
                            widthCells: 1024,
                            horizontalAlign: 0,
                            penResidualInPixels: 0.375,
                            face: regular,
                            weight: 0,
                            variant: 0,
                            tileIndex: index,
                            size: Ubiquitty.Rendering.SizedTile()
                        )
                        guard tile.strip.present, tile.tileCount == first.tileCount else { return 0 }
                        width += tile.widthInPixels
                    }
                    return width
                }
            }
            let narrowTail = [UInt32](repeating: 0x69, count: 600)
            let wideTail = [UInt32](repeating: 0x69, count: 512) + [UInt32](repeating: 0x57, count: 88)
            let narrowWidth = tiledWidth(narrowTail)
            let wideWidth = tiledWidth(wideTail)
            check("long native strips retain text beyond 512 code points", narrowWidth > 0 && wideWidth > narrowWidth)
        } else {
            check("the wide atlas was built", false)
        }

        var narrowBinding = Ubiquitty.Rendering.WideAtlasBinding()
        atlas.bindWideAtlas(into: &narrowBinding)
        check("a zero wide geometry binds nothing", narrowBinding.cache == nil)
        check("and offers no wide texture", atlas.wideTexture == nil)

        checkConfigurationSharing(device: device, symbolFontPath: symbolFontPath, check: check)
        checkNativeStripCoverage(device: device, faces: faces, check: check)
        checkProportionalRunLayout(device: device, check: check)

        print(
            failures == 0
                ? "drive-glyph-atlas: ok (\(checks) claim(s))"
                : "drive-glyph-atlas: FAILED \(failures) of \(checks)"
        )
        exit(failures == 0 ? 0 : 1)
    }
}
