// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RichTextFaces.swift — the faces rich text blocks are measured and drawn in,
// on both Apple shells (Docs/rich-text.md, "The measurement model").
//
// One derivation for both halves of the contract: the typography table Core
// lays a block out by is measured from exactly the faces the block is later
// drawn in, so a glyph lands where Core put it, the highlight sits on it and a
// click names it. A face is measured once at 2048 points, where an advance in
// points is an advance in 1/2048 em, the table's unit.

import CoreText
import UbiquittyCore

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One renderer's font inventory, built when a program first names or queries a family.
///
/// The parser and frame renderer can ask concurrently. The lock publishes one
/// immutable snapshot to both, and a renderer invalidated by font registration
/// receives a new cache with its replacement faces.
private final class RichTextFontCatalogCache: @unchecked Sendable {
    private let additionalFamilies: [[CTFont]]
    private let lock = NSLock()
    private var snapshot: RichTextFontCatalog?

    init(additionalFamilies: [[CTFont]]) {
        self.additionalFamilies = additionalFamilies
    }

    func catalog() -> RichTextFontCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let snapshot { return snapshot }
        let built = RichTextFontCatalog(additionalFamilies: additionalFamilies)
        snapshot = built
        return built
    }

    var hasBuiltSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot != nil
    }
}

