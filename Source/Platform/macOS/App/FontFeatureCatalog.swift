// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// FontFeatureCatalog.swift — what OpenType features a face actually carries,
// read from the face rather than from a list this side keeps.
//
// A hand-maintained table of tags would name features a font does not have and
// miss the ones it does, and it could not print the font's own words for them:
// Monaspace calls ss02 "Comparisons", and that is the name a reader recognises
// when they are looking for the set that draws `<=`. CoreText answers all of
// it — the tag, the font's name for the selector, whether it is on by default,
// and whether its group is exclusive — so the catalog is a projection of the
// face and stays correct for faces nobody here has seen.
//
// The specification string stays Core's: `parseFontFeatureSpecification` and
// `serializeFontFeatureSettings` are the only spellings of that grammar, and
// this reads and writes through them so a value set here is the value the
// renderer resolves.
//

import AppKit
import CoreText
import UbiquittyCore
import UbiquittyRenderKit

/// One selectable feature of a face, named as the face names it.
struct FontFeatureOption: Identifiable, Hashable {
    /// The OpenType tag the specification carries, lower-cased.
    let tag: String
    /// The value the tag takes when this option is chosen.
    let value: Int
    /// The font's own name for the selector, shown to the reader.
    let name: String
    /// Whether the face applies this option when nothing asks otherwise.
    let isDefault: Bool

    var id: String { "\(tag)=\(value)" }
}

/// One feature group of a face, in the font's own grouping.
///
/// `isExclusive` is the face's word for "these options are alternatives".
/// A group of alternatives is a choice among values of one tag; a group that
/// is not exclusive is a set of independent switches.
struct FontFeatureGroup: Identifiable, Hashable {
    enum ID: Hashable {
        case appleType(Int)
        case openType([String])
    }

    let id: ID
    let name: String
    let isExclusive: Bool
    let options: [FontFeatureOption]
}

/// One variation axis of a face, named as the face names it.
struct FontVariationAxis: Identifiable, Hashable {
    /// The four-character OpenType axis tag, case preserved.
    let tag: String
    /// The font's own name for the axis.
    let name: String
    /// The design-space floor the face accepts.
    let minValue: Double
    /// The design-space ceiling the face accepts.
    let maxValue: Double
    /// The value the face sits at when nothing names the axis.
    let defaultValue: Double

    var id: String { tag }
}

