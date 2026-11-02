// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ProportionalFacesSmoke.swift — a proportional run under SGR 1 or 3 is set in
// its family's own bold and italic (Docs/proportional-text.md, "The face").
//
// A run carries the grid face's weight and slant, and the face it is set in
// is the platform's UI face or the family `font.proportional_family` names.
// Every style of each is required to be that family's member in the style,
// and the face the rich text table measures as sans-serif in each style to
// be the same member: a host measures a hosted pane's runs from its client's
// published faces, so a style the two derive differently is a run measured in
// one face and drawn in another. Helvetica Neue stands for an installed
// family of static faces, where a bold asked of the regular by weight alone
// stays the regular; every macOS has it.

#if canImport(AppKit)
import AppKit
import CoreText
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The smoke's entry, which the application's entry point dispatches.
public final class ProportionalFacesSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether every style resolved to its family's member.
    public static func run() -> Bool {
        ProportionalFacesSmoke.run()
    }
}

/// The scenario: the UI face and an installed family, in four styles each.
enum ProportionalFacesSmoke {
    /// The installed family the smoke sets runs in, and the PostScript name of
    /// its member in each style, in FontFace order.
    private static let installed: (family: String, members: [String]) = (
        "Helvetica Neue", ["HelveticaNeue", "HelveticaNeue-Bold", "HelveticaNeue-Italic", "HelveticaNeue-BoldItalic"]
    )