/// The faces a rich text block is set in.
package struct RichTextFaces {
    /// The grid's own upright face.
    package let grid: CTFont
    /// The grid's four faces in FontFace order, which the monospace class's
    /// styles are: the grid's own bold and italics, never a family match that
    /// could answer with a copy of the family the machine has installed.
    private let gridStyles: [CTFont]
    private let sansStyles: [CTFont]
    private let serifStyles: [CTFont]
    /// The configured proportional family, or empty for the platform's UI face.
    package let proportionalFamilyName: String
    private let catalogCache: RichTextFontCatalogCache
    var catalog: RichTextFontCatalog { catalogCache.catalog() }
    package var hasBuiltCatalog: Bool { catalogCache.hasBuiltSnapshot }

    package init(grid: FontFaces, proportionalFamilyName: String) {
        self.grid = grid[Ubiquitty.Rendering.FontFace.Regular]
        self.gridStyles = [
            grid[Ubiquitty.Rendering.FontFace.Regular],
            grid[Ubiquitty.Rendering.FontFace.Bold],
            grid[Ubiquitty.Rendering.FontFace.Italic],
            grid[Ubiquitty.Rendering.FontFace.BoldItalic],
        ]
        self.proportionalFamilyName = proportionalFamilyName
        var bundledStyles: [String: [CTFont]] = [:]
        for family in Ubiquitty.Rendering.bundledFontFamilies() {
            let name = String(family)
            if let styles = FontFaces.shippedStyles(family: name, size: 12) { bundledStyles[name] = styles }
        }
        if let shipped = bundledStyles[proportionalFamilyName.trimmingCharacters(in: .whitespaces)] {
            sansStyles = shipped
        } else {
            let base =
                LigatureSheet.namedProportionalFace(proportionalFamilyName, pointSize: 12)
                ?? CTFontCreateUIFontForLanguage(.system, 12, nil)
                ?? CTFontCreateCopyWithAttributes(self.grid, 12, nil, nil)
            sansStyles = Self.classStyles(of: base)
        }
        serifStyles = Self.classStyles(of: Self.serifFace(size: 12))
        catalogCache = RichTextFontCatalogCache(
            additionalFamilies: [gridStyles, sansStyles, serifStyles] + Array(bundledStyles.values)
        )
    }

    /// Resolves a source family in the same snapshot its font query enumerates.
    package func font(
        _ familyClass: Ubiquitty.RichText.FamilyClass,
        familyName: String,
        isBold: Bool,
        isItalic: Bool,
        size: CGFloat
    ) -> CTFont {
        if !familyName.isEmpty {
            if let named = catalog.font(family: familyName, isBold: isBold, isItalic: isItalic, size: size) {
                return named
            }
        }
        return font(familyClass, isBold: isBold, isItalic: isItalic, size: size)
    }

    /// The face a class names in a style, at an em size.
    ///
    /// - Parameters:
    ///   - familyClass: The class.
    ///   - isBold: Whether the face is the bold one.
    ///   - isItalic: Whether the face is the italic one.
    ///   - size: The em size, in the units the caller draws in.
    /// - Returns: The face; the upright regular one when the family has no
    ///   face in the style asked for.
    package func font(_ familyClass: Ubiquitty.RichText.FamilyClass, isBold: Bool, isItalic: Bool, size: CGFloat) -> CTFont {
        let styles: [CTFont]
        switch familyClass {
        case .Monospace:
            styles = gridStyles
        case .Serif:
            styles = serifStyles
        default:
            styles = sansStyles
        }
        let source = styles[Int(Ubiquitty.Rendering.fontFace(isBold, isItalic).rawValue) & 0x3]
        if familyClass == .Monospace {
            var identity = CGAffineTransform.identity
            return CTFontCreateCopyWithAttributes(source, size, &identity, nil)
        }
        return CTFontCreateCopyWithAttributes(source, size, nil, nil)
    }

    /// Preserve each class's native style policy in immutable handles. Font
    /// matching and bundled-file reads occur only during renderer construction.
    private static func classStyles(of base: CTFont) -> [CTFont] {
        (0...3)
            .map { style in
                guard style != 0 else { return base }
                var traits = CTFontSymbolicTraits()
                if style & 1 != 0 { traits.insert(.boldTrait) }
                if style & 2 != 0 { traits.insert(.italicTrait) }
                var identity = CGAffineTransform.identity
                return CTFontCreateCopyWithSymbolicTraits(base, 12, &identity, traits, traits) ?? base
            }
    }

    /// The table Core lays rich text out by: the cell, and the three class
    /// faces in their four styles.
    ///
    /// - Parameters:
    ///   - cellWidthInPoints: The grid's cell width.
    ///   - cellHeightInPoints: The grid's cell height.
    ///   - baselineInPoints: The grid's baseline below the row top.
    ///   - proportionalSizeInPoints: The zoomed proportional em size.
    ///   - monospaceSizeInPoints: The zoomed grid font's em size.
    /// - Returns: The filled table.
    // swift-only: the generated C++ header drops this package helper, and only Swift callers build the table through it
    package func typographyFacts(
        cellWidthInPoints: Double,
        cellHeightInPoints: Double,
        baselineInPoints: Double,
        proportionalSizeInPoints: Double,
        monospaceSizeInPoints: Double
    ) -> Ubiquitty.RichText.TypographyFactsBuilder {
        var builder = Ubiquitty.RichText.TypographyFactsBuilder()
        builder.setCell(Self.inSixtyFourths(cellWidthInPoints), Self.inSixtyFourths(cellHeightInPoints))
        builder.setTerminalMetrics(
            Self.inSixtyFourths(baselineInPoints),
            Self.inSixtyFourths(proportionalSizeInPoints),
            Self.inSixtyFourths(monospaceSizeInPoints)
        )
        builder.setShaping(1)
        builder.setRendering(1)
        builder.setFontCatalogScope(Ubiquitty.RichText.FontCatalogScope.System.rawValue)
        let emSize = CGFloat(Ubiquitty.RichText.unitsPerEm)
        let classes: [Ubiquitty.RichText.FamilyClass] = [.SansSerif, .Serif, .Monospace]
        for familyClass in classes {
            for styles: UInt8 in 0...3 {
                let face = font(familyClass, isBold: styles & 1 != 0, isItalic: styles & 2 != 0, size: emSize)
                Self.measure(face, as: familyClass, styles: styles, into: &builder)
            }
        }
        return builder
    }

    /// The platform's serif text face: the system face's serif design, New
    /// York, whose vertical proportions are the sans-serif class face's, so a
    /// serif run at the primary em sets at the same cap height.
    ///
    /// The design is reached through the system descriptor because its family
    /// is published under a hidden, dot-prefixed name that a lookup by family
    /// never matches; such a lookup lands on Times New Roman, whose caps are 6%
    /// and lowercase 12% shorter at the same em.
    private static func serifFace(size: CGFloat) -> CTFont {
        #if canImport(AppKit)
        if let design = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif),
            let face = NSFont(descriptor: design, size: size)
        {
            return face as CTFont
        }
        #elseif canImport(UIKit)
        if let design = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: design, size: size) as CTFont
        }
        #endif
        for family in ["Times New Roman", "Times"] {
            if let face = LigatureSheet.namedProportionalFace(family, pointSize: size) {
                return face
            }
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Times" as CFString, size, nil)
    }

    /// One face's metrics and the advances of the tabled range, in 1/2048 em.
    private static func measure(
        _ face: CTFont,
        as familyClass: Ubiquitty.RichText.FamilyClass,
        styles: UInt8,
        into builder: inout Ubiquitty.RichText.TypographyFactsBuilder
    ) {
        let ascent = CTFontGetAscent(face)
        let descent = CTFontGetDescent(face)
        let lineHeight = ascent + descent + CTFontGetLeading(face)
        let first = Ubiquitty.RichText.firstTabledCodePoint
        let last = Ubiquitty.RichText.lastTabledCodePoint
        var advances = [UInt16](repeating: 0, count: Int(last - first + 1))
        var characters = [UInt16](repeating: 0, count: advances.count)
        for index in 0..<characters.count {
            characters[index] = UInt16(first + UInt32(index))
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(face, characters, &glyphs, characters.count)
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        _ = CTFontGetAdvancesForGlyphs(face, .horizontal, glyphs, &sizes, glyphs.count)
        for index in 0..<advances.count {
            var advance = sizes[index].width
            // A code point the face lacks is drawn from the face CoreText
            // falls back to, so it is measured there too.
            if glyphs[index] == 0, let scalar = Unicode.Scalar(characters[index]) {
                let fallback = CTFontCreateForString(face, String(Character(scalar)) as CFString, CFRange(location: 0, length: 1))
                var unit = characters[index]
                var glyph = CGGlyph(0)
                if CTFontGetGlyphsForCharacters(fallback, &unit, &glyph, 1) {
                    var fallbackSize = CGSize.zero
                    _ = CTFontGetAdvancesForGlyphs(fallback, .horizontal, &glyph, &fallbackSize, 1)
                    advance = fallbackSize.width
                }
            }
            advances[index] = clamped(advance)
        }
        // The printable ASCII advances' mean, which an estimate takes.
        let ascii = advances[0..<95]
        let average = UInt16(ascii.reduce(0) { $0 + Int($1) } / ascii.count)
        guard builder.addFace(familyClass, styles, clamped(ascent), clamped(descent), clamped(lineHeight), average) else {
            return
        }
        for index in 0..<advances.count {
            builder.setAdvance(first + UInt32(index), advances[index])
        }
    }

    private static func clamped(_ value: CGFloat) -> UInt16 {
        UInt16(max(0, min(CGFloat(UInt16.max), value.rounded())))
    }

    private static func inSixtyFourths(_ points: Double) -> UInt16 {
        UInt16(max(1, min(Double(Ubiquitty.RichText.maxCellSize), (points * 64).rounded())))
    }
}
