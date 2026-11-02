// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation

/// Immutable local font handles shared by enumeration and named-family lookup.
/// A renderer rebuild replaces this snapshot after a font-registration change.
struct RichTextFontCatalog {
    let families: [String]
    private let fonts: [String: [CTFont]]

    init(additionalFamilies: [[CTFont]] = []) {
        var fonts: [String: [CTFont]] = [:]
        let available = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        for family in available where Self.isRepresentable(family) {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            // CoreText silently substitutes an unavailable family. Never list
            // that substitution as proof the requested family is installed.
            guard (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame else { continue }
            fonts[family] = Self.styles(of: font)
        }
        for styles in additionalFamilies where styles.count == 4 {
            let family = CTFontCopyFamilyName(styles[0]) as String
            guard Self.isRepresentable(family) else { continue }
            fonts[family] = styles.map { font in
                (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame ? font : styles[0]
            }
        }
        self.fonts = fonts
        families = fonts.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// The wire's one-byte name length bounds complete UTF-8 identifiers.
    static func isRepresentable(_ family: String) -> Bool {
        !family.isEmpty && family.utf8.count <= Int(UInt8.max)
            && family == family.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            && !family.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    func font(family: String, isBold: Bool, isItalic: Bool, size: CGFloat) -> CTFont? {
        guard let styles = fonts[family] else { return nil }
        let source = styles[(isBold ? 1 : 0) | (isItalic ? 2 : 0)]
        return CTFontCreateCopyWithAttributes(source, size, nil, nil)
    }

    /// Resolve styles while building the snapshot, before any parser callback.
    private static func styles(of base: CTFont) -> [CTFont] {
        (0...3)
            .map { style in
                let mask: CTFontSymbolicTraits = [.boldTrait, .italicTrait]
                var traits = CTFontSymbolicTraits()
                if style & 1 != 0 { traits.insert(.boldTrait) }
                if style & 2 != 0 { traits.insert(.italicTrait) }
                guard let styled = CTFontCreateCopyWithSymbolicTraits(base, 12, nil, traits, mask),
                    (CTFontCopyFamilyName(styled) as String) == (CTFontCopyFamilyName(base) as String)
                else { return base }
                return styled
            }
    }
}
