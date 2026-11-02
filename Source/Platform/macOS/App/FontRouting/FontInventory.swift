// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FontInventory.swift — macOS CoreText font lookup policy helpers.

import CoreText
import Foundation
import UbiquittyCore
import UbiquittyRenderKit

@objc(UBFontInventory)
final class FontInventory: NSObject {
    @objc(copyFontForFamily:size:)
    static func copyFont(forFamily family: String?, size: CGFloat) -> CTFont? {
        guard let family, !family.isEmpty else {
            return nil
        }
        let font = CTFontCreateWithName(family as CFString, size, nil)
        guard let resolved = CTFontCopyName(font, kCTFontFamilyNameKey) as String? else {
            return nil
        }
        guard resolved.compare(family, options: [.caseInsensitive]) == .orderedSame else {
            return nil
        }
        return font
    }

    /// One representative code point from each block the symbol fallback answers.
    ///
    /// A dedicated symbol or math face covers all five; a text face covers some
    /// and misses others, and a dingbat face covers almost none. Coverage of the
    /// whole set is the line, because no single code point separates the two —
    /// the common blocks are in most text faces, and the rare ones are missing
    /// from faces worth offering.
    private static let symbolProbeCodePoints: [UInt32] = [
        0x2318, // `U+2318 PLACE OF INTEREST SIGN`
        0x2502, // `U+2502 BOX DRAWINGS LIGHT VERTICAL`
        0x25CF, // `U+25CF BLACK CIRCLE`
        0x2211, // `U+2211 N-ARY SUMMATION`
        0x2192, // `U+2192 RIGHTWARDS ARROW`
    ]

    /// Whether `family` is worth offering as the symbol fallback.
    ///
    /// Advance is not consulted. The faces a user reaches for here
    /// — Apple Symbols, STIX Two Math — are proportional, and a monospace trait
    /// filter excludes every one of them while admitting text faces that answer
    /// no more symbols than the primary already does.
    ///
    /// - Parameter family: The installed family name to probe.
    /// - Returns: True when the family covers every probe block.
    @objc(familyCoversSymbolBlocks:)
    static func familyCoversSymbolBlocks(_ family: String?) -> Bool {
        // copyFont refuses a name CoreText substitutes for, so a family that is
        // not installed cannot pass on the substitute's coverage.
        guard let font = copyFont(forFamily: family, size: 14.0) else {
            return false
        }
        return symbolProbeCodePoints.allSatisfy { hasGlyph($0, in: font) }
    }

    /// One representative code point from each block only a pictograph face
    /// answers.
    ///
    /// Both sit outside the BMP, in blocks no text face carries, which is what
    /// separates an emoji face from a symbol face: a symbol face covers arrows
    /// and technical marks and none of these.
    private static let emojiProbeCodePoints: [UInt32] = [
        0x1F600, // Emoticons: GRINNING FACE
        0x1F680, // Transport and Map Symbols: ROCKET
    ]

    /// Whether `family` is worth offering as the emoji fallback.
    ///
    /// A monochrome pictograph face passes, because drawing emoji as outlines is
    /// a choice a person is entitled to make; colour is not the test, coverage is.
    ///
    /// - Parameter family: The installed family name to probe.
    /// - Returns: True when the family covers every probe block.
    @objc(familyCoversEmoji:)
    static func familyCoversEmoji(_ family: String?) -> Bool {
        guard let font = copyFont(forFamily: family, size: 14.0) else {
            return false
        }
        return emojiProbeCodePoints.allSatisfy { hasGlyph($0, in: font) }
    }

    /// Whether `family` is a fixed-pitch family worth offering as the primary.
    ///
    /// The `kCTFontTraitMonoSpace` bit is not consulted. It is wrong in both
    /// directions: `Noto Sans Mono`'s variable build and `Monaspace Neon`
    /// report `0` on their default instances while every printable-ASCII
    /// advance is identical, and a proportional face that sets the bit would
    /// be admitted on its word. Advance uniformity over printable ASCII is the
    /// grid's own definition, and Core's `isMonospace` is the one place it is
    /// spelled.
    ///
    /// - Parameter family: The installed family name to probe.
    /// - Returns: True when every printable-ASCII glyph is present and
    ///   advances by one width.
    @objc(familyIsMonospace:)
    static func familyIsMonospace(_ family: String?) -> Bool {
        // `copyFont` refuses a name CoreText substitutes for, so a family that
        // is not installed cannot pass on the substitute's metrics.
        guard let font = copyFont(forFamily: family, size: 14.0) else {
            return false
        }
        return advancesAreUniform(in: font)
    }

