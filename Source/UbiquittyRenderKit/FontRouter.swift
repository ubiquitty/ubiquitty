// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FontRouter.swift — Core's fallback routing, held for the Swift rasterisers.
//
// The policy is Core's: the cascade order, the script classification, the Han
// width rule and the emoji presentation rule all live in FontFallbackPolicy,
// and this file only assembles requests for it, so every arm routes a code
// point to the same face; otherwise a pixel comparison charges the difference
// to whichever raster ran second.
//
// What this owns is the plumbing Core cannot: the catalogue of CTFonts, the
// session of caches at a stable address, and the byte storage the borrowed
// string views point into for the router's whole life.

import CoreText
import Foundation
import UbiquittyCore

/// Routes code points the primary family lacks to fallback faces.
///
/// One per atlas. Not thread-safe, for the reason the catalogue is not: the
/// rasterise paths are the only callers and they run on one thread.
package final class FontRouter {
    private let catalogue: FontCatalogue
    private var table: Ubiquitty.Rendering.Font.FontInventoryTable
    /// The caches, allocated for their stable address: the route call takes
    /// the session by reference and Swift's stored properties promise none.
    private let session: UnsafeMutablePointer<Ubiquitty.Rendering.Font.FontRoutingSession>
    /// The configuration's own routing preferences, allocated for their stable
    /// address: `view()` hands out spans and views borrowing this object's
    /// storage, and a Swift stored property promises no address at all. Held
    /// for the router's whole life, which is as long as any view it lends.
    ///
    /// The two families this arm resolves itself are written over the
    /// configured spelling after the build, because a family that did not
    /// resolve must route nowhere rather than name a face nobody has.
    private let configuration: Ubiquitty.Preferences.Values
    private let routePreferences: UnsafeMutablePointer<Ubiquitty.Preferences.FontRoutePreferences>
    /// The CJK fallback language tag, NUL-terminated; empty for none. This one
    /// rides the request rather than the preferences, so it stays here.
    private let cjkLanguageBytes: [CChar]

    /// The symbol fallback face this router adopted, or nil when none loaded.
    ///
    /// Held so a rasterise path can recognise it: a glyph drawn from this face
    /// is positioned by centring its ink on the cell box rather than by the
    /// plain pen, because the face's em differs from the primary's and its ink
    /// overhangs the box the cell quad samples.
    private let symbolFallbackFace: CTFont?

    /// The bundled symbol face, adopted beside a configured symbol family that
    /// is not it, or nil when it is the symbol face or did not load.
    ///
    /// Core's policy routes a private-use character the configured family
    /// lacks to the bundled family by name, and this is the face that name
    /// resolves to: the bundled file is loaded through its descriptors and
    /// never registered, so a by-name lookup would not find it.
    private let bundledSymbolFace: CTFont?

    /// The symbol fallback face a configuration names, at a size, or nil.
    ///
    /// The one resolution the measurement and the router share, so the face
    /// whose bounding box grows the slot is the face the glyphs are drawn
    /// from. The configured family is tried first and accepted only when the
    /// resolved family matches what was asked for — the by-name lookup
    /// substitutes the system font for a name it does not know — and the
    /// bundled file is the fallback, loaded through its descriptors and never
    /// registered.
    ///
    /// - Parameters:
    ///   - size: The em size the primary faces are built at.
    ///   - familyName: The configured symbol family, or empty for none.
    ///   - fontPath: The bundled symbol font's file path, or empty.
    /// - Returns: The face, or nil when neither resolves.
    package static func symbolFallbackFace(size: CGFloat, familyName: String, fontPath: String) -> CTFont? {
        if !familyName.isEmpty {
            let named = CTFontCreateWithName(familyName as CFString, size, nil)
            let resolved = CTFontCopyFamilyName(named) as String
            if resolved.compare(familyName, options: .caseInsensitive) == .orderedSame {
                return named
            }
        }
        if !fontPath.isEmpty,
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL)
                as? [CTFontDescriptor],
            let first = descriptors.first
        {
            return CTFontCreateWithFontDescriptor(first, size, nil)
        }
        return nil
    }

    /// Builds a router over a primary family and its configured fallbacks.
    ///
    /// The fallback faces are created here, at the primary's own size, from
    /// the strings the frontend resolved: a family name for the CJK
    /// preference, and a file path for the bundled symbol face — loaded
    /// through its descriptors and never registered, then adopted into the
    /// catalogue because an unregistered face cannot resolve through the
    /// system lookup.
    ///
    /// - Parameters:
    ///   - primary: The configured family's faces.
    ///   - cjkFamilyName: The configured CJK family, or empty for none.
    ///   - cjkLanguage: The Han disambiguation language tag, or empty.
    ///   - symbolFamilyName: The configured symbol family, or empty for none.
    ///     Tried first, and accepted only when the resolved family matches what
    ///     was asked for: the by-name lookup substitutes the system font for a
    ///     name it does not know, so an unverified result is a face nobody chose.
    ///   - symbolFontPath: The bundled symbol font's file path, or empty. Used
    ///     when the configured family is absent or did not resolve: a
    ///     configured family that resolves and lacks the glyphs must draw its
    ///     own tofu rather than be quietly replaced by the bundle.
    ///   - configuration: The effective routing rules owned by this renderer.
    package init(
        primary: FontFaces,
        cjkFamilyName: String,
        cjkLanguage: String,
        symbolFamilyName: String,
        symbolFontPath: String,
        configuration: Ubiquitty.Preferences.Values
    ) {
        self.configuration = configuration
        catalogue = FontCatalogue(
            primary: primary,
            shouldMatchFallbackSize: Ubiquitty.Preferences.Effective.matchFallbackSize(configuration)
        )
        let size = CTFontGetSize(primary[Ubiquitty.Rendering.FontFace.Regular])
        var cjkFamily = ""
        if !cjkFamilyName.isEmpty {
            let candidate = CTFontCreateWithName(cjkFamilyName as CFString, size, nil)
            // CTFont substitutes rather than failing; a substituted family
            // must not become the routed answer for every Han cell.
            if (CTFontCopyFamilyName(candidate) as String).compare(cjkFamilyName, options: .caseInsensitive) == .orderedSame {
                catalogue.adoptFallbackFace(candidate)
                cjkFamily = cjkFamilyName
            }
        }
        let symbolFace = FontRouter.symbolFallbackFace(size: size, familyName: symbolFamilyName, fontPath: symbolFontPath)
        symbolFallbackFace = symbolFace
        var symbolFamily = ""
        if let symbolFace {
            catalogue.adoptFallbackFace(symbolFace)
            symbolFamily = CTFontCopyFamilyName(symbolFace) as String
        }
        let bundledFace = FontRouter.symbolFallbackFace(size: size, familyName: "", fontPath: symbolFontPath)
        if let bundledFace, symbolFace.map({ !CFEqual($0, bundledFace) }) ?? true {
            catalogue.adoptFallbackFace(bundledFace)
            bundledSymbolFace = bundledFace
        } else {
            bundledSymbolFace = nil
        }
        cjkLanguageBytes = cjkLanguage.utf8CString.map { $0 }
        routePreferences = .allocate(capacity: 1)
        routePreferences.initialize(
            to: Ubiquitty.Preferences.buildFontRoutePreferences(configuration)
        )
        routePreferences.pointee.cjkFallbackFamily = std.string(cjkFamily)
        routePreferences.pointee.symbolFallbackFamily = std.string(symbolFamily)
        table = catalogue.inventoryTable()
        session = .allocate(capacity: 1)
        session.initialize(to: Ubiquitty.Rendering.Font.FontRoutingSession())
    }

    private struct ScalarRouteKey: Hashable {
        let codePoint: UInt32
        let isBold: Bool
        let isItalic: Bool
        let variableWeight: UInt8
        let wantsEmoji: Bool
    }

    private struct ScalarRouteAnswer {
        let font: CTFont?
    }

    private(set) var scalarRouteMissCount = 0
    private var scalarRoutes: [ScalarRouteKey: ScalarRouteAnswer] = [:]
    private var scalarRouteOrder: [ScalarRouteKey] = []
    private var nextScalarRoute = 0
    private var preparedScalarKeys: [ScalarRouteKey] = []
    private var collectsPreparedRoutes = false
    private static let scalarRouteCapacity = 65536

    private func storeScalarRoute(_ answer: ScalarRouteAnswer, for key: ScalarRouteKey) {
        guard scalarRoutes[key] == nil else { return }
        if scalarRouteOrder.count == Self.scalarRouteCapacity {
            scalarRoutes.removeValue(forKey: scalarRouteOrder[nextScalarRoute])
            scalarRouteOrder[nextScalarRoute] = key
            nextScalarRoute = (nextScalarRoute + 1) % Self.scalarRouteCapacity
        } else {
            scalarRouteOrder.append(key)
        }
        scalarRoutes[key] = answer
        if collectsPreparedRoutes { preparedScalarKeys.append(key) }
    }

    private init(copying source: FontRouter) {
        configuration = source.configuration
        catalogue = source.catalogue.preparationCopy()
        table = catalogue.inventoryTable()
        session = .allocate(capacity: 1)
        session.initialize(to: source.session.pointee)
        routePreferences = .allocate(capacity: 1)
        routePreferences.initialize(to: Ubiquitty.Preferences.buildFontRoutePreferences(configuration))
        routePreferences.pointee.cjkFallbackFamily = source.routePreferences.pointee.cjkFallbackFamily
        routePreferences.pointee.symbolFallbackFamily = source.routePreferences.pointee.symbolFallbackFamily
        cjkLanguageBytes = source.cjkLanguageBytes
        symbolFallbackFace = source.symbolFallbackFace
        bundledSymbolFace = source.bundledSymbolFace
        scalarRoutes = source.scalarRoutes
        scalarRouteOrder = source.scalarRouteOrder
        nextScalarRoute = source.nextScalarRoute
        collectsPreparedRoutes = true
    }

    func prepareNativeTextCoverage() { catalogue.prepareNativeTextCoverage() }

    func preparationCopy() -> FontRouter { FontRouter(copying: self) }

    func adoptPreparedCascades(from source: FontRouter) {
        catalogue.adoptPreparedCascades(from: source.catalogue)
        for key in source.preparedScalarKeys {
            if let answer = source.scalarRoutes[key] { storeScalarRoute(answer, for: key) }
        }
    }

    deinit {
        session.deinitialize(count: 1)
        session.deallocate()
        routePreferences.deinitialize(count: 1)
        routePreferences.deallocate()
    }

    /// Resolves the face for a code point the primary family lacks.
    ///
    /// In the request, the presentation follows the caller's emoji intent
    /// alone — Core's Attribute::Emoji is the one source of truth, and
    /// re-deriving it from the script class makes the mono-versus-color choice
    /// toolchain-gated — and the width class follows the unified-Han test,
    /// which is what points Han at the CJK preference rather than the generic
    /// cascade.
    ///
    /// - Parameters:
    ///   - codePoint: The character being drawn.
    ///   - face: Bold and italic, which pick the style.
    ///   - variableWeight: The `wght` axis value, or zero.
    ///   - wantsEmoji: Whether the cell's emoji attribute routed it here.
    /// - Returns: The routed face, or nil when nothing carries the glyph.
    /// Whether a face is an adopted symbol face, configured or bundled, or one of
    /// its styled variants.
    ///
    /// Identity, not equality. A configured symbol family may be the primary
    /// family — `symbol_fallback` naming the text font is a legitimate way to ask
    /// for that font's own tofu — and two faces of one family at one size are
    /// equal by value. Comparing by value would then apply the symbol positioning
    /// to every ordinary glyph in the frame.
    ///
    /// - Parameter font: The face a rasterise path is about to draw with.
    /// - Returns: Whether it belongs to the adopted symbol face's variants.
    func isSymbolFallbackFace(_ font: CTFont) -> Bool {
        if let symbolFallbackFace, catalogue.isVariant(font, of: symbolFallbackFace) {
            return true
        }
        guard let bundledSymbolFace else {
            return false
        }
        return catalogue.isVariant(font, of: bundledSymbolFace)
    }

    /// The symbol fallback face this router adopted, or nil when none loaded.
    ///
    /// A reader, not a route: the box family resolves its own face rather than
    /// asking `routedFont`, because a per-code-point cascade would let one
    /// scene's box strokes come from several faces. Two faces are the whole
    /// ladder there — the primary, else this one.
    package var adoptedSymbolFallbackFace: CTFont? {
        symbolFallbackFace
    }

    // swift-only: the generated C++ header drops this package helper, and only Swift callers route through it
    package func routedFont(
        for codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variableWeight: UInt8,
        wantsEmoji: Bool
    ) -> CTFont? {
        let key = ScalarRouteKey(
            codePoint: codePoint,
            isBold: Ubiquitty.Rendering.isBold(face),
            isItalic: Ubiquitty.Rendering.isItalic(face),
            variableWeight: variableWeight,
            wantsEmoji: wantsEmoji
        )
        if let answer = scalarRoutes[key] { return answer.font }
        scalarRouteMissCount += 1
        let points = [codePoint]
        let font = resolveFont(for: points.span, face: face, variableWeight: variableWeight, wantsEmoji: wantsEmoji)
        storeScalarRoute(ScalarRouteAnswer(font: font), for: key)
        return font
    }

    /// Routes a complete cluster through Core's configured fallback order.
    // swift-only: a Span parameter has no C++ thunk, and only Swift callers route clusters through it
    package func routedFont(
        for codePoints: Span<UInt32>,
        face: Ubiquitty.Rendering.FontFace,
        variableWeight: UInt8,
        wantsEmoji: Bool
    ) -> CTFont? {
        if codePoints.count == 1 {
            return routedFont(for: codePoints[0], face: face, variableWeight: variableWeight, wantsEmoji: wantsEmoji)
        }
        return resolveFont(for: codePoints, face: face, variableWeight: variableWeight, wantsEmoji: wantsEmoji)
    }

    private func resolveFont(
        for codePoints: Span<UInt32>,
        face: Ubiquitty.Rendering.FontFace,
        variableWeight: UInt8,
        wantsEmoji: Bool
    ) -> CTFont? {
        guard !codePoints.isEmpty else { return nil }
        let codePoint = codePoints[0]
        let isBold = Ubiquitty.Rendering.isBold(face)
        let isItalic = Ubiquitty.Rendering.isItalic(face)
        let route = codePoints.withUnsafeBufferPointer { buffer in
            var request = Ubiquitty.Rendering.Font.FontRequest()
            request.codePoints = Ubiquitty.Rendering.Font.CodePointSpan(buffer)
            request.script = Ubiquitty.Rendering.Font.classifyScript(codePoint)
            request.presentation = wantsEmoji ? .Emoji : .Text
            request.style =
                isBold
                ? (isItalic ? .BoldItalic : .Bold)
                : (isItalic ? .Italic : .Regular)
            request.variableWeight = variableWeight
            request.width = Ubiquitty.Rendering.Font.isUnifiedHan(codePoint) || wantsEmoji ? .Wide : .Narrow
            let preferences = routePreferences.pointee.view()
            return cjkLanguageBytes.withUnsafeBufferPointer { language in
                if language.count > 1 {
                    request.language = Ubiquitty.Rendering.Font.LanguageTag(value: std.string_view(language.baseAddress!))
                }
                return Ubiquitty.Rendering.Font.routeGlyph(&session.pointee, table, request, preferences)
            }
        }
        // isMissing rather than the route's own truthiness: a route can name
        // a real face whose glyph probe still missed, and drawing from it
        // would ink the notdef box where a missing glyph draws nothing.
        guard !Ubiquitty.Rendering.Font.isMissing(route) else {
            return nil
        }
        return catalogue.resolvedFont(for: route.font)
    }
}