    /// - Returns: Whether every style came from its family's member.
    static func run() -> Bool {
        guard let grid = FontFaces(family: "JetBrains Mono", size: 26, pixelsPerPoint: 2) else {
            return failed("no grid faces to size the proportional run by")
        }
        guard LigatureSheet.namedProportionalFace(installed.family, pointSize: 13) != nil else {
            return failed("\(installed.family) is not installed, so the smoke would prove nothing")
        }
        var findings: [String] = []
        let styles: [(Ubiquitty.Rendering.FontFace, String)] = [
            (.Regular, "regular"), (.Bold, "bold"), (.Italic, "italic"), (.BoldItalic, "bold italic"),
        ]
        for family in ["", installed.family] {
            let request = LigatureSheet.ProportionalFaceRequest(familyName: family)
            let richText = RichTextFaces(grid: grid, proportionalFamilyName: family)
            let label = family.isEmpty ? "the UI face" : family
            for (index, style) in styles.enumerated() {
                let isBold = index & 1 != 0
                let isItalic = index & 2 != 0
                let run = LigatureSheet.proportionalFace(sizedLike: grid, request: request, isBold: isBold, isItalic: isItalic)
                let traits = CTFontGetSymbolicTraits(run)
                if traits.contains(.boldTrait) != isBold || traits.contains(.italicTrait) != isItalic {
                    findings.append("\(label) \(style.1): the run is set in \(postScriptName(run))")
                }
                if !family.isEmpty, postScriptName(run) != installed.members[index] {
                    findings.append("\(label) \(style.1): \(postScriptName(run)) — wanted \(installed.members[index])")
                }
                let measured = richText.font(.SansSerif, isBold: isBold, isItalic: isItalic, size: 13)
                if postScriptName(measured) != postScriptName(run) {
                    findings.append(
                        "\(label) \(style.1): the run is drawn in \(postScriptName(run)) and its table measures \(postScriptName(measured))"
                    )
                }
            }
            if richText.hasBuiltCatalog {
                findings.append("class-only faces built the system font catalog")
            }
        }
        let namedFaces = RichTextFaces(grid: grid, proportionalFamilyName: "")
        if namedFaces.hasBuiltCatalog {
            findings.append("unused named faces built the system font catalog")
        }
        var entry = Ubiquitty.RichText.FontEntry()
        entry.familyClass = .Monospace
        entry.nameLength = UInt8(installed.family.utf8.count)
        for (index, byte) in installed.family.utf8.enumerated() { entry.name[index] = CChar(bitPattern: byte) }
        for (index, style) in styles.enumerated() {
            let named = namedFaces.font(
                .Monospace,
                familyName: installed.family,
                isBold: index & 1 != 0,
                isItalic: index & 2 != 0,
                size: 19
            )
            if postScriptName(named) != installed.members[index] {
                findings.append("named rich text \(style.1): \(postScriptName(named)) — wanted \(installed.members[index])")
            }
            var drawn = Ubiquitty.RichText.DrawnStyle()
            drawn.setFont(entry)
            drawn.end = 4
            drawn.styles = UInt8(index)
            drawn.halfPoints = 38
            let typesetter = RichTextTypesetter(
                text: [0x66, 0x69, 0x66, 0x69],
                styles: [drawn],
                faces: namedFaces,
                automaticColor: CGColor(gray: 1, alpha: 1)
            )
            let attributedFont = typesetter.source.attribute(
                NSAttributedString.Key(kCTFontAttributeName as String),
                at: 0,
                effectiveRange: nil
            )
            if let attributedFont, postScriptName(attributedFont as! CTFont) != installed.members[index] {
                findings.append("named rich text \(style.1) lost its family before native typesetting")
            } else if attributedFont == nil {
                findings.append("named rich text \(style.1) has no native font attribute")
            }
        }
        let missing = namedFaces.font(.Monospace, familyName: "Ubiquitty missing family 7bd20", isBold: true, isItalic: true, size: 19)
        let fallback = namedFaces.font(.Monospace, isBold: true, isItalic: true, size: 19)
        if !namedFaces.hasBuiltCatalog {
            findings.append("named font lookup did not build the system font catalog")
        }
        if postScriptName(missing) != postScriptName(fallback) {
            findings.append("an unavailable named family did not use its declared class")
        }
        let shaper = RichTextShaper(faces: namedFaces)
        var query = Ubiquitty.RichText.FontCatalogQuery()
        query.count = 2
        query.rendererRevision = 17
        var page = Ubiquitty.RichText.FontCatalogPage()
        if !shaper.queryFonts(query, into: &page) || page.status != .Ready || page.scope != .System || page.total < 2
            || page.rendererRevision != 17
        {
            findings.append("native font catalog did not return its bounded system snapshot")
        }
        query.offset = page.total + 1
        var invalidPage = Ubiquitty.RichText.FontCatalogPage()
        if !shaper.queryFonts(query, into: &invalidPage) || invalidPage.status != .Invalid || invalidPage.total != 0 {
            findings.append("native font catalog accepted an out-of-range continuation")
        }
        query.offset = 0
        query.count = Ubiquitty.RichText.maxFontCatalogPageFamilies
        var catalogNames = Set<String>()
        repeat {
            var catalogPage = Ubiquitty.RichText.FontCatalogPage()
            guard shaper.queryFonts(query, into: &catalogPage), catalogPage.status == .Ready,
                catalogPage.familyCount() > 0
            else {
                findings.append("native font catalog could not enumerate its full snapshot")
                break
            }
            for index in 0..<Int(catalogPage.familyCount()) { catalogNames.insert(String(catalogPage.familyNameAt(index))) }
            query.offset += UInt32(catalogPage.familyCount())
            if query.offset == catalogPage.total { break }
        } while true
        for family in Ubiquitty.Rendering.bundledFontFamilies() {
            let name = String(family)
            if FontFaces.shippedStyles(family: name, size: 12) != nil, !catalogNames.contains(name) {
                findings.append("the usable bundled family \(name) is missing from the actual catalog reply")
            }
        }

        let box = ProportionalMeasureBox()
        var facts = Ubiquitty.RichText.TypographyFacts()
        facts.rendererRevision = box.adoptRichText(shaper)
        query.offset = 0
        query.count = 1
        query.rendererRevision = facts.rendererRevision
        var firstPage = Ubiquitty.RichText.FontCatalogPage()
        if !box.queryFonts(query, facts: facts, into: &firstPage) || firstPage.status != .Ready {
            findings.append("the active renderer did not answer its own font revision")
        }
        box.invalidateRichText()
        var stalePage = Ubiquitty.RichText.FontCatalogPage()
        if !box.queryFonts(query, facts: facts, into: &stalePage) || stalePage.status != .Stale {
            findings.append("font-registration invalidation left the previous catalog callable")
        }
        facts.rendererRevision = box.adoptRichText(RichTextShaper(faces: namedFaces))
        var retiredPage = Ubiquitty.RichText.FontCatalogPage()
        if query.rendererRevision == facts.rendererRevision
            || !box.queryFonts(query, facts: facts, into: &retiredPage) || retiredPage.status != .Stale
        {
            findings.append("a replacement renderer accepted a retired catalog revision")
        }
        query.rendererRevision = facts.rendererRevision
        var currentPage = Ubiquitty.RichText.FontCatalogPage()
        if !box.queryFonts(query, facts: facts, into: &currentPage) || currentPage.status != .Ready {
            findings.append("a replacement renderer did not answer its current catalog revision")
        }
        guard findings.isEmpty else {
            return failed(findings.joined(separator: "; "))
        }
        print("smoke-proportional-faces: ok (UI, configured and named families in 4 styles, class fallback and real catalog paging)")
        return true
    }

    private static func postScriptName(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("smoke-proportional-faces: FAILED — \(reason)\n".utf8))
        return false
    }
}
#endif
