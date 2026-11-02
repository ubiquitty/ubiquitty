// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-font-catalogue.swift — runs the Swift font catalogue against CoreText.
//
// The catalogue fills `Rendering::Font::FontInventoryTable`, which Core calls
// through C function pointers. This drives those pointers the way Core does, so
// what is exercised is the seam rather than the Swift beneath it: a table whose
// entries are wired to the wrong member, or whose handles do not survive a round
// trip, fails here and compiles perfectly.
//
// Outside the app because the catalogue needs no Metal device, no window and no
// terminal — CoreText and a header-only Core type are the whole dependency. That
// keeps the check runnable in a second rather than behind an app build, which is
// what makes it worth running per commit.
//
// The cascade case is the one that cannot be faked: Menlo has no CJK, so the
// answer has to come from the system's fallback chain rather than from anything
// this file arranges.

import CoreText
import Foundation
import UbiquittyCore

@main
enum FontCatalogueDriver {
    /// Runs every check and exits non-zero if any failed.
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            print("drive-font-catalogue: expected the bundled font directory")
            exit(2)
        }
        // Drive the table through its C function pointers, the way Core does.
        let faces = FontFaces(family: "Menlo", size: 24.0, pixelsPerPoint: 1)!
        let catalogue = FontCatalogue(primary: faces)
        defer { withExtendedLifetime(catalogue) {} }
        let table = catalogue.inventoryTable()

        var failures = 0
        // Local so a failure names the check rather than a line number.
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ok   \(label) \(detail)")
            } else {
                failures += 1
                print("  FAIL \(label) \(detail)")
            }
        }

        func nameString(_ view: std.string_view) -> String {
            guard let data = view.__dataUnsafe() else { return "" }
            return String(cString: data)
        }

        let styles: [Ubiquitty.Rendering.Font.FontStyle] = [.Regular, .Bold, .Italic, .BoldItalic]
        for style in styles {
            "Helvetica"
                .withCString { name in
                    var request = Ubiquitty.Rendering.Font.FontFamilyRequest()
                    request.family = std.string_view(name)
                    request.style = style
                    let handle = table.validateFamily(table.context, &request)
                    let repeated = table.validateFamily(table.context, &request)
                    guard let font = catalogue.resolvedFont(for: handle) else {
                        check("styled fallback resolves", false, "\(style)")
                        return
                    }
                    let traits = CTFontGetSymbolicTraits(font)
                    check(
                        "fallback keeps requested bold and italic style",
                        traits.contains(.traitBold) == (style == .Bold || style == .BoldItalic)
                            && traits.contains(.traitItalic) == (style == .Italic || style == .BoldItalic),
                        "\(style) -> \(CTFontCopyPostScriptName(font))"
                    )
                    check("fallback style lookup reuses its font handle", repeated.value == handle.value, "\(style)")
                    check("fallback keeps the primary's point size", CTFontGetSize(font) == faces.size, "\(style)")
                }
        }
        let variableURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("MonaspaceNeonVar.ttf")
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(variableURL as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first
        {
            let variable = CTFontCreateWithFontDescriptor(descriptor, faces.size, nil)
            catalogue.adoptFallbackFace(variable)
            let family = CTFontCopyFamilyName(variable) as String
            let axis = NSNumber(value: UInt32(Ubiquitty.Rendering.variationAxisTagWeight))
            for weight: UInt8 in [1, 3, 7, 1] {
                for style in styles {
                    family.withCString { name in
                        var request = Ubiquitty.Rendering.Font.FontFamilyRequest()
                        request.family = std.string_view(name)
                        request.style = style
                        request.variableWeight = weight
                        let handle = table.validateFamily(table.context, &request)
                        guard let font = catalogue.resolvedFont(for: handle) else {
                            check("variable fallback resolves", false, "")
                            return
                        }
                        let coordinates = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
                        let weightAxis = (CTFontCopyVariationAxes(font) as? [[String: Any]])?
                            .first {
                                ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber) == axis
                            }
                        let defaultWeight = (weightAxis?[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue
                        let actualWeight = coordinates?[axis]?.doubleValue ?? defaultWeight
                        let expectedWeight = Double(Ubiquitty.Rendering.Font.variationWeightForSGR(weight))
                        let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic) || CTFontGetMatrix(font).c != 0
                        check(
                            "fallback SGR weight preserves italic and supersedes bold",
                            actualWeight == expectedWeight && italic == (style == .Italic || style == .BoldItalic),
                            "\(style), \(weight) -> \(actualWeight ?? -1)"
                        )
                    }
                }
            }
        } else {
            check("variable fallback fixture loads", false, variableURL.path)
        }

        check("isComplete", Ubiquitty.Rendering.Font.isComplete(table))

        let regular = table.primaryFont(table.context, .Regular, 0)
        check("primaryFont mints a valid handle", regular.value != 0, "value=\(regular.value) gen=\(regular.generation)")

        let bold = table.primaryFont(table.context, .Bold, 0)
        check("bold is a distinct face", bold.value != regular.value, "regular=\(regular.value) bold=\(bold.value)")

        let again = table.primaryFont(table.context, .Regular, 0)
        check("interning is stable", again.value == regular.value, "\(again.value) == \(regular.value)")

        let A = table.glyphForCodePoint(table.context, regular, 0x41)
        check("Menlo has 'A'", A.present && A.glyph.value != 0, "glyph=\(A.glyph.value)")

        let missing = table.glyphForCodePoint(table.context, regular, 0x4E2D)
        check("Menlo lacks U+4E2D", !missing.present, "present=\(missing.present)")

        let family = table.familyName(table.context, regular)
        let name = nameString(family)
        check("familyName round-trips", name == "Menlo", "got '\(name)'")
        let postScript = table.postScriptName(table.context, regular)
        let postScriptName = nameString(postScript)

        // Interning grows both arrays while Core retains views of earlier names.
        for size in 25...160 {
            catalogue.adoptFallbackFace(CTFontCreateWithName("Menlo" as CFString, CGFloat(size), nil))
        }
        check("family view survives catalogue growth", nameString(family) == name)
        check("PostScript view survives catalogue growth", nameString(postScript) == postScriptName)

        check(
            "invalid handle names nothing",
            table.familyName(
                table.context,
                Ubiquitty.Rendering.Font.FontHandle()
            )
            .size() == 0
        )

        let gen0 = table.catalogGeneration(table.context)
        table.bumpCatalogGeneration(table.context)
        check("bump advances the generation", table.catalogGeneration(table.context) == gen0 + 1)
        check("stale handles have no face", catalogue.resolvedFont(for: regular) == nil)
        check("stale handles have no glyph", !table.glyphForCodePoint(table.context, regular, 0x41).present)
        check("stale family name is empty", table.familyName(table.context, regular).empty())
        check("stale PostScript name is empty", table.postScriptName(table.context, regular).empty())
        let freshRegular = table.primaryFont(table.context, .Regular, 0)
        check(
            "new primary uses the current generation",
            freshRegular.generation == table.catalogGeneration(table.context) && freshRegular.value == regular.value
        )
        check("new primary still resolves", table.glyphForCodePoint(table.context, freshRegular, 0x41).present)

        var request = Ubiquitty.Rendering.Font.CascadeRequest()
        request.baseFont = regular
        let han: [UInt32] = [0x4E2D]
        han.withUnsafeBufferPointer { buffer in
            request.codePoints = .init(buffer)
            check("stale cascade base is rejected", !table.cascadeForCodePoint(table.context, &request).present)
            request.baseFont = freshRegular
            let cascaded = table.cascadeForCodePoint(table.context, &request)
            check(
                "the system cascades U+4E2D",
                cascaded.present && cascaded.font.value != 0,
                "handle=\(cascaded.font.value) glyph=\(cascaded.glyph.value)"
            )
            if cascaded.font.value != 0 {
                let fallback = nameString(table.familyName(table.context, cascaded.font))
                check("cascade left Menlo", fallback != "Menlo", "-> '\(fallback)'")
            }
        }

        let localizedHan: [UInt32] = [0x9AA8]
        let localizedText = "骨" as CFString
        var localizedReferenceNames = Set<String>()
        for language in ["ja", "zh-Hans", "zh-Hant", "ko", "ja-JP", "zh-Hant-TW", "JA", "ja", "zh-Hans"] {
            let expected = CTFontCreateForStringWithLanguage(
                faces[.Regular],
                localizedText,
                CFRangeMake(0, 1),
                language as CFString
            )
            let expectedName = CTFontCopyPostScriptName(expected) as String
            localizedReferenceNames.insert(expectedName)
            localizedHan.withUnsafeBufferPointer { buffer in
                language.withCString { languageBytes in
                    request.codePoints = .init(buffer)
                    request.language = .init(value: std.string_view(languageBytes))
                    let answer = table.cascadeForCodePoint(table.context, &request)
                    let actualName = nameString(table.postScriptName(table.context, answer.font))
                    check(
                        "native Han cascade preserves \(language), including cached answers",
                        answer.present && !answer.lastResort && actualName == expectedName,
                        "got '\(actualName)' expected '\(expectedName)'"
                    )
                }
            }
        }
        check("language controls exercise distinct native Han faces", localizedReferenceNames.count > 1)
        request.language = .init()

        for size: CGFloat in [12, 26, 48] {
            guard let sizedFaces = FontFaces(family: "Menlo", size: size, pixelsPerPoint: 1) else { continue }
            let matched = FontCatalogue(primary: sizedFaces)
            let original = FontCatalogue(primary: sizedFaces, shouldMatchFallbackSize: false)
            for style in styles {
                for codePoint: UInt32 in [0x2426, 0x2400, 0x1D11E] {
                    let points = [codePoint]
                    for catalogue in [matched, original] {
                        let inventory = catalogue.inventoryTable()
                        let primary = inventory.primaryFont(inventory.context, style, 0)
                        guard let primaryFont = catalogue.resolvedFont(for: primary) else { continue }
                        points.withUnsafeBufferPointer { buffer in
                            var request = Ubiquitty.Rendering.Font.CascadeRequest()
                            request.baseFont = primary
                            request.codePoints = .init(buffer)
                            request.presentation = .Text
                            let answer = inventory.cascadeForCodePoint(inventory.context, &request)
                            guard let fallback = catalogue.resolvedFont(for: answer.font) else {
                                check("fallback text resolves", false, "U+\(String(codePoint, radix: 16))")
                                return
                            }
                            let detail = "U+\(String(codePoint, radix: 16)) size=\(size) style=\(style)"
                            if catalogue === matched {
                                check(
                                    "native fallback matches primary x-height",
                                    abs(CTFontGetXHeight(fallback) - CTFontGetXHeight(primaryFont)) < 0.02,
                                    detail
                                )
                            } else {
                                check("disabled matching retains nominal size", abs(CTFontGetSize(fallback) - size) < 0.02, detail)
                            }
                            let cached = inventory.cascadeForCodePoint(inventory.context, &request)
                            check("matched cascade retains its cached handle", cached.font.value == answer.font.value, detail)
                        }
                    }
                }
            }
        }

        // A range can opt into matching while the default is off, and both
        // sizes of one family keep independent cached handles.
        if let rangeFaces = FontFaces(family: "Menlo", size: 26, pixelsPerPoint: 1) {
            let catalogue = FontCatalogue(primary: rangeFaces, shouldMatchFallbackSize: false)
            let inventory = catalogue.inventoryTable()
            let primary = inventory.primaryFont(inventory.context, .Regular, 0)
            "Apple Symbols"
                .withCString { family in
                    var request = Ubiquitty.Rendering.Font.FontFamilyRequest()
                    request.family = std.string_view(family)
                    request.sizingBase = primary
                    request.sizing = .MatchPrimary
                    let matched = inventory.validateFamily(inventory.context, &request)
                    request.sizing = .Nominal
                    let nominal = inventory.validateFamily(inventory.context, &request)
                    check(
                        "range size choices have distinct handles",
                        matched.isValid() && nominal.isValid() && matched.value != nominal.value
                    )
                    if let matchedFont = catalogue.resolvedFont(for: matched),
                        let nominalFont = catalogue.resolvedFont(for: nominal),
                        let primaryFont = catalogue.resolvedFont(for: primary)
                    {
                        check(
                            "range matches when the default is off",
                            abs(CTFontGetXHeight(matchedFont) - CTFontGetXHeight(primaryFont)) < 0.02
                        )
                        check("range keeps original size", abs(CTFontGetSize(nominalFont) - 26) < 0.02)
                    }
                    request.sizing = .MatchPrimary
                    check(
                        "range size choice survives cache reuse",
                        inventory.validateFamily(inventory.context, &request).value == matched.value
                    )
                }
        }

        let heart: [UInt32] = [0x2764, 0xFE0F]
        var clusterRequest = Ubiquitty.Rendering.Font.ClusterProbeRequest()
        clusterRequest.font = freshRegular
        heart.withUnsafeBufferPointer { buffer in
            clusterRequest.codePoints = .init(buffer)
            clusterRequest.presentation = .Emoji
            check("primary covers the emoji cluster's lead", table.glyphForCodePoint(table.context, freshRegular, heart[0]).present)
            check(
                "primary does not claim a color cluster through substitution",
                !table.glyphForCluster(table.context, &clusterRequest).present
            )
        }
        let textHeart: [UInt32] = [0x2764, 0xFE0E]
        textHeart.withUnsafeBufferPointer { buffer in
            clusterRequest.codePoints = .init(buffer)
            clusterRequest.presentation = .Text
            check("primary covers the explicit text cluster", table.glyphForCluster(table.context, &clusterRequest).present)
            clusterRequest.font = regular
            check("cluster probe rejects stale handles", !table.glyphForCluster(table.context, &clusterRequest).present)
        }
        let bareHeart: [UInt32] = [0x2764]
        for presentation in [Ubiquitty.Rendering.Font.Presentation.Emoji, .Text, .Emoji, .Text] {
            bareHeart.withUnsafeBufferPointer { buffer in
                request.codePoints = .init(buffer)
                request.presentation = presentation
                let answer = table.cascadeForCodePoint(table.context, &request)
                let selected = catalogue.resolvedFont(for: answer.font)
                let color = selected.map { CTFontGetSymbolicTraits($0).contains(.traitColorGlyphs) }
                check(
                    "native cascade preserves presentation, including cached answers",
                    answer.present && !answer.lastResort && color == (presentation == .Emoji),
                    "\(presentation) -> \(selected.map { CTFontCopyFamilyName($0) as String } ?? "missing")"
                )
            }
        }

        catalogue.prepareNativeTextCoverage()
        let nativeBeforeMissing = catalogue.nativeCascadeQueryCount
        let rejectsBeforeMissing = catalogue.nativeCoverageRejectCount
        let absentPoints: [UInt32] = [0x10FFFF]
        absentPoints.withUnsafeBufferPointer { points in
            var request = Ubiquitty.Rendering.Font.CascadeRequest()
            request.baseFont = freshRegular
            request.codePoints = Ubiquitty.Rendering.Font.CodePointSpan(points)
            request.presentation = .Text
            let answer = table.cascadeForCodePoint(table.context, &request)
            check("native coverage rejects an unsupported scalar", !answer.present)
        }
        check(
            "unsupported scalar bypasses native fallback search",
            catalogue.nativeCascadeQueryCount == nativeBeforeMissing && catalogue.nativeCoverageRejectCount == rejectsBeforeMissing + 1
        )
        let supportedPoints: [UInt32] = [0x4E2D]
        supportedPoints.withUnsafeBufferPointer { points in
            var request = Ubiquitty.Rendering.Font.CascadeRequest()
            request.baseFont = freshRegular
            request.codePoints = Ubiquitty.Rendering.Font.CodePointSpan(points)
            request.presentation = .Text
            let answer = table.cascadeForCodePoint(table.context, &request)
            check("native coverage keeps supported Han fallback", answer.present)
        }

        // A family nothing carries is a missing font, not a proportional one.
        //
        // CTFontCreateWithName substitutes rather than failing, and what it
        // substitutes is the system's proportional face. Unchecked, a reader
        // who names a font this machine does not have gets proportional
        // letters on the grid, and a snapshot case that names one mints a
        // golden of that: a family in the macOS font library and not in the
        // iOS bundle draws the iOS arm's plate in a face other than the one
        // the case names.
        //
        // Both halves are asserted. Without the second, a fallback that fired
        // for every family would pass the first.
        let unknownFamily = FontFaces(family: "No Such Family At All", size: 24.0, pixelsPerPoint: 1)
        check("a missing family still builds faces", unknownFamily != nil)
        if let unknownFamily {
            let traits = CTFontGetSymbolicTraits(unknownFamily[Ubiquitty.Rendering.FontFace.Regular])
            check(
                "a missing family falls back to a monospaced face",
                traits.contains(CTFontSymbolicTraits.traitMonoSpace),
                "-> '\(CTFontCopyFamilyName(unknownFamily[Ubiquitty.Rendering.FontFace.Regular]) as String)'"
            )
        }
        let present = FontFaces(family: "Menlo", size: 24.0, pixelsPerPoint: 1)
        if let present {
            let resolved = CTFontCopyFamilyName(present[Ubiquitty.Rendering.FontFace.Regular]) as String
            check("a family that exists is not diverted", resolved == "Menlo", "-> '\(resolved)'")
        }

        print(failures == 0 ? "drive-font-catalogue: ok" : "drive-font-catalogue: FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
