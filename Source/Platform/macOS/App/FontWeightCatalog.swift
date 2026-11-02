// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// FontWeightCatalog.swift — the weights a family really has, for the two
// weight pickers in Settings.
//
// A picker offering Thin through Black for every family offers seven rows
// most families cannot honour: a static family has the members it ships, a
// variable one the instances its designer named. Read from the face, the
// rows are the family's own names with the setting each one routes to — a
// static member through the published weight stops (FontRoute.h), a
// variable instance through its `wght` coordinate — so the menu never offers
// a weight the route would snap elsewhere.
//
import AppKit
import CoreText
import UbiquittyCore

/// The weight rows a family offers.
enum FontWeightCatalog {
    /// One row: the name the face gives the weight, and the setting it maps to.
    struct Entry: Equatable {
        let label: String
        let weight: Int
    }

    /// The row that means "the face's own", which every list begins with.
    static let fontDefault = Entry(label: "Font Default", weight: 0)

    /// The rows a family offers, the default first, then its members in
    /// weight order; the generic stops when the family is not installed or
    /// reports no upright members.
    ///
    /// - Parameters:
    ///   - familyName: The family, as the settings hold it; empty for the
    ///     system monospaced face.
    ///   - configuredWeight: The setting as it stands, so a value the family
    ///     does not name — written by hand — still shows as itself.
    /// - Returns: The rows.
    static func entries(forFamilyNamed familyName: String, configuredWeight: Int) -> [Entry] {
        var rows = members(ofFamilyNamed: familyName)
        if rows.isEmpty {
            rows = FontWeightChoice.entries.dropFirst().map { Entry(label: $0.label, weight: $0.weight) }
        }
        if configuredWeight > 0, !rows.contains(where: { $0.weight == configuredWeight }) {
            rows.append(Entry(label: "Custom (\(configuredWeight))", weight: configuredWeight))
            rows.sort { $0.weight < $1.weight }
        }
        return [fontDefault] + rows
    }

    /// The upright members of a family, one row per distinct weight.
    ///
    /// A variable family's named instances arrive as descriptors carrying
    /// their `wght` coordinate, which the renderer sets on the axis as the
    /// setting's own value — exact, so those win whenever the family has
    /// them. A static family's members carry a weight trait; the published
    /// stops map it back to the setting whose trait selects that member,
    /// which is what the renderer does with a setting on a static face, so
    /// the row names the weight the route lands on rather than the
    /// OpenType class the member claims. Italic members are the same
    /// weights again under another name, so they are left out.
    ///
    /// - Parameter familyName: The family to read.
    /// - Returns: The rows, in weight order, empty when the family has none.
    static func members(ofFamilyNamed familyName: String) -> [Entry] {
        let family = familyName.isEmpty ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).familyName ?? "" : familyName
        guard !family.isEmpty else { return [] }
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] else {
            return []
        }
        let weightTag: UInt32 = UInt32(Ubiquitty.Rendering.variationAxisTagWeight)
        var byInstance: [Int: String] = [:]
        var byTrait: [Int: String] = [:]
        for match in matches {
            guard let traits = CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute) as? [CFString: Any] else { continue }
            let symbolic = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
            if symbolic & CTFontSymbolicTraits.italicTrait.rawValue != 0 { continue }
            let styleName = (CTFontDescriptorCopyAttribute(match, kCTFontStyleNameAttribute) as? String) ?? "Regular"
            let trait = traits[kCTFontWeightTrait] as? Double
            if let variation = CTFontDescriptorCopyAttribute(match, kCTFontVariationAttribute) as? [UInt32: Double] {
                // An instance at the axis default carries no coordinate; its
                // trait names the same weight the stops map to.
                let weight =
                    variation[weightTag].map { Int($0.rounded()) }
                    ?? trait.map { Int(Ubiquitty.Rendering.Font.settingForNormalisedWeightTrait(Float($0))) } ?? 0
                if weight > 0 { keepPlainer(&byInstance, weight: weight, name: styleName) }
            } else if let trait {
                let weight = Int(Ubiquitty.Rendering.Font.settingForNormalisedWeightTrait(Float(trait)))
                if weight > 0 { keepPlainer(&byTrait, weight: weight, name: styleName) }
            }
        }
        let rows = byInstance.isEmpty ? byTrait : byInstance
        return rows.keys.sorted().map { Entry(label: rows[$0] ?? "\($0)", weight: $0) }
    }

    /// Two members at one weight — a width variant, a stylistic twin — keep
    /// the shorter name, which is the plainer one.
    private static func keepPlainer(_ rows: inout [Int: String], weight: Int, name: String) {
        if let existing = rows[weight], existing.count <= name.count { return }
        rows[weight] = name
    }

    /// The row a configured weight selects.
    ///
    /// - Parameters:
    ///   - weight: The configured weight.
    ///   - entries: The rows offered.
    /// - Returns: The index to show as selected; the default row when none matches.
    static func index(of weight: Int, in entries: [Entry]) -> Int {
        entries.firstIndex { $0.weight == weight } ?? 0
    }
}
