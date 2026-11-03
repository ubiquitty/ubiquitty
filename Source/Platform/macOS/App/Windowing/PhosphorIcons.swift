// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PhosphorIcons.swift — the icons a tag can wear in place of its dot.
//
// The fonts and the catalog ship with this code (Resources/phosphor, refreshed
// by Scripts/import-phosphor.py) and are read from its bundle into fonts that
// only this file holds. They are never registered with the system: the
// glyphs sit in the Private Use Area, where a registered font would be one more
// candidate for a terminal's own icon codepoints.

import AppKit
import CoreText
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The Phosphor catalog, its search, and its glyphs drawn as images.
@MainActor
package enum PhosphorIcons {
    /// One icon of the catalog.
    package struct Icon: Decodable, Hashable {
        /// The name a `[[tags]]` entry spells in `icon`.
        package let name: String
        /// Where the glyph sits in both fonts.
        package let codePoint: UInt32
        /// What the catalog files the icon under.
        package let categories: [String]
        /// The words a search may find it by besides its name.
        package let tags: [String]
    }

    private struct Catalog: Decodable {
        let icons: [Icon]
    }

    /// Every icon, in name order; empty when the bundle carries no catalog.
    package static let catalog: [Icon] = {
        guard let url = resourceURL("catalog.json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Catalog.self, from: data)
        else {
            return []
        }
        return decoded.icons
    }()

    private static let byName: [String: Icon] = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// The icon a tag names, nil for an empty or unknown name.
    ///
    /// - Parameter name: The name as the config spells it.
    /// - Returns: The icon, matched without regard to case.
    package static func icon(named name: String) -> Icon? {
        guard !name.isEmpty else { return nil }
        return byName[name] ?? byName[name.lowercased()]
    }

    /// The icons a picker shows for a query, best match first.
    ///
    /// Every word of the query has to be found, in the name or among the
    /// icon's tags and categories; a name that starts with the query ranks
    /// above one that only contains it, and either above a tag match.
    ///
    /// - Parameter query: What the reader typed; blank lists the whole catalog.
    /// - Returns: The matching icons.
    package static func search(_ query: String) -> [Icon] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return catalog }
        var ranked: [(rank: Int, icon: Icon)] = []
        for icon in catalog {
            var rank = 0
            var isMatch = true
            for word in words where icon.name != word {
                if icon.name.hasPrefix(word) {
                    rank += 1
                } else if icon.name.contains(word) {
                    rank += 2
                } else if icon.tags.contains(where: { $0.hasPrefix(word) }) || icon.categories.contains(where: { $0.contains(word) }) {
                    rank += 4
                } else {
                    isMatch = false
                    break
                }
            }
            if isMatch {
                ranked.append((rank, icon))
            }
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.icon.name < $1.icon.name }.map(\.icon)
    }

    /// An icon drawn in one colour on a clear square.
    ///
    /// The glyph's em square fills the image, so icons keep the relative sizes
    /// the set was drawn at rather than each being stretched to its own bounds.
    ///
    /// - Parameters:
    ///   - name: The icon's name.
    ///   - weight: Which of its two weights.
    ///   - side: The image's side, in points.
    ///   - color: The ink.
    /// - Returns: The image, or nil for a name the catalog does not carry or a
    ///   bundle without the fonts.
    package static func image(named name: String, weight: Ubiquitty.Session.TagIconWeight, side: CGFloat, color: NSColor) -> NSImage? {
        guard let icon = icon(named: name), side > 0, let font = font(for: weight, side: side) else { return nil }
        var character = UInt16(truncatingIfNeeded: icon.codePoint)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
            let path = CTFontCreatePathForGlyph(font, glyph, nil)
        else {
            return nil
        }
        let descent = CTFontGetDescent(font)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: descent)
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
            return true
        }
        image.accessibilityDescription = icon.name.replacingOccurrences(of: "-", with: " ")
        return image
    }

    /// The bundled font of one weight at the size whose line box is `side`.
    private static func font(for weight: Ubiquitty.Session.TagIconWeight, side: CGFloat) -> CTFont? {
        guard let descriptor = descriptor(for: weight) else { return nil }
        let unit = CTFontCreateWithFontDescriptor(descriptor, 1, nil)
        let lineBox = CTFontGetAscent(unit) + CTFontGetDescent(unit)
        guard lineBox > 0 else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, side / lineBox, nil)
    }

    /// The two weights' descriptors, fill first, each read once.
    private static var descriptors: [CTFontDescriptor?] = [nil, nil]

    /// The font descriptor of one weight, read from the bundle once.
    private static func descriptor(for weight: Ubiquitty.Session.TagIconWeight) -> CTFontDescriptor? {
        let slot = weight == .Regular ? 1 : 0
        if let cached = descriptors[slot] { return cached }
        let file = weight == .Regular ? "Phosphor.ttf" : "Phosphor-Fill.ttf"
        guard let url = resourceURL(file),
            let data = try? Data(contentsOf: url),
            let created = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
            let descriptor = created.first
        else {
            return nil
        }
        descriptors[slot] = descriptor
        return descriptor
    }

    /// A file of the shipped Phosphor resources.
    private static func resourceURL(_ file: String) -> URL? {
        ShippedResources.directory(named: "phosphor")?.appendingPathComponent(file)
    }
}