    /// Whether `font` advances every `printable-ASCII` glyph by the same width.
    ///
    /// One probe over `0x20...0x7E` — the range `FontMetrics` sizes the cell
    /// from. A missing glyph is handed to Core as `0`, which refuses the face.
    private static func advancesAreUniform(in font: CTFont) -> Bool {
        let first = UInt16(Ubiquitty.Rendering.FontMetrics.firstProbeCharacter.value)
        let count = Int(Ubiquitty.Rendering.FontMetrics.probeCharacterCount)
        let characters = (0..<count).map { first + UInt16($0) }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        _ = CTFontGetGlyphsForCharacters(font, characters, &glyphs, count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, count)
        var doubles = [Double](repeating: 0, count: count)
        for index in 0..<count {
            doubles[index] = glyphs[index] != 0 ? Double(advances[index].width) : 0
        }
        return doubles.withUnsafeBufferPointer {
            Ubiquitty.Rendering.FontMetrics.isMonospace(Ubiquitty.Rendering.FontMetrics.AdvanceSpan($0))
        }
    }

    /// Whether `family` has renderable programming ligatures.
    ///
    /// The verdict is the renderer's own: Core's classification session,
    /// driven by the same CoreText shaper the strips rasterise with, so the
    /// menu grouping and what draws cannot disagree about a face. A second
    /// probe here once turned every candidate feature off at once where Core
    /// turns them off one at a time, and a face whose `calt` and `liga`
    /// duplicate the same ligature answered differently in the two places.
    ///
    /// - Parameter family: The installed family name to probe.
    /// - Returns: True when the family's default face ligates.
    @objc(familySupportsLigatures:)
    static func familySupportsLigatures(_ family: String?) -> Bool {
        guard let font = copyFont(forFamily: family, size: 14.0) else {
            return false
        }
        return LigatureFeatureClassifier.classify(font).doesLigate
    }

    /// Whether `family` covers the CJK blocks a fallback is worth offering for.
    ///
    /// One representative from each of Han, Hiragana, Katakana and Hangul.
    /// Any one suffices, because a CJK face that covers Kanji but not Hangul
    /// is still worth offering for Han.
    @objc(familySupportsCJK:)
    static func familySupportsCJK(_ family: String?) -> Bool {
        guard let font = copyFont(forFamily: family, size: 14.0) else {
            return false
        }
        let probes: [UInt32] = [0x6570, 0x5B57, 0x3042, 0x30A2, 0xAC00]
        return probes.contains { hasGlyph($0, in: font) }
    }

    @objc(languageForCJKPreference:)
    static func language(forCJKPreference preference: String?) -> String? {
        let token = normalizedPolicyToken(preference)
        if token.isEmpty || token == "auto" || token == "system" {
            return nil
        }
        if token == "zh-hans" || token == "zh_cn" || token == "zh-cn"
            || token == "sc" || token == "simplified" || token == "chinese"
        {
            return "zh-Hans"
        }
        if token == "zh-hant" || token == "zh_tw" || token == "zh-tw"
            || token == "tc" || token == "traditional"
        {
            return "zh-Hant"
        }
        if token == "ja" || token == "jp" || token == "japanese" {
            return "ja"
        }
        if token == "ko" || token == "kr" || token == "korean" {
            return "ko"
        }
        return nil
    }

    @objc(isCJKPolicyToken:)
    static func isCJKPolicyToken(_ preference: String?) -> Bool {
        let token = normalizedPolicyToken(preference)
        return token.isEmpty || token == "auto" || token == "system"
            || language(forCJKPreference: preference) != nil
    }