/// Resolves fallback fonts off the frame thread and publishes reusable scalar answers.
final class GlyphFontPreparation: @unchecked Sendable {
    private struct Request: Sendable {
        let codePoint: UInt32
        let face: Ubiquitty.Rendering.FontFace
    }

    /// Owns every mutable object touched by the preparation queue.
    private final class Work: @unchecked Sendable {
        let router: FontRouter?
        let faces: FontFaces
        let requests: [Request]
        private let lock = NSLock()
        private var cancelled = false

        init(router: FontRouter?, faces: FontFaces, requests: [Request]) {
            self.router = router
            self.faces = faces
            self.requests = requests
        }

        func cancel() { lock.withLock { cancelled = true } }

        func perform() {
            if requests.count >= 128 { router?.prepareNativeTextCoverage() }
            for request in requests {
                if lock.withLock({ cancelled }) { return }
                autoreleasepool {
                    if Ubiquitty.Rendering.Font.classifyScript(request.codePoint) == .Emoji {
                        _ = router?.routedFont(for: request.codePoint, face: .Regular, variableWeight: 0, wantsEmoji: true)
                    }
                    let primary = faces[request.face]
                    if GlyphAtlas.glyphIdentifier(for: request.codePoint, in: primary) == nil {
                        _ = router?.routedFont(for: request.codePoint, face: request.face, variableWeight: 0, wantsEmoji: false)
                    }
                }
            }
        }
    }

