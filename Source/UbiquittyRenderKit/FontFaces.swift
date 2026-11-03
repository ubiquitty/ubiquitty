// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FontFaces.swift — one CTFont per face of the configured family.
//
// The four faces Core's `FontFace` names, resolved once for a family and size
// and held for as long as that pair is current. Everything that draws a glyph
// starts here, so this is where the family's own shortcomings are absorbed: a
// face the family does not ship is synthesised rather than reported, because a
// terminal that stops italicising when the user picks a family without an
// italic is a worse answer than a slanted regular.
//
// Under ARC, which is the point of it being Swift. The CoreText handles are
// managed by the compiler, so there is no release to omit on an early return
// and no retain to add when one is stored — the class of bug that a font path
// with nine handles and four exits invites.
//
// The face table is ORDERED to Core's packing and indexed by the raw value, so
// the encoding is used rather than copied. `fontFace(bold:italic:)` is Core's
// too. A frontend that mapped a bool pair to a face itself would hold a second
// copy of the bit layout, and the two would agree until the enum gained a third
// bit — at which point the array grows and the index still lands.

import CoreText
import Foundation
import UbiquittyCore

/// The CTFont for each of Core's four faces, plus the variants drawing needs.
///
/// Immutable: a family or size change builds a new set rather than mutating one,
/// so a frame that is mid-encode cannot observe half a font change.
package final class FontFaces {
    /// The family these faces were resolved from.
    package let family: String
    /// The size they were built at, in the pixels the atlas rasterises —
    /// the point size times ``pixelsPerPoint``.
    package let size: CGFloat
    /// How many of those pixels one point covers: the backing scale the
    /// faces were sized for, so a face that must be built at the POINT size
    /// — the system UI face, whose optical size and tracking follow the
    /// point size — can recover it and scale by a matrix instead.
    package let pixelsPerPoint: CGFloat

    /// Regular, Bold, Italic, BoldItalic — indexed by ``Ubiquitty/Rendering/FontFace``.
    private let faces: [CTFont]

    /// Whether scalar glyphs require the configured OpenType shaping features.
    package let hasUserFeatures: Bool

    /// Whether the italic faces are sheared uprights rather than the family's own.
    ///
    /// Worth knowing outside this type: a synthesised italic has no italic
    /// metrics of its own, so anything measuring the italic advance is measuring
    /// the regular one with a shear applied.
    package let isItalicSynthesized: Bool

    /// Whether these faces stand in for the family they were asked for.
    ///
    /// True when no font answers to the family's name, which the fixed-pitch
    /// system face is drawn in place of, and when the name is blank and names
    /// no family. False for a shipped family, drawn from its own files, and for
    /// a family CoreText finds under any of its family, full or PostScript
    /// names.
    package let isSubstitute: Bool

    /// The OpenType `wdth` axis identifier.
    private static let widthAxisTag: UInt32 = UInt32(Ubiquitty.Rendering.variationAxisTagWidth)
    /// The OpenType `wght` axis identifier.
    private static let weightAxisTag: UInt32 = UInt32(Ubiquitty.Rendering.variationAxisTagWeight)
    /// The OpenType `slnt` axis identifier.
    private static let slantAxisTag: UInt32 = 0x736C_6E74

    /// An axis identifier is the tag's four ASCII bytes, big-endian.
    ///
    /// - Parameter tag: The four-character tag, case preserved.
    /// - Returns: The identifier, or nil for a tag of the wrong shape.
    private static func axisIdentifier(_ tag: String) -> UInt32? {
        let bytes = Array(tag.utf8)
        guard bytes.count == 4 else {
            return nil
        }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    /// The reader's `font.variations`, resolved through Core's one grammar.
    ///
    /// - Parameter spec: The specification string.
    /// - Returns: The resolved axes, empty when none apply.
    private static func variationSettings(fromSpec spec: String) -> Ubiquitty.Rendering.FontVariationSettings {
        guard !spec.isEmpty else {
            return Ubiquitty.Rendering.FontVariationSettings()
        }
        return Ubiquitty.Rendering.parseFontVariationSpecification(std.string(spec))
    }

    /// The family member at a configured weight, width and axis set, in one
    /// match.
    ///
    /// Two populations answer and each has its own mechanism. A variable face
    /// takes every requested axis in ONE variation dictionary and one copy —
    /// the width as percent-of-normal and the weight in usWeightClass numbers,
    /// both by the OpenType specification, and the user's `font.variations`
    /// folded over that derived pair by Core's rule, so a tag named by both
    /// takes the user's value. Writing axes in two passes trusts the second
    /// write to preserve the first's axis, and the Linux arm measured its
    /// variation API restating every coordinate from the defaults on each
    /// call: one write cannot have the ordering. A static family (the Nerd
    /// Font builds ship SemiWide members and no axis) is matched by the
    /// numeric traits, both in one descriptor; the matcher picks the nearest
    /// member, a family with one width resolves to itself, and a user axis no
    /// face carries applies nowhere — the CSS behaviour for
    /// font-variation-settings on a static font.
    ///
    /// The weight and width are Core's (`weightForFace`, `widthForSetting`), so
    /// a variable face is always placed on its axes — an unset `font.weight` is
    /// the upright weight, not whichever instance the platform resolves the
    /// family name to. A static family keeps the member it has unless a
    /// setting names another, or `forcesWeight` asks for the weight anyway.
    ///
    /// - Parameters:
    ///   - font: The face to re-instance.
    ///   - face: Which of the four faces this is, which picks the weight.
    ///   - weights: The named weights and the body's variation weight.
    ///   - widthPercent: `font.width`, 0 for unset.
    ///   - userAxes: The reader's `font.variations`, already parsed.
    ///   - forcesWeight: Whether a static family is matched to Core's weight
    ///     even with no setting naming it, for a bold whose linked member did
    ///     not come back heavier.
    ///   - matchesTraits: Whether a setting the face has no axis for may be
    ///     matched by trait across the family. Off for a shipped family, which
    ///     is drawn from its own files and never from the system's matcher.
    /// - Returns: The resolved face.
    private static func resolved(
        _ font: CTFont,
        face: Ubiquitty.Rendering.FontFace,
        weights: Ubiquitty.Rendering.Font.WeightSettings,
        widthPercent: Double,
        userAxes: Ubiquitty.Rendering.FontVariationSettings,
        forcesWeight: Bool = false,
        matchesTraits: Bool = true
    ) -> CTFont {
        let isBoldFace = face == .Bold || face == .BoldItalic
        let isWeightSet = (isBoldFace ? weights.bold : weights.upright) > 0
        let faceAxisIdentifiers = Set(
            (CTFontCopyVariationAxes(font) as? [[String: Any]] ?? [])
                .compactMap { $0[kCTFontVariationAxisIdentifierKey as String] as? UInt32 }
        )
        var supportedWeights = weights
        if !faceAxisIdentifiers.contains(weightAxisTag) {
            supportedWeights.uprightVariation = .nan
        }
        let weight = Ubiquitty.Rendering.Font.weightForFace(face, 0, supportedWeights)
        var derived = Ubiquitty.Rendering.FontVariationSettings()
        if widthPercent > 0 || faceAxisIdentifiers.contains(widthAxisTag) {
            derived.push_back(
                Ubiquitty.Rendering.FontVariationSetting(
                    tag: std.string("wdth"),
                    value: Ubiquitty.Rendering.Font.widthForSetting(widthPercent)
                )
            )
        }
        derived.push_back(Ubiquitty.Rendering.FontVariationSetting(tag: std.string("wght"), value: Double(weight)))
        let wanted = Ubiquitty.Rendering.mergeFontVariationSettings(derived, userAxes)
        var variation: [UInt32: Double] = [:]
        var didTakeWidthAxis = false
        var didTakeWeightAxis = false
        for axis in wanted {
            guard let identifier = axisIdentifier(String(axis.tag)), faceAxisIdentifiers.contains(identifier) else {
                continue
            }
            variation[identifier] = axis.value
            if identifier == widthAxisTag {
                didTakeWidthAxis = true
            }
            if identifier == weightAxisTag {
                didTakeWeightAxis = true
            }
        }
        var varied = font
        if !variation.isEmpty {
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [kCTFontVariationAttribute: variation] as CFDictionary
            )
            varied = CTFontCreateCopyWithAttributes(varied, CTFontGetSize(varied), nil, descriptor)
        }
        // The named settings still apply by trait when the face has no axis
        // for them — a static-weight family with a width axis exists. Core's
        // mappings, so the two arms cannot pick different members.
        var traits: [CFString: Any] = [:]
        if widthPercent > 0 && !didTakeWidthAxis {
            traits[kCTFontWidthTrait] = Ubiquitty.Rendering.Font.normalisedWidthTraitForSetting(widthPercent)
        }
        if (isWeightSet || forcesWeight) && !didTakeWeightAxis {
            traits[kCTFontWeightTrait] = Ubiquitty.Rendering.Font.normalisedWeightTraitForSetting(Int32(weight))
        }
        guard !traits.isEmpty, matchesTraits else {
            return varied
        }
        let family = CTFontCopyFamilyName(varied) as String
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [
                kCTFontFamilyNameAttribute: family,
                kCTFontTraitsAttribute: traits,
            ] as CFDictionary
        )
        let rematched = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(varied), nil)
        // File-backed fallbacks need not be registered with the system matcher.
        guard (CTFontCopyFamilyName(rematched) as String).compare(family, options: .caseInsensitive) == .orderedSame else {
            return varied
        }
        // The trait match resolves from the family rather than from `varied`,
        // so the member it picks carries none of the axes placed above — a
        // weight that rode the `wght` axis while the width fell back to its
        // trait would leave here at the member's default weight. The axes go
        // back onto the member the traits chose.
        guard !variation.isEmpty else {
            return rematched
        }
        let axisDescriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontVariationAttribute: variation] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(rematched, CTFontGetSize(rematched), nil, axisDescriptor)
    }

    /// The bold face, at Core's bold weight.
    ///
    /// A variable face is placed on its `wght` axis from the regular one, so
    /// the width and the reader's other axes come along. A static family takes
    /// its linked bold member, and is matched to the weight by trait when that
    /// member does not come back as a different face: CoreText's bold trait
    /// answers a face it has no bold link for with the face itself, and bold
    /// text drawn in it is indistinguishable from regular.
    ///
    /// - Parameters:
    ///   - regular: The resolved upright face.
    ///   - size: The size to build at.
    ///   - weights: The named weights and the body's variation weight.
    ///   - widthPercent: `font.width`, 0 for unset.
    ///   - userAxes: The reader's `font.variations` less any `wght`.
    /// - Returns: The bold face.
    private static func boldFace(
        from regular: CTFont,
        size: CGFloat,
        weights: Ubiquitty.Rendering.Font.WeightSettings,
        widthPercent: Double,
        userAxes: Ubiquitty.Rendering.FontVariationSettings
    ) -> CTFont {
        let axes = (CTFontCopyVariationAxes(regular) as? [[String: Any]] ?? [])
            .compactMap { $0[kCTFontVariationAxisIdentifierKey as String] as? UInt32 }
        if axes.contains(weightAxisTag) {
            return resolved(regular, face: .Bold, weights: weights, widthPercent: widthPercent, userAxes: userAxes)
        }
        let linked = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .traitBold, .traitBold)
        let isLinkedDistinct = linked.map { CTFontCopyPostScriptName($0) != CTFontCopyPostScriptName(regular) } ?? false
        return resolved(
            isLinkedDistinct ? linked! : regular,
            face: .Bold,
            weights: weights,
            widthPercent: widthPercent,
            userAxes: userAxes,
            forcesWeight: !isLinkedDistinct
        )
    }

    /// Resolves a fallback face's style and explicit SGR weight at its existing size.
    static func fallbackFace(from base: CTFont, style: Ubiquitty.Rendering.Font.FontStyle, variableWeight: UInt8) -> CTFont {
        let size = CTFontGetSize(base)
        let weight = variableWeight <= 7 ? Int32(Ubiquitty.Rendering.Font.variationWeightForSGR(variableWeight)) : 0
        let weights = Ubiquitty.Rendering.Font.WeightSettings(upright: weight, bold: weight, uprightVariation: .nan)
        let axes = Ubiquitty.Rendering.FontVariationSettings()
        let bold = style == .Bold || style == .BoldItalic
        let italic = style == .Italic || style == .BoldItalic
        let upright: CTFont
        if bold {
            upright = boldFace(from: base, size: size, weights: weights, widthPercent: 0, userAxes: axes)
        } else if weight > 0 {
            upright = resolved(base, face: .Regular, weights: weights, widthPercent: 0, userAxes: axes)
        } else {
            upright = base
        }
        guard italic else { return upright }
        if let linked = CTFontCreateCopyWithSymbolicTraits(upright, size, nil, .traitItalic, .traitItalic),
            CTFontGetSymbolicTraits(linked).contains(.traitItalic)
        {
            return linked
        }
        return slanted(upright, size: size) ?? upright
    }

    /// The reader's `font.features`, resolved through Core's one grammar.
    ///
    /// - Parameter spec: The specification string.
    /// - Returns: The CoreText feature settings, empty when none apply.
    private static func featureSettings(fromSpec spec: String) -> [[CFString: Any]] {
        guard !spec.isEmpty else {
            return []
        }
        var applied: [[CFString: Any]] = []
        for setting in Ubiquitty.Rendering.parseFontFeatureSpecification(std.string(spec)) {
            applied.append([
                kCTFontOpenTypeFeatureTag: String(setting.tag),
                kCTFontOpenTypeFeatureValue: Int(setting.value),
            ])
        }
        return applied
    }

    /// The same face carrying the reader's features, or unchanged for none.
    ///
    /// - Parameters:
    ///   - font: The face to re-instance.
    ///   - features: The CoreText settings, from ``featureSettings(fromSpec:)``.
    /// - Returns: The featured face.
    private static func featured(_ font: CTFont, with features: [[CFString: Any]]) -> CTFont {
        guard !features.isEmpty else {
            return font
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }

    /// Resolves the four faces for a family at a size.
    ///
    /// The weights carry to the italic faces because they are copies of the
    /// upright and bold ones: a reader who thins their text expects the
    /// italics to thin with it, not to stay at the face's own instance.
    ///
    /// The reader's `font.features` bake into every face the same way: a tag
    /// that reaches only the strip font draws a slashed zero inside a shaped
    /// run and a plain one beside it, which reads as the setting flickering
    /// with the shaper's mood.
    ///
    /// - Parameters:
    ///   - family: The family name to resolve.
    ///   - size: The point size to build at.
    ///   - weight: The upright `wght` axis, or zero for the face's own.
    ///   - boldWeight: The bold `wght` axis, or zero for the face's own.
    ///   - featureSpec: The reader's features, in Core's grammar; empty
    ///     leaves the faces their defaults.
    ///   - widthPercent: The width, 50 through 200 percent, or zero for the
    ///     face's own; a family with neither a `wdth` axis nor width members
    ///     resolves back to itself.
    ///   - variationSpec: The reader's `font.variations`, in Core's grammar;
    ///     empty writes no axis. A tag named here beats the axis a named
    ///     setting derives. The body's `wght` sets the floor for an unset bold
    ///     weight; an explicit bold weight remains independent.
    /// The face a family name asks for, or a fixed-pitch one when nothing
    /// carries that name.
    ///
    /// `CTFontCreateWithName` does not fail on a name no font answers to. It
    /// substitutes, and what it substitutes is the system's proportional face,
    /// so a terminal configured for a font the machine does not have draws
    /// proportional letters on the grid with nothing announcing it. A family
    /// in the macOS font library and not in the iOS bundle then mints an iOS
    /// plate in the substitute, and both arms report success.
    ///
    /// A monospaced fallback is still wrong, but it is wrong the way a missing
    /// font should be.
    ///
    /// The name is matched as a prefix of what came back, normalised, because
    /// a family resolves to one of its members: "Monaspace Neon Var" answers
    /// as "Monaspace Neon Var ExtraLight", and a PostScript name answers as
    /// itself. The face CoreText substitutes is matched by its names whole, so
    /// a name that only begins one of them, "Helv" for Helvetica, is a name no
    /// font carries.
    ///
    /// - Parameters:
    ///   - family: The family, full or PostScript name the reader asked for.
    ///   - size: The point size to build at.
    /// - Returns: The named face, or the fixed-pitch system face, and whether
    ///   the face stands in for a name no font answers to or for a blank one.
    private static func named(_ family: String, _ size: CGFloat) -> (face: CTFont, isSubstitute: Bool) {
        if let confirmed = confirmed(family, size) {
            return (confirmed, normalisedFontName(family).isEmpty)
        }
        let substitute = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? CTFontCreateWithName(family as CFString, size, nil)
        return (substitute, true)
    }

    /// The face a family name asks for, or nil when nothing carries that name.
    ///
    /// The confirmation `named` makes, without its substitution: a caller that
    /// must know whether the reader's font is present — rather than draw
    /// something in its place — reads the nil. Asking `CTFontCreateWithName`
    /// alone cannot tell them apart, because it answers a substitute.
    ///
    /// The name is matched as a prefix of what came back, normalised, for the
    /// reason `named` gives: a family resolves to one of its members. The face
    /// CoreText substitutes answers to its own names whole, since it is what
    /// every name no font carries comes back as.
    ///
    /// - Parameters:
    ///   - family: The family, full or PostScript name the reader asked for.
    ///   - size: The point size to build at.
    /// - Returns: The named face, or nil when the name resolved to something
    ///   else.
    public static func confirmed(_ family: String, _ size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName(family as CFString, size, nil)
        let wanted = normalisedFontName(family)
        guard !wanted.isEmpty else {
            return font
        }
        let postScriptName = CTFontCopyPostScriptName(font) as String
        let isSubstituteFace = postScriptName == substitutePostScriptName
        let answers = [CTFontCopyFamilyName(font) as String, CTFontCopyFullName(font) as String, postScriptName]
        for answer in answers {
            let answered = normalisedFontName(answer)
            if isSubstituteFace ? answered == wanted : answered.hasPrefix(wanted) {
                return font
            }
        }
        return nil
    }

    /// The PostScript name of the face `CTFontCreateWithName` answers a name
    /// no font carries with.
    private static let substitutePostScriptName: String = {
        let unnamed = CTFontCreateWithName(UUID().uuidString as CFString, 12, nil)
        return CTFontCopyPostScriptName(unnamed) as String
    }()

    /// A font name with the spelling differences that do not distinguish one
    /// removed: case, spaces and hyphens.
    ///
    /// - Parameter name: The name to fold.
    /// - Returns: The folded name.
    private static func normalisedFontName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    package init?(
        family: String,
        size: CGFloat,
        pixelsPerPoint: CGFloat,
        weight: Int = 0,
        boldWeight: Int = 0,
        featureSpec: String = "",
        widthPercent: Double = 0,
        variationSpec: String = "",
        fontDirectory: URL? = ShippedResources.fontDirectory
    ) {
        guard size > 0, pixelsPerPoint > 0 else {
            return nil
        }
        self.family = family
        self.size = size
        self.pixelsPerPoint = pixelsPerPoint
        let features = FontFaces.featureSettings(fromSpec: featureSpec)
        hasUserFeatures = !features.isEmpty
        let userAxes = FontFaces.variationSettings(fromSpec: variationSpec)
        var boldUserAxes = Ubiquitty.Rendering.FontVariationSettings()
        for axis in userAxes where String(axis.tag) != "wght" {
            boldUserAxes.push_back(axis)
        }
        // The width changes which MEMBER of a static family every other trait
        // resolves inside, so it rides the same descriptor as the weight: two
        // successive family matches each keep only their own trait, and the
        // second silently discards the first's member. With no width set the
        // paths are the unwidened ones, byte for byte.
        var weights = Ubiquitty.Rendering.Font.WeightSettings(upright: Int32(weight), bold: Int32(boldWeight), uprightVariation: .nan)
        for axis in userAxes where String(axis.tag) == "wght" {
            weights.uprightVariation = axis.value
        }
        // A family we ship is drawn from its own files, every style placed on
        // one of them by axis; the system's matcher is never asked. Asked by
        // name or trait, CoreText answers from every face carrying the family
        // name, so a machine with its own copy installed drew that copy: a
        // static bold italic in ~/Library/Fonts beat the bundled variable
        // italic, and the bold italic stopped matching the other three styles
        // and every other machine.
        let shippedFiles = Ubiquitty.Rendering.bundledFaceFiles(std.string(family))
        if let shipped = FontFaces.shippedFaces(
            shippedFiles,
            in: fontDirectory,
            size: size,
            weights: weights,
            widthPercent: widthPercent,
            userAxes: userAxes,
            boldUserAxes: boldUserAxes,
            features: features
        ) {
            self.isItalicSynthesized = shipped.isItalicSynthesized
            self.isSubstitute = false
            self.faces = shipped.faces
            return
        }
        let named = FontFaces.named(family, size)
        self.isSubstitute = named.isSubstitute
        let regular = FontFaces.featured(
            FontFaces.resolved(
                named.face,
                face: .Regular,
                weights: weights,
                widthPercent: widthPercent,
                userAxes: userAxes
            ),
            with: features
        )
        let bold = FontFaces.featured(
            FontFaces.boldFace(from: regular, size: size, weights: weights, widthPercent: widthPercent, userAxes: boldUserAxes),
            with: features
        )

        // The family's real italic is preferred; a family shipping none gets a
        // sheared upright. One flag covers the two italic faces together: a
        // family with a real italic and no real bold-italic would otherwise
        // slant its bold italics and leave the rest upright, which reads as a
        // rendering fault rather than as a missing face.
        let realItalic = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .traitItalic, .traitItalic)
        // Derived from the bold face rather than the regular one: a family
        // whose bold-italic descends from its bold gives a different weight
        // than the regular face asked for both traits at once.
        let realBoldItalic = CTFontCreateCopyWithSymbolicTraits(
            bold,
            size,
            nil,
            [.traitItalic, .traitBold],
            [.traitItalic, .traitBold]
        )
        self.isItalicSynthesized = realItalic == nil || realBoldItalic == nil
        let italic = realItalic ?? FontFaces.slanted(regular, size: size) ?? regular
        let boldItalic = realBoldItalic ?? FontFaces.slanted(bold, size: size) ?? bold
        // Ordered to match FontFace's bit packing: bit 0 bold, bit 1 italic.
        self.faces = [regular, bold, italic, boldItalic]
    }

    /// The font for one face.
    ///
    /// - Parameter face: The face Core resolved for the cell.
    /// - Returns: The font to draw it with.
    package subscript(face: Ubiquitty.Rendering.FontFace) -> CTFont {
        faces[Int(face.rawValue) & 0x3]
    }

    /// The face a font is, when it is one of these faces.
    ///
    /// - Parameter font: The font a raster is drawing with.
    /// - Returns: The face, or `nil` for a fallback face.
    func primaryFace(of font: CTFont) -> Ubiquitty.Rendering.FontFace? {
        if let index = faces.firstIndex(where: { CFEqual($0, font) }) {
            return Ubiquitty.Rendering.FontFace(rawValue: UInt8(index))
        }
        return nil
    }

    /// The faces widened on their `wdth` axis for a DECDWL row, built on first use.
    private lazy var doubleWidthFaces: [CTFont?] = faces.map(Self.doubleWidthInstance)

    /// The font a DECDWL row draws one face in, where the family can widen.
    ///
    /// A doubled row is twice as wide as it is tall. A family with a width axis
    /// draws that from letterforms designed wider, and the renderer stretches
    /// only the part the axis does not reach.
    ///
    /// - Parameter face: The face Core resolved for the cell.
    /// - Returns: The widened font, or `nil` for a face with no room to widen.
    func doubleWidthFace(_ face: Ubiquitty.Rendering.FontFace) -> CTFont? {
        doubleWidthFaces[Int(face.rawValue) & 0x3]
    }

    /// Where a face's `wdth` axis stands and how far it reaches.
    ///
    /// The fact Core's width selection reads (``Ubiquitty/Rendering/doubleWidthAxisTarget``),
    /// taken from the face's variation axes: where the face is set, or the axis'
    /// default where it names none, and the axis' maximum.
    ///
    /// - Parameter font: The face to measure.
    /// - Returns: The axis position and maximum, or no room for a face with no `wdth` axis.
    static func widthAxisRoom(of font: CTFont) -> Ubiquitty.Rendering.WidthAxisRoom {
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        guard
            let axis = axes.first(where: {
                ($0[kCTFontVariationAxisIdentifierKey as String] as? UInt32) == widthAxisTag
            }),
            let maximum = axis[kCTFontVariationAxisMaximumValueKey as String] as? Double,
            let defaultValue = axis[kCTFontVariationAxisDefaultValueKey as String] as? Double
        else {
            return Ubiquitty.Rendering.WidthAxisRoom()
        }
        let variation = CTFontCopyVariation(font) as? [UInt32: Double] ?? [:]
        return Ubiquitty.Rendering.WidthAxisRoom(current: variation[widthAxisTag] ?? defaultValue, maximum: maximum)
    }

    /// Where each face's `wdth` axis stands, built on first use.
    private lazy var widthAxisRooms: [Ubiquitty.Rendering.WidthAxisRoom] = faces.map(Self.widthAxisRoom(of:))

    /// Where a face's `wdth` axis stands and how far it reaches.
    ///
    /// - Parameter face: The face Core resolved for the cell.
    /// - Returns: The axis position and maximum, or no room.
    func widthAxisRoom(_ face: Ubiquitty.Rendering.FontFace) -> Ubiquitty.Rendering.WidthAxisRoom {
        widthAxisRooms[Int(face.rawValue) & 0x3]
    }

    /// Makes a face's instance at twice its width, or as wide as its axis goes.
    ///
    /// The copy keeps the face's size, matrix and every other variation, so it
    /// differs from the face only on `wdth`. The target is Core's, the one every
    /// arm widens a doubled row to.
    ///
    /// - Parameter font: The face to widen.
    /// - Returns: The widened instance, or `nil` when the face has no `wdth`
    ///   axis or already stands at the axis maximum.
    static func doubleWidthInstance(of font: CTFont) -> CTFont? {
        let target = Ubiquitty.Rendering.doubleWidthAxisTarget(widthAxisRoom(of: font))
        guard target > 0 else {
            return nil
        }
        var variation = CTFontCopyVariation(font) as? [UInt32: Double] ?? [:]
        variation[widthAxisTag] = target
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }

    /// The font for a bold/italic pair, routed through Core's packing.
    ///
    /// - Parameters:
    ///   - bold: Whether the cell is bold.
    ///   - italic: Whether the cell is italic.
    /// - Returns: The font to draw it with.
    package subscript(bold bold: Bool, italic italic: Bool) -> CTFont {
        self[Ubiquitty.Rendering.fontFace(bold, italic)]
    }

    /// A shipped style file opened by its path, or nil when the table names
    /// none or the file is not there.
    ///
    /// - Parameters:
    ///   - file: The file's name inside the font directory, empty for none.
    ///   - directory: The font directory.
    ///   - size: The size to build at.
    /// - Returns: The face in that file.
    private static func shippedFace(_ file: std.string, in directory: URL?, size: CGFloat) -> CTFont? {
        let name = String(file)
        guard !name.isEmpty, let directory else {
            return nil
        }
        let url = directory.appendingPathComponent(name)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first
        else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// A shipped family's four styles, each placed on one of its own files by
    /// axis, or nil when its upright file is not beside this binary.
    ///
    /// The bold is the bold file, or the upright's `wght` axis. The italic is
    /// the italic file, or the upright's slant axis. The bold italic is the
    /// bold italic file, or the italic's `wght` axis, or the upright's slant
    /// and weight axes together. A style none of those carries is sheared from
    /// the upright or the bold, as for any family shipping no italic.
    ///
    /// - Parameters:
    ///   - files: The family's style files, from Core's table.
    ///   - directory: The font directory.
    ///   - size: The size to build at.
    ///   - weights: The named weights and the body's variation weight.
    ///   - widthPercent: `font.width`, 0 for unset.
    ///   - userAxes: The reader's `font.variations`.
    ///   - boldUserAxes: The reader's `font.variations` less any `wght`.
    ///   - features: The reader's OpenType features.
    /// - Returns: The faces in FontFace order, and whether an italic is sheared.
    private static func shippedFaces(
        _ files: Ubiquitty.Rendering.BundledFaceFiles,
        in directory: URL?,
        size: CGFloat,
        weights: Ubiquitty.Rendering.Font.WeightSettings,
        widthPercent: Double,
        userAxes: Ubiquitty.Rendering.FontVariationSettings,
        boldUserAxes: Ubiquitty.Rendering.FontVariationSettings,
        features: [[CFString: Any]]
    ) -> (faces: [CTFont], isItalicSynthesized: Bool)? {
        guard let uprightFile = shippedFace(files.regular, in: directory, size: size) else {
            return nil
        }
        func placed(_ font: CTFont, _ face: Ubiquitty.Rendering.FontFace, _ axes: Ubiquitty.Rendering.FontVariationSettings) -> CTFont {
            featured(
                resolved(font, face: face, weights: weights, widthPercent: widthPercent, userAxes: axes, matchesTraits: false),
                with: features
            )
        }
        // The slant axis at its most slanted, the value the family's italic
        // instances name, over the reader's axes so a `slnt` they set wins.
        func slanting(_ axes: Ubiquitty.Rendering.FontVariationSettings) -> Ubiquitty.Rendering.FontVariationSettings? {
            guard
                let slant = (CTFontCopyVariationAxes(uprightFile) as? [[String: Any]] ?? [])
                    .first(where: {
                        ($0[kCTFontVariationAxisIdentifierKey as String] as? UInt32) == slantAxisTag
                    }), let minimum = slant[kCTFontVariationAxisMinimumValueKey as String] as? Double
            else {
                return nil
            }
            var derived = Ubiquitty.Rendering.FontVariationSettings()
            derived.push_back(Ubiquitty.Rendering.FontVariationSetting(tag: std.string("slnt"), value: minimum))
            return Ubiquitty.Rendering.mergeFontVariationSettings(derived, axes)
        }
        let regular = placed(uprightFile, .Regular, userAxes)
        let boldFile = shippedFace(files.bold, in: directory, size: size)
        let bold: CTFont
        if let boldFile {
            bold = placed(boldFile, .Bold, boldUserAxes)
        } else if hasWeightAxis(uprightFile) {
            bold = placed(uprightFile, .Bold, boldUserAxes)
        } else {
            bold = regular
        }
        let italicFile = shippedFace(files.italic, in: directory, size: size)
        let italic: CTFont?
        if let italicFile {
            italic = placed(italicFile, .Italic, userAxes)
        } else if let slanted = slanting(userAxes) {
            italic = placed(uprightFile, .Italic, slanted)
        } else {
            italic = nil
        }
        let boldItalic: CTFont?
        if let boldItalicFile = shippedFace(files.boldItalic, in: directory, size: size) {
            boldItalic = placed(boldItalicFile, .BoldItalic, boldUserAxes)
        } else if let italicFile, hasWeightAxis(italicFile) {
            boldItalic = placed(italicFile, .BoldItalic, boldUserAxes)
        } else if italicFile == nil, hasWeightAxis(uprightFile), let slanted = slanting(boldUserAxes) {
            boldItalic = placed(uprightFile, .BoldItalic, slanted)
        } else {
            boldItalic = nil
        }
        let faces = [
            regular,
            bold,
            italic ?? slanted(regular, size: size) ?? regular,
            boldItalic ?? slanted(bold, size: size) ?? bold,
        ]
        return (faces, italic == nil || boldItalic == nil)
    }

    /// A shipped family's face in one style, at Core's default weights, or
    /// nil for a family we do not ship.
    ///
    /// For a face built outside the grid's set (a proportional or rich text
    /// face naming a shipped family), so it is drawn from the same files the
    /// grid's faces are and never from a copy the machine has installed.
    ///
    /// - Parameters:
    ///   - family: The family a configuration named.
    ///   - size: The em size to build at.
    ///   - matrix: The transform to build with, or nil for none.
    ///   - isBold: Whether the bold style is wanted.
    ///   - isItalic: Whether the italic style is wanted.
    ///   - directory: The font directory.
    /// - Returns: The face, or nil when the family is not shipped or its files
    ///   are not beside this binary.
    package static func shippedStyle(
        family: String,
        size: CGFloat,
        matrix: CGAffineTransform? = nil,
        isBold: Bool,
        isItalic: Bool,
        in directory: URL? = ShippedResources.fontDirectory
    ) -> CTFont? {
        guard let styles = shippedStyles(family: family, size: size, in: directory) else { return nil }
        let face = styles[Int(Ubiquitty.Rendering.fontFace(isBold, isItalic).rawValue) & 0x3]
        guard var matrix else {
            return face
        }
        return CTFontCreateCopyWithAttributes(face, size, &matrix, nil)
    }

    /// Loads all four shipped style handles together for a renderer snapshot.
    /// Subsequent measurement and drawing resize these handles without reading
    /// files again or resolving an installed copy of the same family.
    package static func shippedStyles(
        family: String,
        size: CGFloat,
        in directory: URL? = ShippedResources.fontDirectory
    ) -> [CTFont]? {
        let files = Ubiquitty.Rendering.bundledFaceFiles(std.string(family.trimmingCharacters(in: .whitespaces)))
        guard
            let shipped = shippedFaces(
                files,
                in: directory,
                size: size,
                weights: Ubiquitty.Rendering.Font.WeightSettings(upright: 0, bold: 0, uprightVariation: .nan),
                widthPercent: 0,
                userAxes: Ubiquitty.Rendering.FontVariationSettings(),
                boldUserAxes: Ubiquitty.Rendering.FontVariationSettings(),
                features: []
            )
        else {
            return nil
        }
        return shipped.faces
    }

    /// Whether a face carries the OpenType `wght` axis.
    ///
    /// - Parameter font: The face.
    /// - Returns: Whether it varies in weight.
    private static func hasWeightAxis(_ font: CTFont) -> Bool {
        (CTFontCopyVariationAxes(font) as? [[String: Any]] ?? [])
            .contains { ($0[kCTFontVariationAxisIdentifierKey as String] as? UInt32) == weightAxisTag }
    }

    /// Slants a face by shear, for a family shipping no italic of its own.
    ///
    /// The matrix is applied at creation rather than to the drawing context, so
    /// the glyph the rasteriser measures is the glyph it draws — a shear applied
    /// later moves the ink outside the bounds the slot was sized from, and the
    /// stems clip on the trailing edge.
    ///
    /// 0.2 is the skew, about 11 degrees: enough to read as italic beside the
    /// upright, short of the distortion that a steeper slant puts into the
    /// glyph's height.
    ///
    /// - Parameters:
    ///   - base: The upright face to slant.
    ///   - size: The point size to rebuild at.
    /// - Returns: The slanted face, or nil if CoreText declines the matrix.
    private static func slanted(_ base: CTFont, size: CGFloat) -> CTFont? {
        var shear = CGAffineTransform(a: 1.0, b: 0.0, c: 0.2, d: 1.0, tx: 0.0, ty: 0.0)
        return CTFontCreateCopyWithAttributes(base, size, &shear, nil)
    }
}