/// The features a face carries, and the specification they read and write.
enum FontFeatureCatalog {
    /// Reads a face's variation axes, in the face's order.
    ///
    /// - Parameter familyName: The family to read, as the settings hold it.
    /// - Returns: The axes; empty for a static face.
    static func variationAxes(forFamilyNamed familyName: String) -> [FontVariationAxis] {
        let font = CTFontCreateWithName(familyName as CFString, 12.0, nil)
        let raw = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        var axes: [FontVariationAxis] = []
        for axis in raw {
            guard let identifier = axis[kCTFontVariationAxisIdentifierKey as String] as? UInt32,
                let minValue = axis[kCTFontVariationAxisMinimumValueKey as String] as? Double,
                let maxValue = axis[kCTFontVariationAxisMaximumValueKey as String] as? Double,
                let defaultValue = axis[kCTFontVariationAxisDefaultValueKey as String] as? Double,
                minValue < maxValue
            else {
                continue
            }
            let bytes = [
                UInt8((identifier >> 24) & 0xFF), UInt8((identifier >> 16) & 0xFF),
                UInt8((identifier >> 8) & 0xFF), UInt8(identifier & 0xFF),
            ]
            guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }), let tag = String(bytes: bytes, encoding: .ascii) else {
                continue
            }
            let name = axis[kCTFontVariationAxisNameKey as String] as? String ?? tag
            axes.append(
                FontVariationAxis(
                    tag: tag,
                    name: name,
                    minValue: minValue,
                    maxValue: maxValue,
                    defaultValue: defaultValue
                )
            )
        }
        return axes
    }

    /// The axis values a `font.variations` specification names.
    ///
    /// - Parameter specification: The specification string.
    /// - Returns: Each tag it sets, with its value.
    static func variationValues(inSpecification specification: String) -> [String: Double] {
        var resolved: [String: Double] = [:]
        for setting in Ubiquitty.Rendering.parseFontVariationSpecification(std.string(specification)) {
            resolved[String(setting.tag)] = setting.value
        }
        return resolved
    }

    /// A `font.variations` specification carrying `values`, in Core's
    /// canonical form, with `order` deciding the spelling order.
    ///
    /// - Parameters:
    ///   - values: Tag to value.
    ///   - order: The tags in the order they should be written; tags absent
    ///     from `values` are skipped, and values whose tag is absent from
    ///     `order` append after it in sorted order so nothing is dropped.
    /// - Returns: The canonical specification.
    static func variationSpecification(from values: [String: Double], order: [String]) -> String {
        var settings = Ubiquitty.Rendering.FontVariationSettings()
        var written = Set<String>()
        for tag in order {
            guard let value = values[tag] else {
                continue
            }
            settings.push_back(Ubiquitty.Rendering.FontVariationSetting(tag: std.string(tag), value: value))
            written.insert(tag)
        }
        for tag in values.keys.sorted() where !written.contains(tag) {
            settings.push_back(Ubiquitty.Rendering.FontVariationSetting(tag: std.string(tag), value: values[tag] ?? 0))
        }
        return String(Ubiquitty.Rendering.serializeFontVariationSettings(settings))
    }

    /// Reads a face's feature groups, keeping only what a specification can
    /// name.
    ///
    /// A selector without an OpenType tag cannot be written to the
    /// specification and so cannot be offered: the reader would set a control
    /// that no renderer could honour. The face's "All Typographic Features"
    /// group is dropped for the same reason — it names no tag and toggles
    /// everything at once, which is not a choice this surface can keep.
    ///
    /// - Parameter familyName: The family to read, as the settings hold it.
    /// - Returns: The groups, in the face's order; empty when the face carries
    ///   no taggable feature.
    static func groups(forFamilyNamed familyName: String) -> [FontFeatureGroup] {
        let font = CTFontCreateWithName(familyName as CFString, 12.0, nil)
        guard let raw = CTFontCopyFeatures(font) as? [[String: Any]] else {
            return []
        }
        var groups: [FontFeatureGroup] = []
        for entry in raw {
            guard let typeName = entry[kCTFontFeatureTypeNameKey as String] as? String,
                let selectors = entry[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]]
            else {
                continue
            }
            let isExclusive = entry[kCTFontFeatureTypeExclusiveKey as String] as? Bool ?? false
            var options: [FontFeatureOption] = []
            for selector in selectors {
                // The tag key has no constant in the overlay; it is the
                // documented CTFeatureOpenTypeTag, and a selector without one
                // is an AAT-only selector the specification cannot address.
                guard let tag = selector["CTFeatureOpenTypeTag"] as? String else {
                    continue
                }
                let value = selector["CTFeatureOpenTypeValue"] as? Int ?? 1
                let name = selector[kCTFontFeatureSelectorNameKey as String] as? String ?? tag
                let isDefault = selector[kCTFontFeatureSelectorDefaultKey as String] as? Bool ?? false
                options.append(
                    FontFeatureOption(
                        tag: tag.lowercased(),
                        value: value,
                        name: name,
                        isDefault: isDefault
                    )
                )
            }
            guard !options.isEmpty else {
                continue
            }
            // An exclusive group needs a way back to the face's own behaviour.
            // Its "off" selector is commonly the one CoreText reports without
            // an OpenType tag — there is no tag to write for "do nothing" —
            // and dropping it leaves a control that can be moved away from its
            // default and never back. The stand-in carries value zero, which
            // the writer turns into "name none of this group's tags".
            if isExclusive && !options.contains(where: \.isDefault) {
                let offName = untaggedDefaultName(in: selectors) ?? "Off"
                options.insert(
                    FontFeatureOption(tag: options[0].tag, value: 0, name: offName, isDefault: true),
                    at: 0
                )
            }
            let identity: FontFeatureGroup.ID
            if let featureType = entry[kCTFontFeatureTypeIdentifierKey as String] as? Int {
                identity = .appleType(featureType)
            } else {
                identity = .openType(Array(Set(options.map(\.tag))).sorted())
            }
            groups.append(FontFeatureGroup(id: identity, name: typeName, isExclusive: isExclusive, options: options))
        }
        return groups
    }

    /// The face's own name for the selector it marks default but gives no tag.
    ///
    /// Faces name it variously — "Off", "No Alternates", "Normal Vertical
    /// Position" — and the face's word is the one the reader recognises.
    private static func untaggedDefaultName(in selectors: [[String: Any]]) -> String? {
        for selector in selectors
        where selector["CTFeatureOpenTypeTag"] == nil
            && (selector[kCTFontFeatureSelectorDefaultKey as String] as? Bool ?? false)
        {
            return selector[kCTFontFeatureSelectorNameKey as String] as? String
        }
        return nil
    }

    /// A face carrying `settings`, for drawing a sample the way the terminal
    /// will draw it.
    ///
    /// Built through the renderer's own face builder rather than a bare
    /// CoreText lookup, so the sample carries the configured weight, width and
    /// variation axes: a sample at the family's default weight beside a
    /// terminal at 450 shows letterforms the terminal never draws.
    ///
    /// - Parameters:
    ///   - familyName: The family to build from.
    ///   - size: The point size to draw at.
    ///   - settings: Tag to value, as a specification resolves it.
    /// - Returns: The face with those features applied.
    @MainActor
    static func font(familyName: String, size: CGFloat, settings: [String: Int]) -> NSFont {
        let app = SettingsBridge.app
        let base: CTFont
        if let faces = FontFaces(
            family: familyName,
            size: size,
            pixelsPerPoint: 1,
            weight: Int(app?.settingsFontWeight() ?? 0),
            widthPercent: app?.settingsFontWidth() ?? 0,
            variationSpec: app?.settingsFontVariations() ?? ""
        ) {
            base = faces[bold: false, italic: false]
        } else {
            base = CTFontCreateWithName(familyName as CFString, size, nil)
        }
        guard !settings.isEmpty else {
            return base as NSFont
        }
        let applied = settings.keys.sorted()
            .map { tag in
                [kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: settings[tag] ?? 0] as [CFString: Any]
            }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontFeatureSettingsAttribute: applied] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor) as NSFont
    }

    /// Finds a short specimen whose shaped glyphs or positions change with the feature.
    ///
    /// Candidates are shaped independently so context from neighboring operators cannot
    /// make an unrelated character appear to be affected. Indices stay in CoreText's
    /// UTF-16 coordinates; they are never used to index Swift characters.
    @MainActor
    static func example(for option: FontFeatureOption, familyName: String) -> String? {
        let before = font(familyName: familyName, size: 13, settings: [option.tag: 0])
        let after = font(familyName: familyName, size: 13, settings: [option.tag: max(1, option.value)])
        if let character = exampleCharacters.first(where: { shapedGlyphs($0, in: before) != shapedGlyphs($0, in: after) }) {
            return character
        }
        return exampleTokens.first { shapedGlyphs($0, in: before) != shapedGlyphs($0, in: after) }
    }

    private static let exampleCharacters =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ßæœøłαβγδεζηθικλμνξοπρστυφχψωабвгдежзийклмнопрстуфхцчшщъыьэюя:;.,!?()[]{}"
        .map(String.init)

    private static let exampleTokens: [String] = {
        var probe = String(cString: Ubiquitty.Rendering.ligatureOperatorProbe)
        probe += " "
        probe += String(cString: Ubiquitty.Rendering.ligatureAlphanumericProbe)
        probe += " ** __ ~~ :: := :.: ... </div> <br/> 1/2 2/3 3/4 AV To fi fl ffi ffl"
        let tokens: [String] = probe.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        return Array(Set(tokens))
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
            }
    }()

    private struct ShapedGlyph: Equatable {
        let fontName: String
        let glyph: CGGlyph
        let stringIndex: CFIndex
        let position: CGPoint
        let advance: CGSize
    }

    private static func shapedGlyphs(_ text: String, in font: NSFont) -> [ShapedGlyph] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return (CTLineGetGlyphRuns(line) as? [CTRun] ?? [])
            .flatMap { run in
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetStringIndices(run, CFRange(), &indices)
                CTRunGetPositions(run, CFRange(), &positions)
                CTRunGetAdvances(run, CFRange(), &advances)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName] as! CTFont
                let name = CTFontCopyPostScriptName(runFont) as String
                return (0..<count)
                    .map {
                        ShapedGlyph(
                            fontName: name,
                            glyph: glyphs[$0],
                            stringIndex: indices[$0],
                            position: positions[$0],
                            advance: advances[$0]
                        )
                    }
            }
    }

    /// The resolved settings a specification names, as tag to value.
    ///
    /// - Parameter specification: The `font.features` string.
    /// - Returns: Each tag the specification sets, with its value.
    static func settings(inSpecification specification: String) -> [String: Int] {
        var resolved: [String: Int] = [:]
        for setting in Ubiquitty.Rendering.parseFontFeatureSpecification(std.string(specification)) {
            resolved[String(setting.tag)] = Int(setting.value)
        }
        return resolved
    }

    /// A specification carrying `settings`, in Core's canonical form.
    ///
    /// Serialised through Core rather than assembled here: the grammar has one
    /// spelling, and a second one on this side would drift from the parser
    /// that has to read it back.
    ///
    /// - Parameter settings: Tag to value; a value of zero disables the tag.
    /// - Returns: The canonical specification string.
    static func specification(from settings: [String: Int]) -> String {
        var resolved = Ubiquitty.Rendering.FontFeatureSettings()
        for tag in settings.keys.sorted() {
            var setting = Ubiquitty.Rendering.FontFeatureSetting()
            setting.tag = std.string(tag)
            setting.value = Int32(settings[tag] ?? 0)
            resolved.push_back(setting)
        }
        return String(Ubiquitty.Rendering.serializeFontFeatureSettings(resolved))
    }
}