    private let queue = DispatchQueue(label: "org.ubiquitty.glyph-preparation", qos: .userInitiated)
    private var work: Work?
    private weak var destinationRouter: FontRouter?
    private var prepared = [UInt64](repeating: 0, count: Int(Ubiquitty.Rendering.FrameCapture.fontPreparationStorageWords()))
    private static let batchLimit = 4096

    deinit { work?.cancel() }

    /// Returns false until bounded preparation for the visible characters finishes.
    func prepare(_ capture: Ubiquitty.Rendering.FrameCapture, faces: FontFaces, router: FontRouter?) -> Bool {
        precondition(Thread.isMainThread)
        if work != nil { return false }
        let keys = prepared.withUnsafeMutableBufferPointer { buffer in
            capture.takeFontPreparationKeys(Ubiquitty.Rendering.FrameCapture.FontPreparationBits(buffer), Self.batchLimit)
        }
        var requests: [Request] = []
        requests.reserveCapacity(Int(keys.size()))
        for index in 0..<Int(keys.size()) {
            let key = keys[index]
            requests.append(
                Request(
                    codePoint: UInt32(truncatingIfNeeded: key),
                    face: Ubiquitty.Rendering.fontFace(key & (1 << 32) != 0, key & (1 << 33) != 0)
                )
            )
        }
        if requests.isEmpty { return true }
        let task = Work(router: router?.preparationCopy(), faces: faces, requests: requests)
        work = task
        destinationRouter = router
        queue.async { [weak self, task] in
            task.perform()
            DispatchQueue.main.async { [weak self, task] in
                guard let self, self.work === task else { return }
                if let source = task.router { self.destinationRouter?.adoptPreparedCascades(from: source) }
                self.work = nil
            }
        }
        return false
    }
}
