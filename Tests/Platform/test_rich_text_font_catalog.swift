// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation

@main
struct RichTextFontCatalogTests {
    static func main() {
        let catalog = RichTextFontCatalog()
        precondition(!catalog.families.isEmpty)
        precondition(Set(catalog.families).count == catalog.families.count)
        precondition(catalog.families == catalog.families.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        let advertised = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        for family in catalog.families {
            precondition(advertised.contains(family))
            for style in 0...3 {
                guard let font = catalog.font(family: family, isBold: style & 1 != 0, isItalic: style & 2 != 0, size: 19) else {
                    preconditionFailure("An enumerated family could not be resolved: \(family)")
                }
                precondition((CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame)
                precondition(CTFontGetSize(font) == 19)
            }
        }
        precondition(catalog.font(family: "Ubiquitty nonexistent family 7bd20", isBold: true, isItalic: true, size: 19) == nil)
        let family = "Helvetica Neue"
        let members = ["HelveticaNeue", "HelveticaNeue-Bold", "HelveticaNeue-Italic", "HelveticaNeue-BoldItalic"]
        precondition(catalog.families.contains(family))
        for style in 0...3 {
            let font = catalog.font(family: family, isBold: style & 1 != 0, isItalic: style & 2 != 0, size: 19)!
            precondition((CTFontCopyPostScriptName(font) as String) == members[style])
        }
        let regular = catalog.font(family: family, isBold: false, isItalic: false, size: 12)!
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let slanted = CTFontCreateCopyWithAttributes(regular, 12, &shear, nil)
        let captured = RichTextFontCatalog(additionalFamilies: [[regular, regular, slanted, slanted]])
        for style in 0...3 {
            let font = captured.font(family: family, isBold: style & 1 != 0, isItalic: style & 2 != 0, size: 23)!
            precondition((CTFontCopyPostScriptName(font) as String) == members[0], "Captured style handles must not be rematched")
            precondition(CTFontGetSize(font) == 23)
            precondition(
                CTFontGetMatrix(font) == (style & 2 != 0 ? shear : .identity),
                "Resizing must preserve a captured synthesized style"
            )
        }
        precondition(RichTextFontCatalog.isRepresentable("日本語;{font}\\name"))
        precondition(RichTextFontCatalog.isRepresentable(String(repeating: "é", count: 127) + "a"))
        precondition(!RichTextFontCatalog.isRepresentable(String(repeating: "é", count: 128)))
        for name in ["", " leading", "trailing ", "control\n", "control\u{7F}", "control\u{85}"] {
            precondition(!RichTextFontCatalog.isRepresentable(name))
        }
        print(
            "rich-text-font-catalog: \(catalog.families.count) real families, all four styles, unavailable names and UTF-8 boundaries pass"
        )
    }
}