    @objc(copyLanguageFallbackFontForCodePoint:baseFont:language:)
    static func copyLanguageFallbackFont(forCodePoint codePoint: UInt32, baseFont: CTFont, language: String?) -> CTFont? {
        guard let language, !language.isEmpty, let scalar = UnicodeScalar(codePoint) else {
            return nil
        }
        let string = String(scalar) as CFString
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: baseFont,
            kCTLanguageAttributeName: language,
        ]
        let attributed = CFAttributedStringCreate(nil, string, attributes as CFDictionary)
        guard let attributed else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as NSArray
        guard runs.count > 0 else {
            return nil
        }
        let run = runs[0] as! CTRun
        guard CTRunGetGlyphCount(run) > 0 else {
            return nil
        }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph)
        guard glyph != 0 else {
            return nil
        }
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        return runAttributes[kCTFontAttributeName] as! CTFont?
    }

    @objc(copyCascadeFontForCodePoint:baseFont:)
    static func copyCascadeFont(forCodePoint codePoint: UInt32, baseFont: CTFont) -> CTFont? {
        guard let scalar = UnicodeScalar(codePoint) else {
            return nil
        }
        let string = String(scalar) as CFString
        return CTFontCreateForString(baseFont, string, CFRangeMake(0, CFStringGetLength(string)))
    }

    @objc(copyFallbackFontForCodePoint:baseFont:symbolFont:cjkFont:hanLanguage:)
    static func copyFallbackFont(
        forCodePoint codePoint: UInt32,
        baseFont: CTFont,
        symbolFont: CTFont?,
        cjkFont: CTFont?,
        hanLanguage: String?
    ) -> CTFont? {
        let unifiedHan = isUnifiedHan(codePoint)
        if unifiedHan, hasGlyph(codePoint, in: cjkFont) {
            return cjkFont
        }
        if unifiedHan, let hanLanguage, !hanLanguage.isEmpty,
            let languageFont = copyLanguageFallbackFont(
                forCodePoint: codePoint,
                baseFont: baseFont,
                language: hanLanguage
            ),
            hasGlyph(codePoint, in: languageFont)
        {
            return languageFont
        }
        if hasGlyph(codePoint, in: symbolFont) {
            return symbolFont
        }
        if let cascadeFont = copyCascadeFont(forCodePoint: codePoint, baseFont: baseFont),
            hasGlyph(codePoint, in: cascadeFont)
        {
            return cascadeFont
        }
        return nil
    }

    private static func normalizedPolicyToken(_ preference: String?) -> String {
        (preference ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isUnifiedHan(_ codePoint: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(codePoint)
            || (0x4E00...0x9FFF).contains(codePoint)
            || (0xF900...0xFAFF).contains(codePoint)
            || (0x20000...0x2A6DF).contains(codePoint)
            || (0x2A700...0x2B73F).contains(codePoint)
            || (0x2B740...0x2B81F).contains(codePoint)
            || (0x2B820...0x2CEAF).contains(codePoint)
            || (0x2CEB0...0x2EBEF).contains(codePoint)
            || (0x30000...0x323AF).contains(codePoint)
    }

    /// The UTF-16 units of `codePoint`, or nil when it names no scalar.
    ///
    /// Never an EMPTY array: a scalar that exists encodes as one unit inside the
    /// BMP and two above it, and the values that encode as neither — surrogates
    /// and anything past U+10FFFF — fail `UnicodeScalar.init` and return nil
    /// here. Three things in `hasGlyph` rest on that: two `baseAddress!`
    /// unwraps, which trap on an empty buffer, and a `glyphBuffer[0]` read.
    ///
    /// - Parameter codePoint: The scalar value to encode.
    /// - Returns: One or two UTF-16 units, or nil when `codePoint` names no scalar.
    private static func utf16Units(for codePoint: UInt32) -> [UniChar]? {
        guard let scalar = UnicodeScalar(codePoint) else {
            return nil
        }
        return Array(String(scalar).utf16)
    }

    private static func hasGlyph(_ codePoint: UInt32, in font: CTFont?) -> Bool {
        guard let font, let units = utf16Units(for: codePoint) else {
            return false
        }
        var glyphs = Array(repeating: CGGlyph(), count: units.count)
        return units.withUnsafeBufferPointer { unitBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                let mapped = CTFontGetGlyphsForCharacters(
                    font,
                    unitBuffer.baseAddress!,
                    glyphBuffer.baseAddress!,
                    units.count
                )
                return mapped && glyphBuffer[0] != 0
            }
        }
    }
}
