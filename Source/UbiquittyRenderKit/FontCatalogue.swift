// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FontCatalogue.swift — the CoreText side of Core's font routing.
//
// Core decides which face a code point belongs in: the cascade order, the
// script classification, the Han width rule and the emoji presentation rule are
// all `FontFallbackPolicy` and none of them are here. What this supplies is the
// part CoreText alone can answer — does this face carry this character, and what
// does the system offer when it does not.
//
// Faces cross the seam as `FontHandle`, two integers rather than a pointer,
// which is what lets the catalogue be written in a language Core knows nothing
// about. The handle indexes a table held here; Core never sees a CTFont and
// never has to know one exists.
//
// Interning is by CFEqual over a linear scan, not a hash. The table holds the
// primary family's faces plus whatever the system cascade has returned so far —
// a handful for a session, tens at worst — and a scan over that is cheaper than
// hashing a CFTypeRef, on a path that runs per glyph miss rather than per cell.

import CoreText
import Foundation
import UbiquittyCore

/// The faces this frontend can draw with, addressed by handle.
///
/// One per renderer. Not thread-safe: Core calls into it from the frame build,
/// which is the only caller, and adding a lock would pay for a contention that
/// cannot happen.
final class FontCatalogue {
    /// Owns fixed-address UTF-8 bytes for the lifetime of an interned name.
    private final class StoredName {
        let value: String
        private let storage: UnsafeMutablePointer<CChar>
        private let count: Int

        init(_ value: String) {
            self.value = value
            let bytes = value.utf8CString
            count = bytes.count
            storage = .allocate(capacity: count)
            for (index, byte) in bytes.enumerated() {
                storage.advanced(by: index).initialize(to: byte)
            }
        }

        deinit {
            storage.deinitialize(count: count)
            storage.deallocate()
        }

        var view: std.string_view {
            std.string_view(storage)
        }
    }

    private struct CascadeKey: Hashable {
        let base: CTFont
        let codePoints: [UInt32]
        let language: String?
        let presentation: UInt8

        static func == (left: Self, right: Self) -> Bool {
            CFEqual(left.base, right.base) && left.codePoints == right.codePoints && left.language == right.language
                && left.presentation == right.presentation
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(base))
            hasher.combine(codePoints)
            hasher.combine(language)
            hasher.combine(presentation)
        }
    }

    private struct CascadeAnswer {
        let font: CTFont?
    }

    private struct ClusterProbeKey: Hashable {
        let font: CTFont
        let codePoints: [UInt32]
        let presentation: UInt8

        static func == (left: Self, right: Self) -> Bool {
            CFEqual(left.font, right.font) && left.codePoints == right.codePoints && left.presentation == right.presentation
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(font))
            hasher.combine(codePoints)
            hasher.combine(presentation)
        }
    }

    private var clusterProbes: [ClusterProbeKey: CGGlyph] = [:]
    private struct FamilyKey: Hashable {
        let family: String
        let style: UInt8
        let variableWeight: UInt8
        let sizingBase: UInt32
        let sizing: UInt8
    }

    private struct FamilyVariant {
        let source: CTFont
        let font: CTFont
    }

    private var adoptedFamilies: [String: CTFont] = [:]
    private var familyVariants: [FamilyKey: FamilyVariant] = [:]
    private var cascadeAnswers: [CascadeKey: CascadeAnswer] = [:]
    private static let cascadeLimit = 16384

    private(set) var nativeCascadeQueryCount = 0
    private(set) var nativeCoverageRejectCount = 0
    private var nativeTextCoverage: CFCharacterSet?
    private var didPrepareNativeTextCoverage = false
    private static let maxNativeFonts = 4096

    /// A conservative union of text-font cmap coverage rejects unsupported
    /// scalars before CoreText performs a system-wide cascade search.
    func prepareNativeTextCoverage() {
        guard !didPrepareNativeTextCoverage else { return }
        didPrepareNativeTextCoverage = true
        let names = CTFontManagerCopyAvailablePostScriptNames() as! [String]
        guard !names.isEmpty, names.count <= Self.maxNativeFonts, let coverage = CFCharacterSetCreateMutable(nil) else { return }
        var isComplete = true
        for name in names where name != "LastResort" {
            if !isComplete { break }
            autoreleasepool {
                let descriptor = CTFontDescriptorCreateWithNameAndSize(name as CFString, 12)
                guard let value = CTFontDescriptorCopyAttribute(descriptor, kCTFontCharacterSetAttribute),
                    CFGetTypeID(value) == CFCharacterSetGetTypeID()
                else {
                    isComplete = false
                    return
                }
                let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? NSDictionary
                let symbolic = traits?[kCTFontSymbolicTrait] as? NSNumber
                if CTFontSymbolicTraits(rawValue: symbolic?.uint32Value ?? 0).contains(.traitColorGlyphs) { return }
                // The type identifier check above is what makes this cast total.
                let characterSet = value as! CFCharacterSet
                CFCharacterSetUnion(coverage, characterSet)
            }
        }
        // A partial inventory cannot prove absence. Keep native searching if
        // any descriptor omits its coverage instead of rejecting valid text.
        if isComplete { nativeTextCoverage = CFCharacterSetCreateCopy(nil, coverage) }
    }

    /// Publishes only native cascade answers; live routing policy and handles stay owned here.
    func adoptPreparedCascades(from source: FontCatalogue) {
        if nativeTextCoverage == nil { nativeTextCoverage = source.nativeTextCoverage }
        didPrepareNativeTextCoverage = didPrepareNativeTextCoverage || source.didPrepareNativeTextCoverage
        for (key, answer) in source.cascadeAnswers where cascadeAnswers[key] == nil {
            if cascadeAnswers.count == Self.cascadeLimit { break }
            cascadeAnswers[key] = answer
        }
    }

    /// The faces minted so far.
    ///
    /// A handle's value is its index plus one, so zero
    /// stays the invalid handle Core tests for.
    private var faces: [CTFont] = []
    /// Family and PostScript names, NUL-terminated and parallel to ``faces``.
    ///
    /// Held rather than derived per call because the seam returns
    /// `std::string_view`, which borrows: a view over a string built inside the
    /// callback would dangle the moment it returned.
    private var names: [(family: StoredName, postScript: StoredName)] = []
    /// The generation handles are minted against.
    private var generation: UInt32 = 1

    /// The configured family's faces, which every route starts from.
    private let primary: FontFaces
    private let shouldMatchFallbackSize: Bool

    /// Creates a catalogue over a resolved family.
    ///
    /// - Parameter primary: The configured family's faces.
    init(primary: FontFaces, shouldMatchFallbackSize: Bool = true) {
        self.primary = primary
        self.shouldMatchFallbackSize = shouldMatchFallbackSize
    }

    /// Copies routing state before transferring the copy to a preparation worker.
    func preparationCopy() -> FontCatalogue {
        let copy = FontCatalogue(primary: primary, shouldMatchFallbackSize: shouldMatchFallbackSize)
        copy.nativeTextCoverage = nativeTextCoverage
        copy.didPrepareNativeTextCoverage = didPrepareNativeTextCoverage
        copy.faces = faces
        copy.names = names.map { (StoredName($0.family.value), StoredName($0.postScript.value)) }
        copy.generation = generation
        copy.weighted = weighted
        copy.cascadeAnswers = cascadeAnswers
        copy.clusterProbes = clusterProbes
        copy.adoptedFamilies = adoptedFamilies
        copy.familyVariants = familyVariants
        return copy
    }

    // MARK: - Handles

    /// Returns the handle for a face, minting one if it is new.
    ///
    /// - Parameter font: The face to address.
    /// - Returns: Its handle, valid for the current generation.
    private func handle(for font: CTFont) -> Ubiquitty.Rendering.Font.FontHandle {
        var out = Ubiquitty.Rendering.Font.FontHandle()
        out.generation = generation
        if let index = faces.firstIndex(where: { CFEqual($0, font) }) {
            out.value = UInt32(index + 1)
            return out
        }
        faces.append(font)
        names.append(
            (
                StoredName(CTFontCopyFamilyName(font) as String),
                StoredName(CTFontCopyPostScriptName(font) as String)
            )
        )
        out.value = UInt32(faces.count)
        return out
    }

    /// The face a handle addresses, or nil if it names none.
    ///
    /// - Parameter handle: The handle to resolve.
    /// - Returns: The face, or nil for an invalid or stale handle.
    private func font(for handle: Ubiquitty.Rendering.Font.FontHandle) -> CTFont? {
        let index = Int(handle.value)
        guard handle.generation == generation, index > 0, index <= faces.count else {
            return nil
        }
        return faces[index - 1]
    }

    /// Interns a fallback face so family requests can resolve it.
    ///
    /// The bundled symbol font is loaded from its file and never registered,
    /// so family validation retains its source face for style derivation.
    ///
    /// - Parameter font: The face to intern.
    func adoptFallbackFace(_ font: CTFont) {
        adoptedFamilies[(CTFontCopyFamilyName(font) as String).lowercased()] = font
        _ = handle(for: font)
    }

    func isVariant(_ font: CTFont, of source: CTFont) -> Bool {
        font === source || familyVariants.values.contains { $0.source === source && $0.font === font }
    }

    private func familyFont(_ family: String, request: Ubiquitty.Rendering.Font.FontFamilyRequest) -> CTFont? {
        let style = request.style
        let variableWeight = request.variableWeight
        let key = FamilyKey(
            family: family.lowercased(),
            style: style.rawValue,
            variableWeight: variableWeight,
            sizingBase: request.sizingBase.value,
            sizing: request.sizing.rawValue
        )
        if let cached = familyVariants[key] { return cached.font }
        let source = adoptedFamilies[key.family] ?? CTFontCreateWithName(family as CFString, primary.size, nil)
        // A missing family silently resolves to an unrelated system face.
        guard (CTFontCopyFamilyName(source) as String).compare(family, options: .caseInsensitive) == .orderedSame else { return nil }
        var variant = FontFaces.fallbackFace(from: source, style: style, variableWeight: variableWeight)
        if let base = font(for: request.sizingBase) {
            variant = matchingFallbackSize(variant, to: base, sizing: request.sizing)
        }
        let canonical = font(for: handle(for: variant))!
        familyVariants[key] = FamilyVariant(source: source, font: canonical)
        return canonical
    }

    /// The face a handle addresses, for the caller that owns this catalogue.
    ///
    /// The routing policy answers in handles; the rasterise site needs the
    /// CTFont behind one to draw with.
    ///
    /// - Parameter handle: The handle to resolve.
    /// - Returns: The face, or nil for an invalid or stale handle.
    func resolvedFont(for handle: Ubiquitty.Rendering.Font.FontHandle) -> CTFont? {
        font(for: handle)
    }

    // MARK: - CoreText answers

    /// Whether a face carries a glyph for one code point, and which glyph.
    ///
    /// - Parameters:
    ///   - font: The face to probe.
    ///   - codePoint: The character wanted.
    /// - Returns: The glyph identifier, or zero when the face has none.
    private func glyph(in font: CTFont, for codePoint: UInt32) -> CGGlyph {
        var utf16: [UInt16] = []
        if codePoint <= 0xFFFF {
            utf16 = [UInt16(codePoint)]
        } else {
            let v = codePoint - 0x10000
            utf16 = [UInt16(0xD800 + (v >> 10)), UInt16(0xDC00 + (v & 0x3FF))]
        }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else {
            return 0
        }
        return glyphs[0]
    }

    private func glyph(in font: CTFont, for codePoints: [UInt32], presentation: Ubiquitty.Rendering.Font.Presentation) -> CGGlyph {
        guard !codePoints.isEmpty else { return 0 }
        let color = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        if (presentation == .Emoji && !color) || (presentation == .Text && color) { return 0 }
        if codePoints.count == 1, Ubiquitty.Rendering.Font.classifyScript(codePoints[0]) != .Emoji {
            return glyph(in: font, for: codePoints[0])
        }
        let key = ClusterProbeKey(font: font, codePoints: codePoints, presentation: presentation.rawValue)
        if let cached = clusterProbes[key] { return cached }
        var text = ""
        for codePoint in codePoints {
            guard let scalar = Unicode.Scalar(codePoint) else { return 0 }
            text.unicodeScalars.append(scalar)
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        )
        var firstGlyph: CGGlyph = 0
        var present = true
        let graphicsFont = CTFontCopyGraphicsFont(font, nil)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            // Shaping may change descriptor attributes without changing the face.
            guard CFEqual(graphicsFont, CTFontCopyGraphicsFont(runFont, nil)) else {
                present = false
                break
            }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            if glyphs.contains(0) {
                present = false
                break
            }
            if firstGlyph == 0 { firstGlyph = glyphs.first ?? 0 }
        }
        let answer = present ? firstGlyph : 0
        if clusterProbes.count < Self.cascadeLimit { clusterProbes[key] = answer }
        return answer
    }

    /// The face the system offers for a run the base face cannot draw.
    ///
    /// - Parameters:
    ///   - base: The face that came up short.
    ///   - codePoints: The characters to cover.
    ///   - language: The requested localization, or nil for the system default.
    ///   - presentation: Whether text or color glyphs are required.
    /// - Returns: The substitute face, or nil when the system offers none.
    private func cascade(
        from base: CTFont,
        over codePoints: [UInt32],
        language: String?,
        presentation: Ubiquitty.Rendering.Font.Presentation
    ) -> CTFont? {
        let key = CascadeKey(base: base, codePoints: codePoints, language: language, presentation: presentation.rawValue)
        if let answer = cascadeAnswers[key] { return answer.font }
        if codePoints.count == 1, presentation == .Text, let coverage = nativeTextCoverage,
            !CFCharacterSetIsLongCharacterMember(coverage, codePoints[0])
        {
            nativeCoverageRejectCount += 1
            return nil
        }
        var utf16: [UInt16] = []
        for codePoint in codePoints {
            if codePoint <= 0xFFFF {
                utf16.append(UInt16(codePoint))
            } else {
                let v = codePoint - 0x10000
                utf16.append(UInt16(0xD800 + (v >> 10)))
                utf16.append(UInt16(0xDC00 + (v & 0x3FF)))
            }
        }
        guard !utf16.isEmpty else {
            return nil
        }
        if codePoints.count == 1, presentation != .Default {
            utf16.append(presentation == .Emoji ? 0xFE0F : 0xFE0E)
        }
        let text = String(decoding: utf16, as: UTF16.self) as CFString
        nativeCascadeQueryCount += 1
        let font = CTFontCreateForStringWithLanguage(base, text, CFRangeMake(0, utf16.count), language as CFString?)
        if isLastResortFace(font) { return nil }
        let hasRequestedGlyphs =
            codePoints.count > 1 || presentation != .Default
            ? glyph(in: font, for: codePoints, presentation: presentation) != 0
            : glyph(in: font, for: codePoints[0]) != 0
        let answer = hasRequestedGlyphs ? matchingFallbackSize(font, to: base) : nil
        if cascadeAnswers.count < Self.cascadeLimit {
            cascadeAnswers[key] = CascadeAnswer(font: answer)
        }
        return answer
    }

    /// Native fallback faces share the primary's visible text size and baseline.
    /// Emoji have their own cell-fitting path and keep their native size.
    private func matchingFallbackSize(
        _ font: CTFont,
        to base: CTFont,
        sizing: Ubiquitty.Rendering.FontMetrics.FallbackSizing = .Inherit
    ) -> CTFont {
        let shouldMatch = sizing == .MatchPrimary || (sizing == .Inherit && shouldMatchFallbackSize)
        guard shouldMatch, !CFEqual(font, base), !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return font }
        func metrics(_ face: CTFont) -> Ubiquitty.Rendering.FontMetrics.FallbackMetrics {
            let size = CTFontGetSize(face)
            guard size.isFinite, size > 0 else { return .init() }
            return .init(
                xHeight: CTFontGetXHeight(face) / size,
                capHeight: CTFontGetCapHeight(face) / size,
                lineHeight: (CTFontGetAscent(face) + CTFontGetDescent(face) + CTFontGetLeading(face)) / size
            )
        }
        let scale = Ubiquitty.Rendering.FontMetrics.fallbackScale(metrics(base), metrics(font))
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(base) * scale, nil, nil)
    }

    // MARK: - Variable weight

    /// Faces built on the `wght` axis, keyed by SGR 1:n weight 1...7.
    ///
    /// Cached because a variation copy is a descriptor round-trip, and a run of
    /// weighted text asks for the same one on every glyph miss.
    private var weighted: [UInt8: CTFont] = [:]

    /// The primary regular face at a variable weight.
    ///
    /// Weight supersedes face selection: a cell carrying SGR 1:n takes its axis
    /// value rather than the bold face, so the two cannot both apply and produce
    /// a double-emboldened glyph.
    ///
    /// - Parameter weight: The SGR weight 1...7, where 0 means the face's own.
    /// - Returns: The varied face, or the regular one if the family has no axis.
    private func weightedFace(_ weight: UInt8) -> CTFont {
        let regular = primary[Ubiquitty.Rendering.FontFace.Regular]
        guard weight > 0, weight <= 7 else {
            return regular
        }
        if let cached = weighted[weight] {
            return cached
        }
        // The axis value is Core's: SGR carries 1...7 and the font wants a point
        // on the wght axis, and two frontends choosing different curves render one
        // document at different weights.
        let axis: [CFString: Any] = [
            kCTFontVariationAttribute: [
                UInt32(Ubiquitty.Rendering.variationAxisTagWeight): Double(Ubiquitty.Rendering.Font.variationWeightForSGR(weight))
            ]
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(axis as CFDictionary)
        let varied = CTFontCreateCopyWithAttributes(regular, CTFontGetSize(regular), nil, descriptor)
        weighted[weight] = varied
        return varied
    }

    /// The face for one of Core's font styles.
    ///
    /// Mapped by name rather than by raw value: two enums that happen to agree
    /// on their ordering are one reordering away from routing bold text through
    /// the italic face, and nothing downstream could attribute that.
    ///
    /// - Parameter style: The style Core resolved.
    /// - Returns: The matching face.
    private func face(for style: Ubiquitty.Rendering.Font.FontStyle) -> CTFont {
        switch style {
        case .Regular: return primary[Ubiquitty.Rendering.FontFace.Regular]
        case .Bold: return primary[Ubiquitty.Rendering.FontFace.Bold]
        case .Italic: return primary[Ubiquitty.Rendering.FontFace.Italic]
        case .BoldItalic: return primary[Ubiquitty.Rendering.FontFace.BoldItalic]
        default: return primary[Ubiquitty.Rendering.FontFace.Regular]
        }
    }

    // MARK: - The seam

    /// Builds the table Core's routing calls into.
    ///
    /// Borrows this catalogue: the table carries a raw pointer to it, so it is
    /// valid only while the catalogue lives. Core never sees a CTFont — a face
    /// crosses as a `FontHandle`, which is two integers.
    ///
    /// - Returns: The filled table, satisfying `isComplete`.
    func inventoryTable() -> Ubiquitty.Rendering.Font.FontInventoryTable {
        var table = Ubiquitty.Rendering.Font.FontInventoryTable()
        table.context = Unmanaged.passUnretained(self).toOpaque()
        table.catalogGeneration = { context in
            FontCatalogue.of(context).generation
        }
        table.bumpCatalogGeneration = { context in
            FontCatalogue.of(context).generation &+= 1
        }
        table.primaryFont = { context, style, variableWeight in
            let catalogue = FontCatalogue.of(context)
            let font = variableWeight > 0 ? catalogue.weightedFace(variableWeight) : catalogue.face(for: style)
            return catalogue.handle(for: font)
        }
        table.validateFamily = { context, request in
            let catalogue = FontCatalogue.of(context)
            guard let request, let name = FontCatalogue.string(request.pointee.family), !name.isEmpty,
                let font = catalogue.familyFont(name, request: request.pointee)
            else {
                return Ubiquitty.Rendering.Font.FontHandle()
            }
            return catalogue.handle(for: font)
        }
        table.glyphForCodePoint = { context, font, codePoint in
            let catalogue = FontCatalogue.of(context)
            var result = Ubiquitty.Rendering.Font.GlyphProbeResult()
            result.font = font
            guard let face = catalogue.font(for: font) else {
                return result
            }
            let glyph = catalogue.glyph(in: face, for: codePoint)
            result.glyph.value = UInt32(glyph)
            result.present = glyph != 0
            result.lastResort = catalogue.isLastResortFace(face)
            return result
        }
        table.glyphForCluster = { context, request in
            let catalogue = FontCatalogue.of(context)
            var result = Ubiquitty.Rendering.Font.GlyphProbeResult()
            guard let request else { return result }
            result.font = request.pointee.font
            guard let font = catalogue.font(for: request.pointee.font) else { return result }
            let codePoints = request.pointee.codePoints
            var points: [UInt32] = []
            points.reserveCapacity(Int(codePoints.size()))
            for index in 0..<Int(codePoints.size()) { points.append(codePoints[index]) }
            let glyph = catalogue.glyph(in: font, for: points, presentation: request.pointee.presentation)
            result.glyph.value = UInt32(glyph)
            result.present = glyph != 0
            result.lastResort = catalogue.isLastResortFace(font)
            return result
        }
        table.cascadeForCodePoint = { context, request in
            FontCatalogue.of(context).cascadeResult(request)
        }
        table.cascadeForRun = { context, request in
            FontCatalogue.of(context).cascadeResult(request)
        }
        table.isLastResort = { context, handle in
            let catalogue = FontCatalogue.of(context)
            guard let face = catalogue.font(for: handle) else {
                return false
            }
            return catalogue.isLastResortFace(face)
        }
        table.familyName = { context, handle in
            FontCatalogue.of(context).view(handle) { $0.family }
        }
        table.postScriptName = { context, handle in
            FontCatalogue.of(context).view(handle) { $0.postScript }
        }
        return table
    }

    /// Resolves the catalogue from the pointer Core passes an entry.
    ///
    /// - Parameter context: The opaque pointer the table was built with.
    /// - Returns: The catalogue it addresses.
    private static func of(_ context: UnsafeMutableRawPointer?) -> FontCatalogue {
        Unmanaged<FontCatalogue>.fromOpaque(context!).takeUnretainedValue()
    }

    /// Resolves the catalogue from a const context pointer.
    ///
    /// The entries Core marks const hand back an immutable pointer, and
    /// `Unmanaged` takes a mutable one. Casting here rather than at three call
    /// sites keeps the const-ness of the seam readable at the seam.
    ///
    /// - Parameter context: The opaque pointer the table was built with.
    /// - Returns: The catalogue it addresses.
    private static func of(_ context: UnsafeRawPointer?) -> FontCatalogue {
        Unmanaged<FontCatalogue>.fromOpaque(UnsafeMutableRawPointer(mutating: context!)).takeUnretainedValue()
    }

    /// Copies a borrowed `string_view` into a Swift string.
    ///
    /// - Parameter view: The view Core passed.
    /// - Returns: The string, or nil when the view is empty.
    private static func string(_ view: std.string_view) -> String? {
        guard view.size() > 0, let base = view.__dataUnsafe() else {
            return nil
        }
        return String(
            decoding: UnsafeBufferPointer(start: base, count: Int(view.size()))
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    /// Whether a face is the system's last-resort fallback.
    ///
    /// - Parameter font: The face to test.
    /// - Returns: Whether the system offered it because nothing else matched.
    private func isLastResortFace(_ font: CTFont) -> Bool {
        (CTFontCopyPostScriptName(font) as String) == "LastResort"
    }

    /// A borrowed view over one of a face's stored names.
    ///
    /// - Parameters:
    ///   - handle: The face whose name is wanted.
    ///   - pick: Which of the two stored names to view.
    /// - Returns: A view over storage this catalogue owns, empty for a bad handle.
    private func view(
        _ handle: Ubiquitty.Rendering.Font.FontHandle,
        _ pick: ((family: StoredName, postScript: StoredName)) -> StoredName
    ) -> std.string_view {
        let index = Int(handle.value)
        guard handle.generation == generation, index > 0, index <= names.count else {
            return std.string_view()
        }
        return pick(names[index - 1]).view
    }

    /// The cascade answer for a request, as Core's result type.
    ///
    /// - Parameter request: The base face and characters to route.
    /// - Returns: The substitute face and its glyph, or an absent result.
    private func cascadeResult(
        _ request: UnsafePointer<Ubiquitty.Rendering.Font.CascadeRequest>?
    )
        -> Ubiquitty.Rendering.Font.CascadeResult
    {
        var result = Ubiquitty.Rendering.Font.CascadeResult()
        guard let request else {
            return result
        }
        let codePoints = request.pointee.codePoints
        guard let base = font(for: request.pointee.baseFont),
            codePoints.size() > 0
        else {
            return result
        }
        var points: [UInt32] = []
        for i in 0..<Int(codePoints.size()) {
            points.append(codePoints[i])
        }
        let language = Self.string(request.pointee.language.value)
        guard let substitute = cascade(from: base, over: points, language: language, presentation: request.pointee.presentation) else {
            return result
        }
        result.font = handle(for: substitute)
        let glyph = glyph(in: substitute, for: points[0])
        result.glyph.value = UInt32(glyph)
        result.present = glyph != 0
        result.lastResort = isLastResortFace(substitute)
        return result
    }
}
