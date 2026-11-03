// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GlyphAtlas.swift — the mono coverage sheet and the slots inside it.
//
// The piece that joins the three below it: Core's slot cache decides which slot
// a glyph gets, the rasteriser draws the coverage, and the texture holds it for
// the shader to sample. What this adds is the sheet itself and the arithmetic
// from a slot index to a rectangle.
//
// Slot policy is Core's and is not restated here. `GlyphSlotCache` holds the
// hash and the LRU, and the builder runs the whole hit path itself against the
// binding this hands over — the backend is reached only to rasterise a glyph the
// cache had no slot for, which is once per glyph per style rather than once per
// cell. A frontend that re-implemented the probe would be a second eviction
// policy, and the two would diverge under pressure rather than at compile time.
//
// The cache lives behind an allocated pointer rather than in a stored property.
// Core's binding carries its address across the seam and the builder reads
// through it for a whole frame, so the address has to be stable; Swift promises
// that for allocated memory and not for a property.

import CoreText
import Metal
import UbiquittyCore

/// The mono coverage sheet, its slots, and the glyphs rasterised into them.
///
/// One per renderer. Conforms to ``GlyphSource``, so Core reaches it only
/// through the table `GlyphBackendContext` builds.
package final class GlyphAtlas {
    /// The wide sheet's nominal grid.
    ///
    /// Wide slots budget separately from mono ones: the sheets hold different
    /// populations, and the grid holds ~49k wide masters. One number per axis
    /// fixes the texture shape.
    static let wideNominalColumns = 128
    static let wideNominalRows = 384

    /// The R8 sheet the glyph and cell passes sample.
    let texture: MTLTexture
    /// Orders uploads and reads for every view sharing these glyph sheets.
    let commandQueue: MTLCommandQueue
    /// The staged path from a rasteriser to every sheet; see ``AtlasUploader``.
    let uploader: AtlasUploader

    /// Slot layout: how wide a slot is, how many fit per row, where the glyph
    /// box sits inside the margins.
    private let geometry: Ubiquitty.Rendering.GlyphSlotGeometry

    /// Core's hash-and-LRU over the slots.
    ///
    /// A reference, not a pointer: Core annotates the class as a shared
    /// reference type, so Swift retains and releases it and the address it hands
    /// the builder stays put for the frame without anything here managing a
    /// lifetime.
    private let cache: Ubiquitty.Rendering.GlyphSlotCache

    /// The slot layout, for a caller that must resolve geometry against the
    /// same one the glyphs were rasterised into.
    ///
    /// The capture takes it, so the metrics the decorations are drawn at are the
    /// metrics the sheet was cut to.
    /// One view's retained-reference leases across this shared atlas's caches.
    ///
    /// The sheets are shared per font configuration while retained frames are
    /// per view, so an idle view's quads reference slots a busy view's misses
    /// would otherwise evict — and the idle window shows the busy window's
    /// ink until its own next rebuild. A lease per cache pins each view's
    /// last-frame slots; -1 marks a sheet this configuration does not build.
    struct ViewRetainLease {
        var mono: Int32 = -1
        var wide: Int32 = -1
        var proportional: Int32 = -1
        var proportionalStrip: Int32 = -1
        var color: Int32 = -1
        var ligature: Int32 = -1
    }

    /// Opens a lease on every sheet this atlas carries.
    func acquireViewRetainLease() -> ViewRetainLease {
        var lease = ViewRetainLease()
        lease.mono = cache.acquireRetainLease()
        if let wide { lease.wide = wide.cache.acquireRetainLease() }
        if let proportional { lease.proportional = proportional.cache.acquireRetainLease() }
        if let proportionalStrip { lease.proportionalStrip = proportionalStrip.cache.acquireRetainLease() }
        if let color { lease.color = color.cache.acquireRetainLease() }
        if let ligature { lease.ligature = ligature.cache.acquireRetainLease() }
        return lease
    }

    /// Drops a view's pins across every sheet.
    func releaseViewRetainLease(_ lease: ViewRetainLease) {
        if lease.mono >= 0 { cache.releaseRetainLease(lease.mono) }
        if let wide, lease.wide >= 0 { wide.cache.releaseRetainLease(lease.wide) }
        if let proportional, lease.proportional >= 0 { proportional.cache.releaseRetainLease(lease.proportional) }
        if let proportionalStrip, lease.proportionalStrip >= 0 {
            proportionalStrip.cache.releaseRetainLease(lease.proportionalStrip)
        }
        if let color, lease.color >= 0 { color.cache.releaseRetainLease(lease.color) }
        if let ligature, lease.ligature >= 0 { ligature.cache.releaseRetainLease(lease.ligature) }
    }

    /// Pins the frame just built as the view's retained set, on every sheet.
    ///
    /// Called after `buildCellInstances` returns, on the build's own thread,
    /// so the frame stamps the scan reads are exactly that build's.
    func retainFrame(_ lease: ViewRetainLease) {
        if lease.mono >= 0 { cache.retainTouchedSlots(lease.mono) }
        if let wide, lease.wide >= 0 { wide.cache.retainTouchedSlots(lease.wide) }
        if let proportional, lease.proportional >= 0 { proportional.cache.retainTouchedSlots(lease.proportional) }
        if let proportionalStrip, lease.proportionalStrip >= 0 {
            proportionalStrip.cache.retainTouchedSlots(lease.proportionalStrip)
        }
        if let color, lease.color >= 0 { color.cache.retainTouchedSlots(lease.color) }
        if let ligature, lease.ligature >= 0 { ligature.cache.retainTouchedSlots(lease.ligature) }
    }

    /// Whether any sheet refused a slot during the frame just built.
    func frameHadRefusals() -> Bool {
        if cache.refusalsThisFrame() > 0 { return true }
        if let wide, wide.cache.refusalsThisFrame() > 0 { return true }
        if let proportional, proportional.cache.refusalsThisFrame() > 0 { return true }
        if let proportionalStrip, proportionalStrip.cache.refusalsThisFrame() > 0 { return true }
        if let color, color.cache.refusalsThisFrame() > 0 { return true }
        if let ligature, ligature.cache.refusalsThisFrame() > 0 { return true }
        return false
    }

    /// Whether any sheet's pins have grown far enough to threaten the next
    /// frame, one step before it would refuse a slot and draw a hole.
    func pinsCrowdOutNextFrame() -> Bool {
        if Ubiquitty.Rendering.pinsCrowdOutNextFrame(cache.capacity(), cache.pinnedSlots()) { return true }
        if let wide, Ubiquitty.Rendering.pinsCrowdOutNextFrame(wide.cache.capacity(), wide.cache.pinnedSlots()) {
            return true
        }
        if let proportional,
            Ubiquitty.Rendering.pinsCrowdOutNextFrame(proportional.cache.capacity(), proportional.cache.pinnedSlots())
        {
            return true
        }
        if let proportionalStrip,
            Ubiquitty.Rendering.pinsCrowdOutNextFrame(proportionalStrip.cache.capacity(), proportionalStrip.cache.pinnedSlots())
        {
            return true
        }
        if let color, Ubiquitty.Rendering.pinsCrowdOutNextFrame(color.cache.capacity(), color.cache.pinnedSlots()) {
            return true
        }
        if let ligature,
            Ubiquitty.Rendering.pinsCrowdOutNextFrame(ligature.cache.capacity(), ligature.cache.pinnedSlots())
        {
            return true
        }
        return false
    }

    /// Whether any sheet's pins have passed the refusal-imminent line, where
    /// the correction must not wait out its throttle.
    func pinsNearRefusal() -> Bool {
        if Ubiquitty.Rendering.pinsNearRefusal(cache.capacity(), cache.pinnedSlots()) { return true }
        if let wide, Ubiquitty.Rendering.pinsNearRefusal(wide.cache.capacity(), wide.cache.pinnedSlots()) {
            return true
        }
        if let proportional,
            Ubiquitty.Rendering.pinsNearRefusal(proportional.cache.capacity(), proportional.cache.pinnedSlots())
        {
            return true
        }
        if let proportionalStrip,
            Ubiquitty.Rendering.pinsNearRefusal(proportionalStrip.cache.capacity(), proportionalStrip.cache.pinnedSlots())
        {
            return true
        }
        if let color, Ubiquitty.Rendering.pinsNearRefusal(color.cache.capacity(), color.cache.pinnedSlots()) {
            return true
        }
        if let ligature,
            Ubiquitty.Rendering.pinsNearRefusal(ligature.cache.capacity(), ligature.cache.pinnedSlots())
        {
            return true
        }
        return false
    }

    /// What each sheet refused and how much of it the pins hold.
    ///
    /// A refusal draws a blank cell, so a frame that reports one has already
    /// lost ink the user can see. This is the only evidence that separates a
    /// sheet too small for its screen from a defect elsewhere in the frame,
    /// which otherwise look identical from outside.
    ///
    /// - Returns: One line per sheet that refused or is crowded, empty when
    ///   every sheet served the frame whole.
    func pressureReport() -> String {
        var parts: [String] = []
        func note(_ name: String, _ sheet: Ubiquitty.Rendering.GlyphSlotCache) {
            let refusals = sheet.refusalsThisFrame()
            let pinned = sheet.pinnedSlots()
            let capacity = sheet.capacity()
            guard refusals > 0 || Ubiquitty.Rendering.pinsCrowdOutNextFrame(capacity, pinned) else {
                return
            }
            parts.append("\(name) refused=\(refusals) pinned=\(pinned)/\(capacity)")
        }
        note("mono", cache)
        if let wide { note("wide", wide.cache) }
        if let proportional { note("proportional", proportional.cache) }
        if let proportionalStrip { note("proportional-strip", proportionalStrip.cache) }
        if let color { note("color", color.cache) }
        if let ligature { note("strip", ligature.cache) }
        return parts.joined(separator: " ")
    }

    /// The mono sheet's filled slots against its capacity.
    var monoOccupancy: (used: Int, capacity: Int) { (Int(cache.used()), Int(cache.capacity())) }

    /// Every sheet's pinned share, whether or not it is under pressure.
    ///
    /// The healthy reading, so a log with no refusals in it is evidence the
    /// sheets served the frame rather than evidence the reporting never ran.
    ///
    /// - Returns: One `name pinned/capacity` term per sheet.
    func occupancyReport() -> String {
        var parts = ["mono \(cache.pinnedSlots())/\(cache.capacity())"]
        if let wide { parts.append("wide \(wide.cache.pinnedSlots())/\(wide.cache.capacity())") }
        if let proportional {
            parts.append("proportional \(proportional.cache.pinnedSlots())/\(proportional.cache.capacity())")
        }
        if let proportionalStrip {
            parts.append("proportional-strip \(proportionalStrip.cache.pinnedSlots())/\(proportionalStrip.cache.capacity())")
        }
        if let color { parts.append("color \(color.cache.pinnedSlots())/\(color.cache.capacity())") }
        if let ligature { parts.append("strip \(ligature.cache.pinnedSlots())/\(ligature.cache.capacity())") }
        return parts.joined(separator: " ")
    }

    /// Drops a view's accumulated pins across every sheet.
    func rebaselineViewRetainLease(_ lease: ViewRetainLease) {
        if lease.mono >= 0 { cache.rebaselineRetainedSlots(lease.mono) }
        if let wide, lease.wide >= 0 { wide.cache.rebaselineRetainedSlots(lease.wide) }
        if let proportional, lease.proportional >= 0 {
            proportional.cache.rebaselineRetainedSlots(lease.proportional)
        }
        if let proportionalStrip, lease.proportionalStrip >= 0 {
            proportionalStrip.cache.rebaselineRetainedSlots(lease.proportionalStrip)
        }
        if let color, lease.color >= 0 { color.cache.rebaselineRetainedSlots(lease.color) }
        if let ligature, lease.ligature >= 0 { ligature.cache.rebaselineRetainedSlots(lease.ligature) }
    }

    var slotGeometry: Ubiquitty.Rendering.GlyphSlotGeometry {
        // The strip font's probe verdict rides the geometry so the builder's
        // prescan and the sheet's row walk read one answer; the sheet is the
        // authority because it owns the font strips draw with. No sheet means
        // no strips, and the economy is the safe direction there.
        var published = geometry
        published.ligatureParticipation = ligature?.participation ?? .OperatorRuns
        measureBoxStrokeProfileIfNeeded()
        published.boxStrokeProfile = boxStrokeProfile
        return published
    }

    /// How many slots the sheet holds.
    private let slotCapacity: Int

    /// Per-slot measured ink box, handed to Core through ``bindMonoAtlas`` the
    /// way a slot-UV table would be: one load per hit, no seam call.
    ///
    /// Raw storage rather than an Array because Core holds the pointer for the
    /// frame; an Array's buffer address is only promised inside a
    /// `withUnsafe...` closure. The pointer is stable for the atlas's life and
    /// the builder reads it only inside `buildCellInstances`, on the thread
    /// that faults the slots — the ordering every other slot table here
    /// already relies on.
    ///
    /// Every writer of a mono slot must store something: a measured box, the
    /// zero-size "no ink" box, or the unmeasured marker. A box left from the
    /// slot's previous occupant clips the new glyph on screen.
    private let inkBoxForSlot: UnsafeMutablePointer<Ubiquitty.Rendering.GlyphInkBox>

    deinit {
        inkBoxForSlot.deinitialize(count: slotCapacity)
        inkBoxForSlot.deallocate()
    }

    /// The two-cell sheet, or nil when Core's geometry declares none.
    ///
    /// Core carries the wide slot as `wideSlotWidthInPixels`, and zero is what
    /// tells a consumer to leave a wide glyph on its own cell rather than route
    /// it to a wide pass. Building the sheet on a zero geometry would create a
    /// pass Core never emits into.
    private let wide: CoverageSheet?

    /// The proportional face's per-glyph sheet.
    ///
    /// Its slot geometry matches the two-cell canvas because proportional
    /// glyphs need the same overhang room, but its texture and cache are its
    /// own. A flood of UI labels therefore cannot evict a CJK glyph or cluster,
    /// and a wide-heavy frame cannot evict the proportional repertoire.
    private let proportional: CoverageSheet?
    /// The bitmap tier's proportional slot, from Core's plan; nil in the
    /// native tier, where the sheet is cut to the wide canvas.
    private let bitmapProportionalPlan: Ubiquitty.Rendering.ProportionalGlyphSlotPlan?

    /// The proportional face's bounded fallback strips.
    ///
    /// Separate from both the per-glyph proportional sheet and the grid
    /// face's ligature sheet: the three populations have different keys and
    /// eviction pressure, and a draw samples exactly one texture.
    private let proportionalStrip: LigatureSheet?

    /// The RGBA sheet colour emoji live on, or nil on a geometry with no
    /// reference extents. Its slot edge is Core's destination square — the
    /// same number the builder cuts the quad to, so no sampler filter is
    /// observable between the two. A colour glyph with no sheet falls to the
    /// mono path and draws as coverage — an emoji in the foreground colour.
    private let color: ColorSheet?

    /// The 2x-master sheet DECDWL/DECDHL rows crop from, or nil when creation
    /// refused. Slots are the mono slot doubled on both axes, so the master's
    /// margins are the 1x margins doubled and the slot's vertical midline is
    /// the cell box's — which is what lets the Top and Bottom halves meet
    /// without a seam.
    private let double: CoverageSheet?

    /// The strip sheet shaped ligature runs live on, or nil when Core's
    /// geometry publishes no strip slot — rows then stay unligatured.
    private let ligature: LigatureSheet?

    private let rasterizer: GlyphRasterizer
    /// Draws the masters a sized block's windows are cut from, for the mono and the
    /// wide sheets alike.
    private let sizedRaster = SizedWindowRaster()
    private let faces: FontFaces

    /// The number of subpixel phases this atlas keys and draws, the grid
    /// CoreText quantises pens onto at the faces' device size. The frame
    /// inputs carry the same number so the builder's phase is the raster's.
    let subpixelPhaseCount: Int
    /// The primary face's pitch, which decides whether Core centres a glyph
    /// narrower than its cell.
    private let facePitch: Ubiquitty.Rendering.FontMetrics.FacePitch
    /// Shapes a proportional primary face's rows letter by letter (LetterLayout.h).
    private let primaryRuns: PrimaryRunShaper
    /// The number of phases the wide sheet keys and draws: the grid CoreText
    /// quantises a grown two-cell glyph onto, which is the grid of the faces'
    /// size times the growth and so can be coarser than the mono text's. The
    /// frame inputs carry it beside the count above.
    let widePhaseCount: Int
    /// Each two-cell glyph's own pen grid, by code point and face: growth
    /// sized by the glyph's ink sets the device size CoreText quantises on.
    /// Measured once per glyph, since Core asks for every phased wide cell.
    private var widePenGrids: [UInt64: Int32] = [:]
    /// Each fallback face's raise on the wide sheet, by face and style.
    /// Measured once per face, since every glyph of a face shares it.
    private var wideRaises: [String: CGFloat] = [:]
    /// Whether the sheets are CoreText rasters. A bitmap family Core draws
    /// itself (Unifont) positions on the portable grid and has no smoothing
    /// tiers, so its frame keys exactly as the portable renderer's.
    var isCoreTextRaster: Bool { unifontScale == 0 }

    /// Core's fallback routing, consulted when the primary face lacks a
    /// glyph; nil keeps every miss blank, the pre-routing behaviour.
    private let router: FontRouter?

    /// The current frame's native shaping work and active segment retention.
    package var shapingStatisticsForTesting: (lines: Int, segments: Int) {
        (ligature?.shapedLinesThisFrame ?? 0, ligature?.retainedShapingSegments ?? 0)
    }

    /// The em size this atlas sets proportional runs at, or nil without a strip sheet.
    package var proportionalPointSizeForTesting: Double? { proportionalStrip?.proportionalPointSizeForTesting }

    /// Returns the fallback face selected by this live atlas for a character.
    package func routedFamilyForTesting(_ codePoint: UInt32) -> String? {
        guard let font = router?.routedFont(for: codePoint, face: .Regular, variableWeight: 0, wantsEmoji: false) else { return nil }
        return CTFontCopyFamilyName(font) as String
    }

    private let fontPreparation = GlyphFontPreparation()

    func prepareVisibleFonts(_ capture: Ubiquitty.Rendering.FrameCapture) -> Bool {
        if unifontScale > 0 { return true }
        return fontPreparation.prepare(capture, faces: faces, router: router)
    }

    private let baselinePenInPixels: Double

    /// The integer upscale a bitmap family's cell was cut for, or zero when the
    /// configured family is not one.
    ///
    /// Zero is the whole test: a family Core rasterises itself has no CoreText
    /// face worth asking, and one that does must not be routed to Unifont's
    /// glyphs. Carried rather than derived because the family-to-rasteriser map
    /// is Core's and the renderer that owns the font build already read it.
    package let unifontScale: Int // 0 for a face CoreText rasterises; the frame raster inputs carry it to Core

    /// The box family's uniform vertical centring shift, in pixels.
    ///
    /// Measured once per font configuration from the reference U+2500's ink
    /// band, then applied to every box glyph identically — the family moves
    /// as a group to the cell centre, so all strokes stay on one shared row
    /// and meet across cells without a seam.
    private var boxCenterShiftY: Int32 = 0
    /// The font's measured box strokes, published through ``slotGeometry``.
    private var boxStrokeProfile = Ubiquitty.Rendering.BoxDrawing.BoxStrokeProfile()
    private var isBoxStrokeProfileMeasured = false
    /// Whether the shift above has been measured for this configuration.
    private var isBoxCenterShiftMeasured = false

    /// Holds an atlas without keeping it alive.
    ///
    /// The registry must not decide an atlas's lifetime: its sheets are Metal
    /// textures sized for whole glyph working sets, and a strong entry would
    /// keep every font configuration a session ever showed resident until the
    /// process exits — the same rationale `UBGlyphAtlas` records for its
    /// weak-value registry on the other arm.
    private final class WeakAtlas {
        weak var atlas: GlyphAtlas?

        init(_ atlas: GlyphAtlas) {
            self.atlas = atlas
        }
    }

    /// Guards the registry below.
    private static let registryLock = NSLock()

    /// Live atlases by configuration, so views showing one font share one.
    ///
    /// The atlas and nothing above it: everything in here is keyed by glyph
    /// identity and produces byte-identical coverage for identical inputs,
    /// which is the property `UBGlyphAtlas` shares its texture on. The
    /// renderer, its retained grid texture and its instance buffers are
    /// per-view CONTENT — a registry one level up shared those too, and a new
    /// tab blitted the previous tab's retained frame.
    ///
    /// ``registryLock`` guards this map; every read, prune and insert is inside
    /// it, so lookup and build are one step and one key cannot cut two sheet
    /// sets. It guards the map only. An atlas it vends is render-thread state —
    /// the slot cache, the uploader and ``inkBoxForSlot`` are not thread-safe
    /// and this lock does not make them so — with one exception:
    /// ``proportionalRunCells(_:)`` is entered from the ingest thread through
    /// Core's text measurer (`Source/Core/OSC/TextSizing.cpp`), reads only the
    /// immutable `ligature` reference, and hands off to ``LigatureSheet``'s own
    /// `proportionalLinesLock`. A new member reached from that path needs its
    /// own guard.
    nonisolated(unsafe) private static var registry: [String: WeakAtlas] = [:]

    /// Assembles the sharing key from every axis that changes a rasterised pixel.
    ///
    /// One assembly for every renderer owner: a second spelling of this list
    /// serves another configuration's glyphs on the axis it leaves out, and
    /// nothing errors. The device is identity-keyed (two devices cannot share
    /// a texture); the shader library is not (it changes no coverage mask).
    /// The key selects the shared glyph sheets only — the renderer, its
    /// retained grid and its buffers stay per view.
    ///
    /// - Parameters:
    ///   - device: The device the sheets live on.
    ///   - familyName: The font family.
    ///   - pointSize: The size the faces are built at, in atlas pixels.
    ///   - pixelsPerPoint: The backing scale those pixels were sized for; two
    ///     configurations at one pixel size and two scales draw the UI face
    ///     at two optical sizes.
    ///   - geometry: The slot layout.
    ///   - slotCapacity: Slots per sheet.
    ///   - baselinePenInPixels: The pen inside a slot.
    ///   - wideGlyphBoostCap: The wide-glyph optical multiplier, resolved.
    ///   - unifontScale: The bitmap family's upscale, or zero.
    ///   - cjkFallbackFamily: The configured CJK family, or empty.
    ///   - cjkFallbackLanguage: The Han disambiguation tag, or empty.
    ///   - symbolFamilyName: The symbol family, or empty.
    ///   - symbolFontPath: The bundled symbol font's path, or empty.
    ///   - ligatureFeatureSpec: The probe's features, in Core's grammar.
    ///   - userFeatureSpec: The reader's `font.features`, baked into the
    ///     faces the sheets rasterise with. Named separately from the probed
    ///     spec because the two can coincide while the faces differ: a face
    ///     that ligates nothing probes empty under any user spec, and a key
    ///     without this field hands those configurations one atlas.
    ///   - userVariationSpec: The reader's `font.variations`, baked into the
    ///     faces the sheets rasterise with, named for the same reason as the
    ///     user features: an axis the key does not name hands two variation
    ///     configurations one atlas.
    ///   - fontWeight: The configured regular-face weight.
    ///   - boldFontWeight: The configured bold-face weight.
    ///   - fontWidthPercent: The configured face width.
    ///   - fontLigates: The probe's verdict, the reader's toggle folded in.
    ///   - wantsLigatures: The reader's toggle alone. Named beside the fold
    ///     because the fold can hide it: a face that ligates nothing answers
    ///     false under either toggle, and a key without this field hands the
    ///     two configurations one atlas.
    ///   - proportionalFamilyName: The proportional face's family, or empty
    ///     for the platform's UI face; a run is cut in it, so two families
    ///     cannot share a strip.
    ///   - proportionalPointSize: The proportional face's em size, or zero
    ///     for one optical step over the grid's.
    /// - Returns: Core's sharing identity, or nil for invalid configuration facts.
    package static func sheetKey(
        device: MTLDevice,
        familyName: String,
        pointSize: Double,
        pixelsPerPoint: Double,
        geometry: Ubiquitty.Rendering.GlyphSlotGeometry,
        slotCapacity: Int32,
        baselinePenInPixels: Double,
        wideGlyphBoostCap: Double,
        unifontScale: Int32,
        cjkFallbackFamily: String,
        cjkFallbackLanguage: String,
        symbolFamilyName: String,
        symbolFontPath: String,
        ligatureFeatureSpec: String,
        userFeatureSpec: String,
        userVariationSpec: String,
        fontWeight: Int32,
        boldFontWeight: Int32,
        fontWidthPercent: Double,
        fontLigates: Bool,
        wantsLigatures: Bool,
        proportionalFamilyName: String = "",
        proportionalPointSize: Double = 0
    ) -> String? {
        var configuration = Ubiquitty.Rendering.AtlasConfiguration()
        configuration.resourceDomain = UInt64(UInt(bitPattern: ObjectIdentifier(device)))
        configuration.familyName = std.string(familyName)
        configuration.pointSize = pointSize
        configuration.pixelsPerPoint = pixelsPerPoint
        configuration.geometry = geometry
        configuration.slotCapacity = slotCapacity
        configuration.baselinePenInPixels = baselinePenInPixels
        configuration.wideGlyphBoostLimit = wideGlyphBoostCap
        configuration.unifontScale = unifontScale
        configuration.fontWeight = fontWeight
        configuration.boldFontWeight = boldFontWeight
        configuration.fontWidthPercent = fontWidthPercent
        configuration.proportionalFamilyName = std.string(proportionalFamilyName)
        configuration.proportionalPointSize = proportionalPointSize
        configuration.cjkFallbackFamily = std.string(cjkFallbackFamily)
        configuration.cjkFallbackLanguage = std.string(cjkFallbackLanguage)
        configuration.symbolFamilyName = std.string(symbolFamilyName)
        configuration.symbolFontPath = std.string(symbolFontPath)
        configuration.ligatureFeatureSpecification = std.string(ligatureFeatureSpec)
        configuration.userFeatureSpecification = std.string(userFeatureSpec)
        configuration.userVariationSpecification = std.string(userVariationSpec)
        configuration.doesFontLigate = fontLigates
        configuration.wantsLigatures = wantsLigatures
        let key = String(configuration.sharingKey())
        return key.isEmpty ? nil : key
    }

    /// Returns the atlas for this configuration, building one only if none is live.
    ///
    /// A caller supplies `faces` and `router` for the build case; a served
    /// atlas keeps the equivalent objects the first builder created, which the
    /// configuration describes. Resolved font resources must remain stable
    /// while the configuration's atlases are shared.
    ///
    /// - Parameters:
    ///   - key: The configuration, assembled by the caller that holds every
    ///     axis — a key built from fewer axes serves another configuration's
    ///     glyphs rather than an error.
    ///   - device: The Metal device the sheets live on.
    ///   - faces: The resolved faces, used when no atlas is live.
    ///   - geometry: The slot layout.
    ///   - slotCapacity: Slots per sheet.
    ///   - baselinePenInPixels: The pen inside a slot.
    ///   - wideGlyphBoostCap: The wide-glyph growth cap, at most 1 for none.
    ///   - unifontScale: Non-zero when Core rasterises this family itself.
    ///   - router: The fallback router, used when no atlas is live.
    ///   - ligatureFeatureSpec: The probed feature spelling.
    ///   - fontLigates: Whether the face ligates.
    ///   - proportionalFamilyName: The proportional face's family, or empty
    ///     for the platform's UI face.
    ///   - proportionalPointSize: The proportional face's em size, or zero
    ///     for one optical step over the grid's.
    /// - Returns: An atlas shared with any live view of this configuration, or
    ///   nil when one cannot be built.
    static func shared(
        key: String,
        device: MTLDevice,
        faces: FontFaces,
        geometry: Ubiquitty.Rendering.GlyphSlotGeometry,
        slotCapacity: Int,
        baselinePenInPixels: Double,
        wideGlyphBoostCap: Double,
        unifontScale: Int,
        router: FontRouter?,
        ligatureFeatureSpec: String,
        fontLigates: Bool,
        proportionalFamilyName: String = "",
        proportionalPointSize: Double = 0
    ) -> GlyphAtlas? {
        // Lookup, build, prune and insert are one step under the lock, so two
        // callers on one key cannot each build a sheet set and drop one.
        // `init` reaches nothing that calls this, so the lock cannot re-enter.
        registryLock.withLock { () -> GlyphAtlas? in
            if let live = registry[key]?.atlas {
                return live
            }
            guard
                let atlas = GlyphAtlas(
                    device: device,
                    faces: faces,
                    geometry: geometry,
                    slotCapacity: slotCapacity,
                    baselinePenInPixels: baselinePenInPixels,
                    wideGlyphBoostCap: wideGlyphBoostCap,
                    unifontScale: unifontScale,
                    router: router,
                    ligatureFeatureSpec: ligatureFeatureSpec,
                    fontLigates: fontLigates,
                    proportionalFamilyName: proportionalFamilyName,
                    proportionalPointSize: proportionalPointSize
                )
            else {
                return nil
            }
            // Entries whose atlas has gone leave dead keys, dropped at the one
            // place the map grows so a session cycling configurations accumulates
            // strings rather than textures.
            registry = registry.filter { $0.value.atlas != nil }
            registry[key] = WeakAtlas(atlas)
            return atlas
        }
    }

    /// Builds a sheet sized to hold `slotCapacity` slots of one geometry.
    ///
    /// - Parameters:
    ///   - device: The device the sheet is allocated on.
    ///   - faces: The family the glyphs are drawn from.
    ///   - geometry: The slot layout, from Core's atlas fit.
    ///   - slotCapacity: How many slots to make room for.
    /// - Parameter baselinePenInPixels: Where the pen baseline sits above the
    ///   slot bottom — Core's `layoutCell` answer (descent plus the split
    ///   slack), resolved by the frame drive. Received rather than re-derived:
    ///   a pen built from the descent alone rides low by the gap, the ink
    ///   lands in the underline band, and skip-ink erases the rule.
    /// - Parameter unifontScale: The integer upscale a bitmap family's cell was
    ///   cut for; zero when the configured family is not a bitmap one.
    /// - Parameter wideGlyphBoostCap: The optical multiplier a wide monochrome
    ///   glyph may grow by before the slot caps it, with the on/off setting
    ///   already folded in — at most 1 means no boost. Received rather than read
    ///   from the configuration, so this file needs no config module and one
    ///   resolution serves both arms.
    /// - Parameter ligatureFeatureSpec: The probed ligature features, in
    ///   Core's font-feature grammar; empty when none were found.
    /// - Parameter fontLigates: The probe's verdict on whether the face
    ///   shapes any ligature at all.
    /// - Parameter proportionalFamilyName: The family proportional runs are
    ///   set in, or empty for the platform's UI face.
    /// - Parameter proportionalPointSize: The em size proportional runs are
    ///   set at, or zero for one optical step over the grid's.
    init?(
        device: MTLDevice,
        faces: FontFaces,
        geometry: Ubiquitty.Rendering.GlyphSlotGeometry,
        slotCapacity: Int,
        baselinePenInPixels: Double,
        wideGlyphBoostCap: Double,
        unifontScale: Int,
        router: FontRouter? = nil,
        ligatureFeatureSpec: String = "",
        fontLigates: Bool = false,
        proportionalFamilyName: String = "",
        proportionalPointSize: Double = 0
    ) {
        self.router =
            router
            ?? (unifontScale == 0
                ? FontRouter(
                    primary: faces,
                    cjkFamilyName: "",
                    cjkLanguage: "",
                    symbolFamilyName: "",
                    symbolFontPath: "",
                    configuration: Ubiquitty.Preferences.Values()
                ) : nil)
        // The faces are sized in atlas pixels, which is the device size
        // CoreText's quantiser selects on.
        self.subpixelPhaseCount =
            unifontScale > 0
            ? Int(Ubiquitty.Rendering.subpixelPhaseCount)
            : Int(Ubiquitty.Rendering.nativeSubpixelPhaseCount(Double(CTFontGetSize(faces[Ubiquitty.Rendering.FontFace.Regular]))))
        self.facePitch = unifontScale > 0 ? .Fixed : FontGeometry.facePitch(of: faces[Ubiquitty.Rendering.FontFace.Regular])
        self.primaryRuns = PrimaryRunShaper(faces: faces)
        self.widePhaseCount =
            unifontScale > 0 || wideGlyphBoostCap <= 1
            ? self.subpixelPhaseCount
            : Int(
                Ubiquitty.Rendering.nativeSubpixelPhaseCount(
                    wideGlyphBoostCap * Double(CTFontGetSize(faces[Ubiquitty.Rendering.FontFace.Regular]))
                )
            )
        guard geometry.columns > 0, slotCapacity > 0,
            let rasterizer = GlyphRasterizer(
                width: Int(geometry.slotWidthInPixels),
                height: Int(geometry.slotHeightInPixels)
            )
        else {
            return nil
        }
        // What the colour and double-size sheets are cut for. Not the mono
        // count: a colour slot is four bytes a pixel and a double-size slot
        // covers four times the area, so matching the mono sheet spends tens
        // of megabytes on populations — emoji, double-height rows — that are
        // a fraction of a screen's text. An allocation that large can fail
        // outright, and a sheet that refuses reaches the user as a window
        // that never draws.
        // Core clamps the grid to the device limit. A bounded slot count is not
        // enough on its own: the per-slot pixels alone can push a large font
        // past the maximum texture dimension, and an over-size descriptor does
        // not fail creation — Metal aborts the process inside descriptor
        // validation, so an unclamped grid reaches a user as a crash on a font
        // size rather than as a smaller sheet.
        //
        // The fitted grid becomes this atlas's geometry and capacity, never
        // just the texture's size. The cache maps a slot to a column and a row
        // by the same column count, so a texture cut to one width and a cache
        // indexing at another address different slots for one glyph.
        let wantedRows = (slotCapacity + Int(geometry.columns) - 1) / Int(geometry.columns)
        let fit = Ubiquitty.Rendering.clampAtlasGridToTextureLimit(
            Ubiquitty.GridSize(columns: geometry.columns, rows: Int32(wantedRows)),
            Ubiquitty.IntSize(
                width: geometry.slotWidthInPixels,
                height: geometry.slotHeightInPixels
            ),
            Int32(device.maximumTexture2DDimension)
        )
        guard fit.valid else {
            return nil
        }
        var fittedGeometry = geometry
        fittedGeometry.columns = fit.columns
        let fittedCapacity = Int(fit.columns) * Int(fit.rows)
        let auxiliarySlotCapacity = max(Int(fit.columns) * 128, fittedCapacity / 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(fit.columns) * Int(geometry.slotWidthInPixels),
            height: Int(fit.rows) * Int(geometry.slotHeightInPixels),
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        guard let texture = device.makeTexture(descriptor: descriptor),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        self.texture = texture
        self.commandQueue = commandQueue
        // Made before the sheets, which take it: every sheet of an atlas
        // stages through one uploader so a single flush carries them all.
        let uploader = AtlasUploader(queue: commandQueue)
        self.uploader = uploader
        self.geometry = fittedGeometry
        self.slotCapacity = fittedCapacity
        self.inkBoxForSlot = UnsafeMutablePointer<Ubiquitty.Rendering.GlyphInkBox>.allocate(capacity: fittedCapacity)
        self.inkBoxForSlot.initialize(
            repeating: Ubiquitty.Rendering.unmeasuredGlyphInkBox(),
            count: fittedCapacity
        )
        self.rasterizer = rasterizer
        self.faces = faces
        self.baselinePenInPixels = baselinePenInPixels
        self.unifontScale = unifontScale
        // Core's factory, because the class is a shared reference type and Swift
        // cannot place one itself. The bucket count is Core's too: the load
        // factor and the power-of-two mask are one decision every backend's
        // cache has to make the same way.
        guard
            let cache = Ubiquitty.Rendering.makeGlyphSlotCache(
                Int32(fittedCapacity),
                Ubiquitty.Rendering.recommendedHashBuckets(Int32(fittedCapacity)),
                fittedGeometry.columns
            )
        else {
            return nil
        }
        self.cache = cache
        // The two-cell sheet carries its own wide budget, not the mono one: a
        // wide-heavy stream holds more distinct two-cell glyphs than the mono
        // count, so a shared budget would make the LRU re-rasterise every
        // resident glyph on every pass instead of filling each once. CoverageSheet clamps
        // the nominal grid to the device limit.
        // Two true cell advances, not two rounded cell boxes: the phased wide
        // quad stands 1:1 at the cell's pen, so the cells end where the
        // advances do.
        let cellAdvance = geometry.referenceAdvanceInPixels > 0 ? geometry.referenceAdvanceInPixels : Float(geometry.glyphWidthInPixels)
        let wideCentringWidth = 2 * CGFloat(cellAdvance)
        self.wide =
            geometry.wideSlotWidthInPixels > 0 && geometry.wideSlotHeightInPixels > 0
            ? CoverageSheet(
                device: device,
                uploader: uploader,
                columns: GlyphAtlas.wideNominalColumns,
                slotWidthInPixels: Int(geometry.wideSlotWidthInPixels),
                slotHeightInPixels: Int(geometry.wideSlotHeightInPixels),
                slotCapacity: GlyphAtlas.wideNominalColumns * GlyphAtlas.wideNominalRows,
                pen: CGPoint(
                    x: CGFloat(geometry.glyphMarginInPixels.width),
                    y: CGFloat(baselinePenInPixels)
                ),
                // The cap the owning renderer resolved, not the compile-time
                // default: `wide_glyph_boost` and `wide_glyph_scale` are settings,
                // and Effective:: is where an unset key becomes its default. A
                // sheet reading Defaults:: directly draws the default whatever the
                // user configured, which the pixel comparison sees only under a
                // config that moves the key off its default — every case that
                // leaves it alone agrees either way.
                boostCap: CGFloat(wideGlyphBoostCap),
                centringWidthInPixels: wideCentringWidth,
                maxTextureDimension: device.maximumTexture2DDimension
            )
            : nil
        let proportionalGrid = Ubiquitty.Rendering.proportionalGlyphAtlasNominalGrid()
        // A separate sheet even though the slot has the wide canvas's shape:
        // shape is geometry, while ownership is eviction and lifetime. Core
        // owns the bounded grid so another frontend does not silently choose
        // another cache policy for the same repertoire.
        //
        // The bitmap tier's sheet is cut to the plan the reference sheet cuts
        // for the same cell — the strike's overhang above and below, no
        // margin before the pen — and its glyphs are drawn by Core's strike,
        // so a run here is the reference's per-glyph run byte for byte rather
        // than one composed strip (Docs/proportional-text.md).
        let bitmapProportionalPlan: Ubiquitty.Rendering.ProportionalGlyphSlotPlan? =
            unifontScale > 0
            ? Ubiquitty.Rendering.unifontProportionalGlyphSlotPlan(
                Int32(unifontScale),
                geometry.slotWidthInPixels,
                geometry.slotHeightInPixels,
                Int32(device.maximumTexture2DDimension)
            )
            : nil
        self.bitmapProportionalPlan = bitmapProportionalPlan?.valid == true ? bitmapProportionalPlan : nil
        if let plan = self.bitmapProportionalPlan {
            self.proportional = CoverageSheet(
                device: device,
                uploader: uploader,
                columns: Int(plan.columns),
                slotWidthInPixels: Int(plan.slotWidthInPixels),
                slotHeightInPixels: Int(plan.slotHeightInPixels),
                slotCapacity: Int(plan.columns * plan.rows),
                pen: CGPoint(
                    x: CGFloat(plan.marginInPixels.width),
                    y: CGFloat(baselinePenInPixels)
                ),
                maxTextureDimension: device.maximumTexture2DDimension
            )
        } else {
            self.proportional =
                unifontScale == 0
                    && geometry.wideSlotWidthInPixels > 0
                    && geometry.wideSlotHeightInPixels > 0
                    && geometry.ligatureSlotWidthInPixels > 0
                    && geometry.ligatureSlotHeightInPixels > 0
                ? CoverageSheet(
                    device: device,
                    uploader: uploader,
                    columns: Int(proportionalGrid.columns),
                    slotWidthInPixels: Int(geometry.wideSlotWidthInPixels),
                    slotHeightInPixels: Int(geometry.wideSlotHeightInPixels),
                    slotCapacity: Int(proportionalGrid.columns * proportionalGrid.rows),
                    pen: CGPoint(
                        x: CGFloat(geometry.glyphMarginInPixels.width),
                        y: CGFloat(baselinePenInPixels)
                    ),
                    maxTextureDimension: device.maximumTexture2DDimension
                )
                : nil
        }
        if let proportional = self.proportional {
            // The ledger is one column wide, the slot's own width: the
            // builder reads a glyph's ink extent off it to clip the quad at
            // the run's claim.
            proportional.cache.enableOwnedInkRecords(1, Int32(proportional.slotWidthInPixels))
        }
        // Cut to Core's destination square — the number the builder also cuts
        // the quad to — and not to the mono slot height: the mono slot carries
        // the overflow margins a tall glyph needs, so a sheet cut to it
        // rasterises every emoji oversized and the quad resamples it down,
        // through a filter the backends do not share. The reference extents
        // are the inputs Core's builder uses for the quad.
        self.color =
            unifontScale == 0
            ? ColorSheet(
                device: device,
                uploader: uploader,
                columns: Int(geometry.columns),
                slotInPixels: Int(
                    Ubiquitty.Rendering.colourGlyphSquareInPixels(
                        geometry.referenceAdvanceInPixels,
                        geometry.referenceLineHeightInPixels
                    )
                ),
                slotCapacity: auxiliarySlotCapacity,
                maxTextureDimension: device.maximumTexture2DDimension
            ) : nil
        // The mono slot doubled on both axes, at the mono pen: the transform
        // doubles the draw, so the unscaled pen is what keeps the master's
        // baseline at exactly twice the single-height one.
        self.double = CoverageSheet(
            device: device,
            uploader: uploader,
            columns: Int(geometry.columns),
            slotWidthInPixels: 2 * Int(geometry.slotWidthInPixels),
            slotHeightInPixels: 2 * Int(geometry.slotHeightInPixels),
            slotCapacity: auxiliarySlotCapacity,
            pen: CGPoint(
                x: CGFloat(geometry.glyphMarginInPixels.width),
                y: CGFloat(baselinePenInPixels)
            ),
            maxTextureDimension: device.maximumTexture2DDimension
        )
        // Cut to Core's published strip slot; a zero width is Core's signal
        // that rows stay unligatured, and no sheet is built for them.
        self.ligature =
            geometry.ligatureSlotWidthInPixels > 0 && geometry.ligatureSlotHeightInPixels > 0
            ? LigatureSheet(
                device: device,
                uploader: uploader,
                faces: faces,
                slotWidthInPixels: Int(geometry.ligatureSlotWidthInPixels),
                slotHeightInPixels: Int(geometry.ligatureSlotHeightInPixels),
                marginXInPixels: Double(geometry.glyphMarginInPixels.width),
                baselinePenInPixels: baselinePenInPixels,
                cellAdvanceInPixels: Double(geometry.referenceAdvanceInPixels),
                worstCaseCellsOnScreen: slotCapacity,
                featureSpec: ligatureFeatureSpec,
                doesLigate: fontLigates,
                subpixelPhaseCount: self.subpixelPhaseCount,
                maxTextureDimension: device.maximumTexture2DDimension,
                unifontScale: unifontScale,
                marginYInPixels: Double(geometry.glyphMarginInPixels.height),
                proportionalFamilyName: proportionalFamilyName,
                proportionalPointSize: proportionalPointSize
            )
            : nil
        self.proportionalStrip =
            geometry.ligatureSlotWidthInPixels > 0 && geometry.ligatureSlotHeightInPixels > 0
            ? LigatureSheet(
                device: device,
                uploader: uploader,
                faces: faces,
                slotWidthInPixels: Int(geometry.ligatureSlotWidthInPixels),
                slotHeightInPixels: Int(geometry.ligatureSlotHeightInPixels),
                marginXInPixels: Double(geometry.glyphMarginInPixels.width),
                baselinePenInPixels: baselinePenInPixels,
                cellAdvanceInPixels: Double(geometry.referenceAdvanceInPixels),
                worstCaseCellsOnScreen: slotCapacity,
                featureSpec: ligatureFeatureSpec,
                doesLigate: fontLigates,
                subpixelPhaseCount: self.subpixelPhaseCount,
                maxTextureDimension: device.maximumTexture2DDimension,
                unifontScale: unifontScale,
                marginYInPixels: Double(geometry.glyphMarginInPixels.height),
                proportionalFamilyName: proportionalFamilyName,
                proportionalPointSize: proportionalPointSize
            )
            : nil
    }

    /// The two-cell sheet the wide pass samples, or nil when there is none.
    var wideTexture: MTLTexture? { wide?.texture }

    /// The proportional-glyph pass's sheet, or nil when there is no native face.
    var proportionalTexture: MTLTexture? { proportional?.texture }

    /// The proportional-strip fallback pass's sheet.
    var proportionalStripTexture: MTLTexture? { proportionalStrip?.texture }

    /// The RGBA sheet the colour pass samples, or nil when creation refused.
    var colorTexture: MTLTexture? { color?.texture }

    /// The 2x-master sheet the double pass samples, or nil when creation refused.
    var doubleTexture: MTLTexture? { double?.texture }

    /// The strip sheet the ligature pass samples, or nil when there is none.
    var ligatureTexture: MTLTexture? { ligature?.texture }

    /// Applies the user's ligature toggle for the coming frames.
    ///
    /// The sheet stays built either way, so flipping the setting keeps every
    /// cached strip warm; the shaper just stops reporting runs.
    ///
    /// - Parameter isEnabled: Whether rows shape at all.
    func setLigaturesEnabled(_ isEnabled: Bool) {
        ligature?.isEnabled = isEnabled
    }

    /// The pixel rectangle a slot occupies in the sheet.
    ///
    /// Core's `atlasSlotRegion` does the division — the sibling sheets call
    /// it already, and a second spelling here is the drift the shared
    /// arithmetic exists to prevent.
    ///
    /// - Parameter slot: The slot index the cache assigned.
    /// - Returns: The region to upload into.
    private func region(for slot: Int) -> MTLRegion {
        let box = Ubiquitty.Rendering.atlasSlotRegion(
            Int32(slot),
            geometry.columns,
            geometry.slotWidthInPixels,
            geometry.slotHeightInPixels
        )
        return MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height))
    }

    /// The normalized UV rectangle a slot occupies.
    ///
    /// - Parameter slot: The slot index the cache assigned.
    /// - Returns: The glyph's atlas rect, marked present.
    private func atlasGlyph(for slot: Int) -> Ubiquitty.Rendering.AtlasGlyph {
        // atlasRectForBuilder, not atlasRectForSlot: Core names three mappings and this is the
        // one the builder consumes — the full slot contracted by the margin,
        // which the builder then expands again. Handing it either of the other
        // two shifts every glyph by a margin, and the frame draws.
        let uv = geometry.atlasRectForBuilder(Int32(slot), Int32(slotCapacity))
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = uv.minU
        glyph.minUV.y = uv.minV
        glyph.maxUV.x = uv.maxU
        glyph.maxUV.y = uv.maxV
        glyph.present = true
        return glyph
    }

    /// The cache key Core's builder probes with.
    ///
    /// Core's, not derived here. The builder runs the mono hit path itself
    /// against this same cache using `monoGlyphKey`, so a second packing in this
    /// file would send a lookup to a different slot than the one the builder
    /// filled — the glyph rasterises into one slot and samples from another, and
    /// the neighbouring glyph draws with every count correct.
    ///
    /// `GlyphKey.h` partitions the keyspace across text, box, cluster and DRCS
    /// glyphs and says never to renumber it; a frontend inventing a packing is
    /// outside that partition and can collide with any of them.
    ///
    /// - Parameters:
    ///   - codePoint: The character.
    ///   - weight: Variable-font weight. In the key because a weighted glyph is a
    ///     different image and must not share a slot with the plain one.
    ///   - face: The face it is drawn in.
    ///   - variant: The raster variant it was positioned and weighted under.
    /// - Returns: The key to probe the cache with.
    private static func key(
        _ codePoint: UInt32,
        _ weight: UInt32,
        _ face: Ubiquitty.Rendering.FontFace,
        _ variant: UInt32
    ) -> UInt64 {
        Ubiquitty.Rendering.glyphSlotKey(Ubiquitty.Rendering.monoGlyphKey(codePoint, weight, face, variant), variant)
    }

    /// The rasteriser's style for a variant: its tier.
    func rasterStyle(for variant: UInt32) -> GlyphRasterizer.Style {
        GlyphRasterizer.Style(tier: Ubiquitty.Rendering.variantTier(variant))
    }

    /// How far into its pixel a wide variant's pen falls: its phase over the
    /// glyph's own pen grid, the count Core keyed it at.
    func wideSubpixel(of variant: UInt32, for codePoint: UInt32, face: Ubiquitty.Rendering.FontFace) -> CGFloat {
        CGFloat(Ubiquitty.Rendering.variantPhase(variant)) / CGFloat(max(Int(wideGlyphPhaseCount(codePoint, face: face)), 1))
    }
}

extension GlyphAtlas: GlyphSource {
    /// Core's verdict on the primary face, from the advances the cell was
    /// measured from; `Proportional` has the builder lay every row out as
    /// proportional runs through ``shapePrimaryRun(_:face:weight:)``.
    var primaryFacePitch: Ubiquitty.Rendering.FontMetrics.FacePitch { facePitch }

    func shapePrimaryRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] {
        // The bitmap tier is fixed pitch and never asked; a CoreText face
        // answers from the primary faces at the pen's weight.
        guard unifontScale == 0 else { return [] }
        return primaryRuns.shape(codePoints, face: face, weight: weight)
    }

    /// Opens a frame on every sheet, after which touched slots survive
    /// eviction within it. Every cache, not just the mono one: a sheet whose
    /// frame never opens can evict a slot the same frame touched, and the
    /// cell that inherits it draws another glyph's pixels.
    func beginFrame() {
        flushRasterBatches()
        cache.beginFrame()
        wide?.beginFrame()
        proportional?.beginFrame()
        proportionalStrip?.beginFrame()
        color?.beginFrame()
        double?.beginFrame()
        ligature?.beginFrame()
    }

    /// Copies the frame's newly rasterised strips into the sheet, on the queue
    /// that is about to draw them.
    ///
    /// The copy belongs to the drawing queue rather than to the CPU: a queue
    /// executes its buffers in order, so a slot rewritten here lands after the
    /// frames that read it and before the frame that will. Written from the
    /// CPU instead, the rewrite races the frame still sampling the sheet and a
    /// run draws the next occupant's ink under its own coordinates.
    ///
    /// Every consumer draws on ``commandQueue``, including cache-hit frames
    /// that stage no uploads of their own.
    private func flushRasterBatches() {
        rasterizer.flushBatch()
        wide?.flushRasterBatch()
    }

    func flushStagedUploads() {
        flushRasterBatches()
        uploader.flush()
    }

    /// How many glyphs the mono and wide sheets have queued for a batched
    /// raster, ever: a glyph's ink is measured only when its batch lands, so a
    /// build across which this moved drew some glyphs before their ink was
    /// known.
    var enqueuedRasterCount: Int { rasterizer.enqueuedCount + (wide?.enqueuedRasterCount ?? 0) }

    /// Hands Core the slot cache and the layout for this frame.
    ///
    /// - Parameter binding: The binding to fill.
    func bindMonoAtlas(into binding: inout Ubiquitty.Rendering.MonoAtlasBinding) {
        binding.cache = cache
        binding.geometry = geometry
        binding.slotCapacity = Int32(slotCapacity)
        binding.inkBoxForSlot = UnsafePointer(inkBoxForSlot)
    }

    /// The atlas rect for a code point, rasterising it on a miss.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: The face to draw it in.
    ///   - weight: Variable-font weight, carried in the key.
    ///   - variant: The raster variant: subpixel phase, tier, thickness slot.
    /// - Returns: The glyph's rect, or an absent one when the sheet is full.
    func monoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        var fresh = false
        let slot = Int(
            cache.slotForKey(GlyphAtlas.key(codePoint, weight, face, variant), &fresh)
        )
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh {
            // Discarded because this backend cannot refuse: every path writes the
            // slot, so the answer is the same one every time. Core's hook returns
            // the bit for backends that can decline, and reading it here would
            // suggest a branch that does not exist.
            _ = rasteriseMonoGlyph(codePoint, face: face, variant: variant, slot: Int32(slot))
        }
        return atlasGlyph(for: slot)
    }

    /// Draws a code point into a slot the cache has already assigned.
    ///
    /// Uploaded whether or not the draw put down ink: a slot the cache reassigned
    /// still holds its previous glyph, so a blank has to overwrite the sheet
    /// rather than leave it — the rasteriser clears for the same reason.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - face: The face to draw it in.
    ///   - phase: The subpixel phase to position it at.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Always true. Core's hook carries the bit so a backend can say a
    ///   slot is not its own, and this one has no such path: a glyph nothing
    ///   carries takes a blank, which is written, so the slot is claimed either
    ///   way. Refusing instead would put the same question to the same face on
    ///   every frame.
    /// Copies a Core-rasterised coverage plane into a mono slot.
    ///
    /// The mirror of what ``rasteriseMonoGlyph`` does with a plane this sheet
    /// drew itself; a DECDLD soft-font glyph arrives here because its matrix
    /// came off the wire and there is nothing to look up.
    ///
    /// - Parameters:
    ///   - coverage: The R8 plane, row-major at this sheet's slot box,
    ///     borrowed from Core for the call.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether the plane was staged; false refuses a slot outside
    ///   the sheet or a plane that is not the slot box's shape, which would
    ///   otherwise stage row by row into the neighbouring slots.
    func stageMonoCoverage(_ coverage: Ubiquitty.Rendering.CoveragePlaneSpan, slot: Int32) -> Bool {
        let expected = Int(geometry.slotWidthInPixels) * Int(geometry.slotHeightInPixels)
        guard slot >= 0, Int(slot) < slotCapacity, Int(coverage.size()) == expected else {
            return false
        }
        // A plane this sheet did not draw: unmeasured, so the builder keeps the
        // slot quad rather than clipping by the previous occupant's box.
        inkBoxForSlot[Int(slot)] = Ubiquitty.Rendering.unmeasuredGlyphInkBox()
        // The one pointer extraction, at the API that demands one: Metal's
        // upload takes a raw base address, and the span outlives the call by
        // Core's own contract — the plane is the builder's scratch, live for
        // the backend call that stages it.
        uploader.stage(
            coverage.__dataUnsafe()!,
            bytesPerRow: Int(geometry.slotWidthInPixels),
            region: region(for: Int(slot)),
            into: texture
        )
        return true
    }

    func rasteriseMonoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        slot: Int32
    ) -> Bool {
        let censusStart = FillCensus.enabled ? DispatchTime.now().uptimeNanoseconds : 0
        if unifontScale > 0 {
            if (0x2500...0x257F).contains(codePoint), !Ubiquitty.Rendering.BoxDrawing.prefersProcedural(codePoint) {
                rasteriseBoxFontGlyph(codePoint, face: face, slot: slot)
                return true
            }
            // Core's face and Core's fill: the slot is the cell for a bitmap
            // family, so there is no pen, no phase and no fallback routing to
            // apply — the glyph either exists at this code point or the slot
            // stays blank.
            rasterizer.rasteriseUnifont(codePoint, scale: unifontScale, nativeWidthInPixels: 8)
            inkBoxForSlot[Int(slot)] = rasterizer.coverage.withUnsafeBufferPointer { plane in
                Ubiquitty.Rendering.measureInkBox(
                    Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                    geometry.slotWidthInPixels,
                    geometry.slotHeightInPixels
                )
            }
            rasterizer.coverage.withUnsafeBytes { bytes in
                uploader.stage(
                    bytes.baseAddress!,
                    bytesPerRow: Int(geometry.slotWidthInPixels),
                    region: region(for: Int(slot)),
                    into: texture
                )
            }
            return true
        }
        let font = faces[face]
        var characters: [UInt16] = []
        if codePoint <= 0xFFFF {
            characters = [UInt16(codePoint)]
        } else {
            let value = codePoint - 0x10000
            characters = [UInt16(0xD800 + (value >> 10)), UInt16(0xDC00 + (value & 0x3FF))]
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        var drawFont = font
        // An extension is always rebuilt from a sibling's stem, never taken
        // from the face's own extension glyph.
        //
        // The face's version can disagree with the hooks it sits between about
        // weight and about column, and in three of the faces measured it does.
        // A hook's foot cannot: it is the same ink the neighbour is drawn from.
        // A face that ships no extension at all then needs no special case --
        // the donor was going to be used regardless.
        var stemFromDonor = false
        let donor = Ubiquitty.Rendering.stemDonor(codePoint)
        do {
            if donor != 0 {
                var donorCharacters: [UInt16] = []
                if donor < 0x10000 {
                    donorCharacters = [UInt16(donor)]
                } else {
                    let value = donor - 0x10000
                    donorCharacters = [UInt16(0xD800 + (value >> 10)), UInt16(0xDC00 + (value & 0x3FF))]
                }
                var donorGlyphs = [CGGlyph](repeating: 0, count: donorCharacters.count)
                if CTFontGetGlyphsForCharacters(font, donorCharacters, &donorGlyphs, donorCharacters.count),
                    donorGlyphs[0] != 0
                {
                    glyphs = donorGlyphs
                    stemFromDonor = true
                } else if let routed = router?.routedFont(for: donor, face: face, variableWeight: 0, wantsEmoji: false),
                    CTFontGetGlyphsForCharacters(routed, donorCharacters, &donorGlyphs, donorCharacters.count),
                    donorGlyphs[0] != 0
                {
                    // The primary face lacks the hook, so the hook's own cell
                    // drew it from the face Core routed it to. The donor comes
                    // from that same face: JetBrains Mono ships no integral
                    // pieces at all, and an extension taken from the face the
                    // routing chose for U+23AE met hooks drawn from the face it
                    // chose for U+2320 -- a different stroke at both joins.
                    glyphs = donorGlyphs
                    drawFont = routed
                    stemFromDonor = true
                }
            }
        }
        if !stemFromDonor, !CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) {
            // The primary face lacks the glyph: ask Core's routing for the
            // face that carries it. A miss there still owns the slot — the
            // cache assigned it, and a return that leaves the previous
            // glyph's pixels in place shows the wrong character with every
            // count right — so the last resort is a blank, the truthful
            // raster for a glyph nothing carries.
            guard let routed = router?.routedFont(for: codePoint, face: face, variableWeight: 0, wantsEmoji: false),
                CTFontGetGlyphsForCharacters(routed, characters, &glyphs, characters.count), glyphs[0] != 0
            else {
                // The face has no glyph here, so the slot takes a blank — which
                // is written, and therefore this key's. Reporting a refusal
                // would ask the same face the same question every frame.
                rasterizer.rasteriseBlank()
                inkBoxForSlot[Int(slot)] = Ubiquitty.Rendering.emptyGlyphInkBox()
                rasterizer.coverage.withUnsafeBytes { bytes in
                    uploader.stage(
                        bytes.baseAddress!,
                        bytesPerRow: Int(geometry.slotWidthInPixels),
                        region: region(for: Int(slot)),
                        into: texture
                    )
                }
                if FillCensus.enabled {
                    FillCensus.note(lane: "monoblank", font: nil, spent: DispatchTime.now().uptimeNanoseconds - censusStart)
                }
                return true
            }
            drawFont = routed
        }
        // The pen sits inside the slot's margins. Core carries the margin per
        // axis rather than one inset, because a face whose ink overhangs
        // horizontally rarely overhangs vertically by the same amount.
        // A donor is fitted as its own piece, not as the extension it lends
        // to: a hook shrunk to the cell and pinned to the edge it continues
        // into, exactly as its own cell draws it. Fitted as an extension it was
        // stretched to the full cell, and the row sampled from that stretched
        // foot was a different stroke from the one the hook's cell shows at the
        // join.
        if let fit = tilingFit(
            stemFromDonor ? donor : codePoint,
            glyphs[0],
            in: drawFont,
            phase: Ubiquitty.Rendering.variantPhase(variant)
        ) {
            // A tiling piece is fitted to the cell rather than drawn at the
            // face's own size: its seam with the row above and below is the
            // whole of what it is for. See tilingFit.
            rasterizer.rasterise(
                glyph: glyphs[0],
                in: drawFont,
                at: fit.pen,
                verticalScale: fit.verticalScale,
                style: rasterStyle(for: variant)
            )
        } else if faces.hasUserFeatures && drawFont === font {
            let text = String(decoding: characters, as: UTF16.self)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): drawFont,
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ]
                )
            )
            rasterizer.rasterise(
                line: line,
                at: monoPen(codePoint, glyphs[0], in: drawFont, primary: font, phase: Ubiquitty.Rendering.variantPhase(variant)),
                style: rasterStyle(for: variant)
            )
        } else if !Ubiquitty.Rendering.tilingReach(codePoint).isTilingPiece && !stemFromDonor {
            inkBoxForSlot[Int(slot)] = Ubiquitty.Rendering.unmeasuredGlyphInkBox()
            rasterizer.enqueue(
                glyph: glyphs[0],
                in: drawFont,
                at: monoPen(codePoint, glyphs[0], in: drawFont, primary: font, phase: Ubiquitty.Rendering.variantPhase(variant)),
                style: rasterStyle(for: variant)
            ) { [weak self] plane in
                guard let self else { return }
                self.inkBoxForSlot[Int(slot)] = plane.withUnsafeBufferPointer { pixels in
                    Ubiquitty.Rendering.measureInkBox(
                        Ubiquitty.Rendering.CoveragePlaneSpan(pixels),
                        self.geometry.slotWidthInPixels,
                        self.geometry.slotHeightInPixels
                    )
                }
                plane.withUnsafeBytes { pixels in
                    self.uploader.stage(
                        pixels.baseAddress!,
                        bytesPerRow: Int(self.geometry.slotWidthInPixels),
                        region: self.region(for: Int(slot)),
                        into: self.texture
                    )
                }
            }
            return true
        } else {
            rasterizer.rasterise(
                glyph: glyphs[0],
                in: drawFont,
                // The pen names the BASELINE, not the box corner: CoreText's text
                // position is the baseline origin, so a pen at the bare margin puts
                // the baseline at the slot's bottom margin and the whole letterform
                // rides low by the descent. The oracle pens at margin + descent
                // (_baselineDyInPixels), and low-riding ink lands in the underline
                // band, where skip-ink then erases the rule that crosses it — one
                // wrong pen presented as two defects.
                //
                // The pen carries the phase it was keyed with: the builder chose
                // the phase from the column's fractional pen, and a slot keyed per
                // phase but drawn at phase zero holds eight copies of one raster —
                // the pixel oracle read that as bolder coverage on every column
                // whose phase is not zero. The slot is a pixel wider than the
                // glyph box for exactly this shift.
                at: monoPen(codePoint, glyphs[0], in: drawFont, primary: font, phase: Ubiquitty.Rendering.variantPhase(variant)),
                style: rasterStyle(for: variant)
            )
        }
        let boxLeft = geometry.glyphMarginInPixels.width
        let boxRight = geometry.glyphMarginInPixels.width + geometry.glyphWidthInPixels
        let boxTop = geometry.glyphMarginInPixels.height
        let boxBottom = geometry.slotHeightInPixels - geometry.glyphMarginInPixels.height
        rasterizer.finishTilingGlyph(
            codePoint: codePoint,
            drawnCodePoint: stemFromDonor ? donor : codePoint,
            glyphBoxLeft: boxLeft,
            glyphBoxRight: boxRight,
            glyphBoxTop: boxTop,
            glyphBoxBottom: boxBottom
        )
        inkBoxForSlot[Int(slot)] = rasterizer.coverage.withUnsafeBufferPointer { plane in
            Ubiquitty.Rendering.measureInkBox(
                Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                geometry.slotWidthInPixels,
                geometry.slotHeightInPixels
            )
        }
        rasterizer.coverage.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: Int(geometry.slotWidthInPixels),
                region: region(for: Int(slot)),
                into: texture
            )
        }
        if FillCensus.enabled {
            FillCensus.note(lane: "mono", font: drawFont, spent: DispatchTime.now().uptimeNanoseconds - censusStart)
        }
        return true
    }
}

extension GlyphAtlas: WideGlyphSource {
    /// Hands Core the wide sheet's slot cache and grid for this frame.
    ///
    /// Left empty when there is no wide sheet, which is Core's signal to keep a
    /// two-cell glyph on its own cell rather than emit into a pass this backend
    /// cannot draw.
    ///
    /// - Parameter binding: The binding to fill.
    func bindWideAtlas(into binding: inout Ubiquitty.Rendering.WideAtlasBinding) {
        guard let wide else {
            return
        }
        binding.cache = wide.cache
        binding.columns = Int32(wide.columns)
        binding.rows = Int32(wide.rows)
        binding.slotWidthInPixels = Int32(wide.slotWidthInPixels)
        binding.slotHeightInPixels = Int32(wide.slotHeightInPixels)
        binding.slotCapacity = Int32(wide.slotCapacity)
    }

    /// Measures the font's ink and applies Core's assembly placement.
    private func tilingFit(
        _ codePoint: UInt32,
        _ glyph: CGGlyph,
        in font: CTFont,
        phase: UInt32
    ) -> (pen: CGPoint, verticalScale: CGFloat)? {
        guard Ubiquitty.Rendering.tilesOnTextPen(codePoint) else { return nil }
        var glyphForInk = glyph
        let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphForInk, nil, 1)
        let bottom = Double(geometry.glyphMarginInPixels.height)
        let fit = Ubiquitty.Rendering.fitTilingGlyph(
            codePoint,
            Double(ink.minY),
            Double(ink.height),
            bottom,
            Double(geometry.slotHeightInPixels) - bottom * 2
        )
        guard fit.isApplicable else { return nil }
        return (
            CGPoint(
                x: CGFloat(geometry.glyphMarginInPixels.width) + CGFloat(phase) / CGFloat(subpixelPhaseCount),
                y: CGFloat(fit.baseline)
            ),
            CGFloat(fit.verticalScale)
        )
    }

    /// The pen a single-cell glyph is drawn at in its slot.
    ///
    /// A primary-face glyph stands at the slot's margin plus its phase: where
    /// the slot lands on screen is the builder's, which on a proportional
    /// face's row is the letter's own pen (LetterLayout.h). A fallback glyph
    /// is centred by its ink while retaining the primary baseline.
    ///
    /// - Parameters:
    ///   - codePoint: The cell's code point, or 0 for a shaped glyph.
    ///   - glyph: The glyph, in `font`'s numbering.
    ///   - font: The face drawing it.
    ///   - primary: The primary face for the requested style.
    ///   - phase: The subpixel phase the slot was keyed at.
    /// - Returns: The pen, in pixels from the slot's bottom-left.
    private func monoPen(_ codePoint: UInt32, _ glyph: CGGlyph, in font: CTFont, primary: CTFont, phase: UInt32) -> CGPoint {
        let subpixel = CGFloat(phase) / CGFloat(subpixelPhaseCount)
        let pen = CGPoint(
            x: CGFloat(geometry.glyphMarginInPixels.width) + subpixel,
            y: CGFloat(baselinePenInPixels)
        )
        guard !placesByFace(font, primary: primary) else {
            return pen
        }
        var glyphForInk = glyph
        let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphForInk, nil, 1)
        return SymbolFallbackPen.pen(
            codePoint: codePoint,
            ink: ink,
            subpixel: subpixel,
            glyphMarginX: CGFloat(geometry.glyphMarginInPixels.width),
            glyphWidth: CGFloat(geometry.glyphWidthInPixels),
            slotWidth: CGFloat(geometry.slotWidthInPixels),
            slotHeight: CGFloat(geometry.slotHeightInPixels),
            baselinePen: CGFloat(baselinePenInPixels)
        )
    }

    func rasteriseWideGlyph(_ codePoint: UInt32, face: Ubiquitty.Rendering.FontFace, variant: UInt32, slot: Int32) -> Bool {
        guard let wide else {
            // No two-cell sheet, so nothing was written and the slot still holds
            // whatever preceded it. Core forgets the key rather than serving it.
            return false
        }
        if unifontScale > 0 {
            // Core's face for the wide page as well, at the two-cell native
            // width. A bitmap family has no CoreText face worth asking, so a
            // two-cell glyph asked of one came back shaped by whatever the
            // cascade substituted, while the mono slots beside it drew Core's
            // own bytes — the same picture in two typefaces, one cell apart.
            wide.rasteriseUnifont(codePoint, scale: unifontScale, nativeWidthInPixels: 16, slot: Int(slot))
            return true
        }
        if FillCensus.enabled {
            let start = DispatchTime.now().uptimeNanoseconds
            let font = faceCarrying(codePoint, face: face)
            wide.rasterise(
                codePoint,
                in: font,
                style: rasterStyle(for: variant),
                subpixel: wideSubpixel(of: variant, for: codePoint, face: face),
                raisedBy: wideRaise(for: font, face: face),
                slot: Int(slot)
            )
            FillCensus.note(lane: "wide", font: font, spent: DispatchTime.now().uptimeNanoseconds - start)
            return true
        }
        let font = faceCarrying(codePoint, face: face)
        wide.rasterise(
            codePoint,
            in: font,
            style: rasterStyle(for: variant),
            subpixel: wideSubpixel(of: variant, for: codePoint, face: face),
            raisedBy: wideRaise(for: font, face: face),
            slot: Int(slot)
        )
        return true
    }

    /// The whole pixels the wide sheet raises a face's glyphs.
    ///
    /// A CJK face's ideographs centre on its ideographic character face, and
    /// the primary face's capitals on half its cap height; text mixing the two
    /// reads level when those centres meet. Where the face's centre lands is
    /// measured as the wide sheet draws it, size matching and growth included,
    /// through a reference ideograph less that glyph's own offset from the
    /// character face's centre. A face whose BASE table names no character face
    /// is measured by the reference glyph alone.
    ///
    /// The whole face moves together, so its marks and punctuation keep their
    /// places beside its ideographs. The primary face, and a face carrying none
    /// of the reference characters, keep their own placement.
    ///
    /// - Parameters:
    ///   - font: The face a glyph is drawn in.
    ///   - face: Bold and italic, which pick the primary face.
    /// - Returns: The raise in pixels, zero for a face left where it stands.
    private func wideRaise(for font: CTFont, face: Ubiquitty.Rendering.FontFace) -> CGFloat {
        let primary = faces[face]
        guard let wide, !CFEqual(font, primary) else {
            return 0
        }
        let key = "\(CTFontCopyPostScriptName(font)) \(CTFontGetSize(font)) \(face.rawValue)"
        if let known = wideRaises[key] {
            return known
        }
        var raise: CGFloat = 0
        // 漢, 国, 한 and あ: a Han, a Hangul and a kana face each carry one.
        for reference: UInt32 in [0x6F22, 0x56FD, 0xD55C, 0x3042] {
            guard let glyph = GlyphAtlas.glyphIdentifier(for: reference, in: font),
                let drawn = wide.drawnInkCentre(of: reference, glyph: glyph, in: font)
            else {
                continue
            }
            var inkGlyph = glyph
            let ink = CTFontGetBoundingRectsForGlyphs(font, .default, &inkGlyph, nil, 1)
            let offsetFromFace = ideographicCharacterFaceCentre(font).map { ink.midY - $0 } ?? 0
            raise = (CTFontGetCapHeight(primary) / 2 - (drawn - offsetFromFace)).rounded()
            break
        }
        wideRaises[key] = raise
        return raise
    }

    func wideGlyphPhaseCount(_ codePoint: UInt32, face: Ubiquitty.Rendering.FontFace) -> Int32 {
        // A bitmap family places by Core's own grid, and without a sheet there
        // is no growth to measure.
        guard let wide, unifontScale == 0 else {
            return Int32(widePhaseCount)
        }
        let key = UInt64(codePoint) << 8 | UInt64(face.rawValue)
        if let known = widePenGrids[key] {
            return known
        }
        let font = faceCarrying(codePoint, face: face)
        let count =
            GlyphAtlas.glyphIdentifier(for: codePoint, in: font).map { Int32(wide.penGridPhaseCount(sizedBy: $0, in: font)) }
            ?? Int32(widePhaseCount)
        widePenGrids[key] = count
        return count
    }

    /// The primary face when it carries the glyph, else the routed one.
    ///
    /// The wide and double sheets draw whole code points, so the resolution
    /// happens here and the sheets stay routing-blind — one router, one
    /// answer, whichever sheet asks.
    ///
    /// - Parameters:
    ///   - codePoint: The character about to be drawn.
    ///   - face: Bold and italic, which pick the style.
    /// - Returns: The face to draw with.
    private func faceCarrying(_ codePoint: UInt32, face: Ubiquitty.Rendering.FontFace) -> CTFont {
        let primary = faces[face]
        if GlyphAtlas.glyphIdentifier(for: codePoint, in: primary) != nil {
            return primary
        }
        return router?.routedFont(for: codePoint, face: face, variableWeight: 0, wantsEmoji: false) ?? primary
    }
}

extension GlyphAtlas: WideClusterGlyphSource {
    /// The atlas rect for a two-cell base carrying combining marks.
    ///
    /// Keyed and drawn at the variant's phase and tier, as the plain wide glyph
    /// is. The wide sheet carries its own keyspace, so the same derivation the
    /// mono page uses keys this one without collision across the two.
    ///
    /// Empty when there is no wide sheet, which leaves Core to draw the base on
    /// its own cell rather than route a glyph into a pass this backend cannot
    /// sample.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - face: Which face to shape it in.
    ///   - weight: Unused here; this atlas applies no variable weight.
    ///   - variant: The raster variant; its tier keys the slot and weights the raster.
    /// - Returns: The glyph, or an absent one.
    func wideClusterGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        // One extraction at the seam's consumer: the helpers below take typed
        // buffers, and the span's borrow covers this call.
        let codePoints = UnsafeBufferPointer(start: codePoints.__dataUnsafe(), count: Int(codePoints.size()))
        guard let wide, let base = codePoints.baseAddress, !codePoints.isEmpty else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        let key = Ubiquitty.Rendering.glyphSlotKey(
            Ubiquitty.Rendering.coverageClusterKey(
                base,
                Int32(codePoints.count),
                Int32(Ubiquitty.Rendering.variantPhase(variant)),
                face
            ),
            variant
        )
        var fresh = false
        // Verified for the reason the mono page is: the key folds a
        // variable-length run, and an unchecked hit serves another cluster's
        // pixels.
        let slot = Int(wide.cache.slotForKeyVerified(key, base, Int32(codePoints.count), &fresh))
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh && unifontScale > 0 {
            wide.rasteriseUnifontCluster(Ubiquitty.Rendering.ClusterSpan(codePoints), scale: unifontScale, slot: slot)
        } else if fresh {
            if let shaped = drawableClusterLine(codePoints, face: face) {
                let baseFont = faceCarrying(shaped.base, face: face)
                wide.rasterise(
                    cluster: shaped.line,
                    baseGlyph: GlyphAtlas.glyphIdentifier(for: shaped.base, in: baseFont) ?? 0,
                    in: baseFont,
                    style: rasterStyle(for: variant),
                    subpixel: wideSubpixel(of: variant, for: shaped.base, face: face),
                    raisedBy: wideRaise(for: baseFont, face: face),
                    slot: slot
                )
            } else {
                wide.rasteriseBlankSlot(slot)
            }
        }
        let uv = wide.atlasRectForSlot(slot)
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = uv.minU
        glyph.minUV.y = uv.minV
        glyph.maxUV.x = uv.maxU
        glyph.maxUV.y = uv.maxV
        glyph.present = true
        return glyph
    }
}

extension GlyphAtlas: ProportionalGlyphSource {
    func bindProportionalAtlas(into binding: inout Ubiquitty.Rendering.ProportionalAtlasBinding) {
        guard let proportional else {
            return
        }
        binding.cache = proportional.cache
        binding.columns = Int32(proportional.columns)
        binding.rows = Int32(proportional.rows)
        binding.slotWidthInPixels = Int32(proportional.slotWidthInPixels)
        binding.slotHeightInPixels = Int32(proportional.slotHeightInPixels)
        binding.slotCapacity = Int32(proportional.slotCapacity)
        // The bitmap tier's slot carries the strike's overhang as its margin,
        // which is where the builder lifts the quad from; the native tier's
        // is the wide canvas's own.
        binding.marginInPixels = bitmapProportionalPlan?.marginInPixels ?? geometry.glyphMarginInPixels
        binding.phaseCount = Int32(subpixelPhaseCount)
    }

    func shapeProportionalRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] {
        // The proportional sheet is where the glyphs go, so a run shapes only when it
        // has somewhere to draw; the weight is the UI face's own and takes
        // none, the way the strip takes none.
        guard proportional != nil else {
            return []
        }
        if unifontScale > 0 {
            // Core's strike shapes the bitmap tier's run — one glyph per code
            // point, kerned as the strike records — so the identities the
            // builder places are the reference's.
            let count = Int(codePoints.size())
            guard count > 0 else { return [] }
            var shaped = [Ubiquitty.ProportionalShapedGlyph](repeating: Ubiquitty.ProportionalShapedGlyph(), count: count)
            let written = shaped.withUnsafeMutableBufferPointer { out in
                Ubiquitty.Rendering.shapeUnifontProportionalRun(Int32(unifontScale), codePoints, face, out.baseAddress, Int32(out.count))
            }
            return written > 0 ? Array(shaped.prefix(Int(written))) : []
        }
        guard let proportionalStrip else {
            return []
        }
        return proportionalStrip.shapeProportionalRun(codePoints, face: face)
    }

    func rasteriseProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32,
        slot: Int32
    ) -> Bool {
        _ = weight
        guard let proportional, glyphID != 0, slot >= 0 else {
            return false
        }
        if let plan = bitmapProportionalPlan {
            return proportional.rasteriseUnifontProportionalGlyph(
                glyphID,
                face: face,
                variant: variant,
                scale: unifontScale,
                plan: plan,
                slot: Int(slot)
            )
        }
        guard let proportionalStrip else {
            return false
        }
        let phase = Ubiquitty.Rendering.variantPhase(variant)
        proportional.rasterise(
            glyph: CGGlyph(truncatingIfNeeded: glyphID),
            in: proportionalStrip.proportionalFont(forFace: face),
            phase: Int(phase),
            phaseCount: subpixelPhaseCount,
            style: rasterStyle(for: variant),
            slot: Int(slot)
        )
        return true
    }

    /// One slot-sized window of a proportional glyph drawn larger than its
    /// slot: for a DECDWL row, a DECDHL pair or an OSC 66 scale.
    ///
    /// Doubled across, on a DECDWL row, the glyph is drawn from the
    /// proportional face widened on its `wdth` axis where the family has one,
    /// scaled across by what the axis left, so the doubled run keeps its
    /// letterforms rather than stretching them; a family with no axis draws
    /// its own glyph twice as wide. On a DECDHL pair or at a scale it is drawn
    /// at that size both ways from the face itself, as a sized block's masters
    /// are, and the window is cut from the slot height the tile's band names.
    /// The bitmap tier draws Core's reference window, the strike at the whole
    /// size and whole texels past it.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph, as the proportional shaper named it.
    ///   - face: The style the run was shaped in.
    ///   - weight: Unused; the face carries its weight.
    ///   - variant: The sized origin's subpixel phase and coverage tier.
    ///   - tile: The scale, the band, the window and the doubling across.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether the window was drawn.
    func rasteriseSizedProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32,
        tile: Ubiquitty.Rendering.SizedTile,
        slot: Int32
    ) -> Bool {
        _ = weight
        let scale = Int(tile.scale)
        let widthScale = tile.widthScale == 2 ? 2 : 1
        guard let proportional, glyphID != 0, slot >= 0, scale >= 1, Int(tile.band) < scale, scale * widthScale > 1,
            !tile.isFractional()
        else {
            return false
        }
        if let plan = bitmapProportionalPlan {
            return proportional.rasteriseUnifontSizedProportionalGlyph(
                glyphID,
                face: face,
                variant: variant,
                tile: tile,
                scale: unifontScale,
                plan: plan,
                slot: Int(slot)
            )
        }
        guard let proportionalStrip else {
            return false
        }
        let font = proportionalStrip.proportionalFont(forFace: face)
        var glyph = CGGlyph(truncatingIfNeeded: glyphID)
        var drawnFont = font
        var horizontalScale = CGFloat(widthScale)
        // A variable face keeps its glyph identities across instances, so the
        // shaper's glyph names the same letter in the widened one.
        if widthScale == 2, let widened = proportionalStrip.doubleWidthProportionalFont(forFace: face) {
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
            let widenedAdvance = CTFontGetAdvancesForGlyphs(widened, .horizontal, &glyph, nil, 1)
            if advance > 0, widenedAdvance > advance {
                drawnFont = widened
                horizontalScale = 2 * advance / widenedAdvance
            }
        }
        proportional.rasteriseSizedWindow(
            glyph: glyph,
            in: drawnFont,
            scale: scale,
            widthScale: widthScale,
            horizontalScale: horizontalScale,
            phase: Int(Ubiquitty.Rendering.variantPhase(variant)),
            phaseCount: subpixelPhaseCount,
            window: Int(tile.tile),
            band: Int(tile.band),
            style: rasterStyle(for: variant),
            slot: Int(slot)
        )
        return true
    }
}

extension GlyphAtlas: DoubleGlyphSource {
    /// The atlas rect for a double-size master's region, rasterising on a miss.
    ///
    /// The key's weight lane is zero because this backend rasterises at the
    /// face's own weight rather than a variable axis.
    ///
    /// - Parameters:
    ///   - codePoint: The code point to draw at twice the cell size.
    ///   - face: Which face to draw it in; bold and italic key their own master.
    ///   - variant: The raster variant; its tier keys the master and weights the raster.
    ///   - region: The slice the row draws — the whole master for DECDWL, the
    ///     upper or lower half for a DECDHL pair.
    /// - Returns: The region's rect, or an absent one.
    func doubleGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        region: Ubiquitty.Rendering.DoubleRegion
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        guard unifontScale == 0, let double, codePoint != 0, codePoint != 0x20 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        // A DECDWL row draws from the face widened on its width axis, where the
        // family has one; the DECDHL pair keeps the uniform master it shares.
        let widened = region == .Full ? faces.doubleWidthFace(face) : nil
        var fresh = false
        let masterKey =
            widened == nil
            ? Ubiquitty.Rendering.doubleMasterKey(codePoint, 0, face)
            : Ubiquitty.Rendering.doubleWidthMasterKey(codePoint, 0, face)
        let key = Ubiquitty.Rendering.glyphSlotKey(masterKey, variant)
        let slot = Int(double.cache.slotForKey(key, &fresh))
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh {
            // The doubled cell box inside the doubled margins, which is where
            // a box glyph's strokes must reach for a DECDWL run to meet.
            let marginX = 2 * Int(geometry.glyphMarginInPixels.width)
            let marginY = 2 * Int(geometry.glyphMarginInPixels.height)
            let cellBox = (
                x0: marginX,
                x1: double.slotWidthInPixels - marginX,
                y0: marginY,
                y1: double.slotHeightInPixels - marginY
            )
            if let widened {
                double.rasteriseDoubleWidthMaster(
                    codePoint,
                    in: faces[face],
                    widened: widened,
                    style: rasterStyle(for: variant),
                    slot: slot,
                    cellBox: cellBox
                )
            } else {
                double.rasteriseDoubleMaster(
                    codePoint,
                    in: faces[face],
                    style: rasterStyle(for: variant),
                    slot: slot,
                    cellBox: cellBox
                )
            }
        }
        return Ubiquitty.Rendering.doubleRegionUV(
            Int32(slot),
            Ubiquitty.GridSize(columns: Int32(double.columns), rows: Int32(double.rows)),
            Ubiquitty.IntSize(width: Int32(double.slotWidthInPixels), height: Int32(double.slotHeightInPixels)),
            region
        )
    }
}

extension GlyphAtlas: SizedGlyphSource {
    /// One cell-shaped window of a mono glyph rasterised at the block's scale.
    ///
    /// The window lands in an ordinary mono slot under `sizedTileKey`, probed
    /// VERIFIED with the same two words the key folds — the fold hashes a
    /// variable field set into 29 bits, so an unchecked hit would serve
    /// another window's pixels the way an unchecked cluster hit would another
    /// cluster's.
    ///
    /// The window is Core's: it selects the master, places the glyph in it and
    /// cuts the window out (SizedMaster.h), so the picture is the one every arm
    /// draws. CoreText draws the master at the size and pen Core names.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: Which face to draw it in.
    ///   - weight: Variable-font weight lane for the key.
    ///   - phase: Subpixel phase the anchor was positioned at.
    ///   - tile: Which window of the scaled glyph.
    /// - Returns: The window's cell-box rect, or an absent one — absent keeps
    ///   the cell on the crop, which draws the same picture soft.
    func sizedGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        phase: UInt32,
        pass: Ubiquitty.Rendering.GlyphPass,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        // A bitmap family gains nothing here: its 3x is the magnified crop by
        // another route, so the crop path answers and no slot is spent.
        // A fractional tile is any size but one; a whole one is two or more.
        guard unifontScale == 0, codePoint != 0, codePoint != 0x20, tile.scale >= 2 || tile.isFractional() else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        let scaleLane = tile.scaleLane()
        let key = Ubiquitty.Rendering.glyphSlotKey(
            Ubiquitty.Rendering.sizedTileKey(
                codePoint,
                weight,
                face,
                Ubiquitty.Rendering.variantPhase(phase),
                scaleLane,
                UInt32(tile.band),
                UInt32(tile.tile)
            ),
            phase
        )
        let verify: [UInt32] = [
            codePoint,
            Ubiquitty.Rendering.sizedTileWord(
                weight,
                face,
                Ubiquitty.Rendering.variantPhase(phase),
                scaleLane,
                UInt32(tile.band),
                UInt32(tile.tile)
            ),
        ]
        var fresh = false
        let slot = Int(cache.slotForKeyVerified(key, verify, Int32(verify.count), &fresh))
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh {
            let carrying = faceCarrying(codePoint, face: face)
            guard let glyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: carrying) else {
                // Nothing carries the glyph. The crop path draws whatever the
                // 1x lookup resolved — including its blank — so the slot goes
                // back rather than holding a blank the soft path already has.
                cache.forgetKey(key)
                return Ubiquitty.Rendering.AtlasGlyph()
            }
            let font = carrying
            let isPlacedByFace = placesByFace(font, primary: faces[face])
            var widened: (glyph: CGGlyph, font: CTFont)?
            if tile.widthScale == 2, isPlacedByFace, let widenedFont = faces.doubleWidthFace(face),
                let widenedGlyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: widenedFont)
            {
                widened = (widenedGlyph, widenedFont)
            }
            var canvas = Ubiquitty.Rendering.sizedWindowCanvas(
                geometry.slotWidthInPixels,
                geometry.slotHeightInPixels,
                geometry.glyphMarginInPixels.width,
                geometry.glyphMarginInPixels.height,
                geometry.referenceLineHeightInPixels,
                geometry.referenceAdvanceInPixels,
                1,
                tile.step,
                Float(geometry.glyphWidthInPixels)
            )
            canvas.isGlyphBottomAligned = true
            let window =
                sizedRaster.rasterise(
                    SizedWindowFace(
                        glyph: glyph,
                        font: font,
                        widened: widened,
                        room: widened == nil ? Ubiquitty.Rendering.WidthAxisRoom() : faces.widthAxisRoom(face),
                        pen: isPlacedByFace
                            ? .advanceCentred
                            : .placed(monoPen(codePoint, glyph, in: font, primary: faces[face], phase: 0))
                    ),
                    tile: tile,
                    phase: phase,
                    canvas: canvas,
                    baselinePenInPixels: CGFloat(baselinePenInPixels),
                    boostCap: 0,
                    style: rasterStyle(for: phase)
                ) ?? [UInt8](repeating: 0, count: Int(canvas.width) * Int(canvas.height))
            window.withUnsafeBytes { bytes in
                uploader.stage(
                    bytes.baseAddress!,
                    bytesPerRow: Int(geometry.slotWidthInPixels),
                    region: region(for: slot),
                    into: texture
                )
            }
        }
        if pass == .Subpixel {
            return atlasGlyph(for: slot)
        }
        // The cell-baked flavour: the glyph box, the rect the builder's
        // non-subpixel branch derives for an unsized glyph. Its window was cut at
        // the cell box, the step the cell it maps onto advances by, so the
        // quad takes the whole rect texel for texel.
        let uv = geometry.atlasRectForSlot(Int32(slot), Int32(slotCapacity))
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = uv.minU
        glyph.minUV.y = uv.minV
        glyph.maxUV.x = uv.maxU
        glyph.maxUV.y = uv.maxV
        glyph.present = true
        return glyph
    }

    /// Whether the face draws a glyph at the pen Core places, and not at one the
    /// sheet chooses for it.
    ///
    /// A primary-face glyph stands where its advance puts it. A glyph from another
    /// face is centred by its own ink — the symbol fallback's rule — and the
    /// primary's metrics say nothing of where that ink falls.
    ///
    /// - Parameters:
    ///   - font: The face drawing the glyph.
    ///   - primary: The primary face for the requested style.
    /// - Returns: True for a glyph the primary face places.
    private func placesByFace(_ font: CTFont, primary: CTFont) -> Bool {
        CFEqual(font, primary) && router?.isSymbolFallbackFace(font) != true
    }

    /// One two-cell window of a wide glyph rasterised at the block's scale.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: Which face to draw it in.
    ///   - variant: The raster variant; its tier keys the slot and weights the raster.
    ///   - tile: Which window of the scaled glyph.
    /// - Returns: The window's full-slot rect, matching what the wide route
    ///   returns for an unsized glyph, or an absent one.
    func sizedWideGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        // A fractional tile is drawn at its own size, whatever it is; a whole
        // one is two or more. Doubled rows widen a glyph, which no wide window
        // describes, so a widened tile keeps the crop.
        guard let wide, unifontScale == 0, codePoint != 0, tile.scale >= 2 || tile.isFractional(), tile.widthScale <= 1 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        let scaleLane = tile.scaleLane()
        // Phase zero in the fold: a sized block's windows step by whole cells
        // from the block's own origin, so they carry no pen phase.
        let key = Ubiquitty.Rendering.sizedTileKey(
            codePoint,
            0,
            face,
            0,
            scaleLane,
            UInt32(tile.band),
            UInt32(tile.tile)
        )
        let verify: [UInt32] = [
            codePoint,
            Ubiquitty.Rendering.sizedTileWord(0, face, 0, scaleLane, UInt32(tile.band), UInt32(tile.tile)),
        ]
        var fresh = false
        let slot = Int(
            wide.cache.slotForKeyVerified(Ubiquitty.Rendering.glyphSlotKey(key, variant), verify, Int32(verify.count), &fresh)
        )
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh {
            let font = faceCarrying(codePoint, face: face)
            let window: [UInt8]
            if let glyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: font) {
                // The wide page is two cells across, so a window steps two
                // advances. The wide sheet places its glyph at its own pen, the
                // advance centred in the two cells and the face raised to the
                // primary's cap height, and grows it toward the slot, which the
                // master draws as well.
                var canvas = Ubiquitty.Rendering.sizedWindowCanvas(
                    Int32(wide.slotWidthInPixels),
                    Int32(wide.slotHeightInPixels),
                    geometry.glyphMarginInPixels.width,
                    geometry.glyphMarginInPixels.height,
                    geometry.referenceLineHeightInPixels,
                    geometry.referenceAdvanceInPixels,
                    2,
                    tile.step,
                    Float(2 * geometry.glyphWidthInPixels)
                )
                canvas.isGlyphBottomAligned = true
                window =
                    sizedRaster.rasterise(
                        SizedWindowFace(
                            glyph: glyph,
                            font: font,
                            widened: nil,
                            room: Ubiquitty.Rendering.WidthAxisRoom(),
                            pen: .placed(wide.centredPen(of: glyph, in: font, raisedBy: wideRaise(for: font, face: face)))
                        ),
                        tile: tile,
                        phase: 0,
                        canvas: canvas,
                        baselinePenInPixels: CGFloat(baselinePenInPixels),
                        boostCap: wide.boostCap,
                        style: rasterStyle(for: variant)
                    ) ?? [UInt8](repeating: 0, count: wide.slotWidthInPixels * wide.slotHeightInPixels)
            } else {
                window = [UInt8](repeating: 0, count: wide.slotWidthInPixels * wide.slotHeightInPixels)
            }
            wide.upload(window, slot: slot)
        }
        let uv = wide.atlasRectForSlot(slot)
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = uv.minU
        glyph.minUV.y = uv.minV
        glyph.maxUV.x = uv.maxU
        glyph.maxUV.y = uv.maxV
        glyph.present = true
        return glyph
    }

    /// One square window of a colour cluster rasterised at the block's scale.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - tile: Which window of the source square's grid.
    /// - Returns: The window's pixel-boundary slot rect, as Core derives for every
    ///   colour slot, or an absent one.
    func sizedColorGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        let codePointsBuffer = UnsafeBufferPointer(start: codePoints.__dataUnsafe(), count: Int(codePoints.size()))
        guard let color, let base = codePointsBuffer.baseAddress, !codePointsBuffer.isEmpty, tile.scale >= 2 || tile.isFractional() else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        // The fold and the verification carry the cluster PLUS the tile word,
        // so a family and its own windows occupy distinct slots and a hash
        // collision re-rasterises instead of serving another window. A
        // fraction rides the scale lane, so each drawn size keys its own.
        let tileWord = Ubiquitty.Rendering.sizedTileWord(
            0,
            Ubiquitty.Rendering.FontFace.Regular,
            0,
            tile.scaleLane(),
            UInt32(tile.band),
            UInt32(tile.tile)
        )
        let key = Ubiquitty.Rendering.sizedColorTileKey(base, Int32(codePointsBuffer.count), tileWord)
        var verify = Array(codePointsBuffer)
        verify.append(tileWord)
        var fresh = false
        let slot = Int(color.cache.slotForKeyVerified(UInt64(key), verify, Int32(verify.count), &fresh))
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh {
            guard let font = router?.routedFont(for: codePointsBuffer.span, face: .Regular, variableWeight: 0, wantsEmoji: true),
                color.rasteriseSized(codePointsBuffer, font: font, slot: Int32(slot), tile: tile)
            else {
                color.cache.forgetKey(UInt64(key))
                return Ubiquitty.Rendering.AtlasGlyph()
            }
        }
        var binding = Ubiquitty.Rendering.ColorAtlasBinding()
        bindColorAtlas(into: &binding)
        let uv = binding.atlasRectForSlot(Int32(slot))
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = uv.minU
        glyph.minUV.y = uv.minV
        glyph.maxUV.x = uv.maxU
        glyph.maxUV.y = uv.maxV
        glyph.present = true
        return glyph
    }
}

extension GlyphAtlas: ShapedGlyphSource {
    /// Draws the glyph a shaper already chose into the mono slot Core keyed by
    /// that glyph's identity.
    ///
    /// The strip path keys a slot by the TEXT that produced it, and text
    /// fragments do not repeat: one screen of this repo's sources needs 51,983
    /// distinct fragment keys against a sheet of 4,096, and the count grows
    /// with the corpus. The glyphs a face actually draws do not grow — the
    /// whole source tree reaches about 450 — so a slot keyed by the glyph is
    /// bounded where a slot keyed by the fragment is not, and the thrash that
    /// costs 2.1 seconds of CoreText in a 25-second scroll disappears with it.
    ///
    /// The identity is the face's own, so the id must be interpreted in the
    /// face that produced it: a producer that let the shaper fall back to
    /// another family reports no shaped glyph rather than an id this face
    /// would read as a different letter.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph, in `face`'s own numbering.
    ///   - face: The style to draw it in.
    ///   - variant: The raster variant; its phase rides the pen as it does on
    ///     the mono path.
    ///   - slot: The slot the cache assigned.
    /// - Returns: False for a bitmap family, whose cells Core rasterises from
    ///   code points and which has no glyph ids to draw.
    func rasteriseShapedGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        slot: Int32
    ) -> Bool {
        guard unifontScale == 0 else {
            return false
        }
        let glyph = CGGlyph(truncatingIfNeeded: glyphID)
        let font = faces[face]
        rasterizer.rasterise(
            glyph: glyph,
            in: font,
            at: monoPen(0, glyph, in: font, primary: faces[face], phase: Ubiquitty.Rendering.variantPhase(variant)),
            style: rasterStyle(for: variant)
        )
        // The mono sheet's slots are shared, so every writer owes the ink table
        // its entry: the box an evicted glyph left would otherwise describe
        // pixels this raster has replaced.
        inkBoxForSlot[Int(slot)] = rasterizer.coverage.withUnsafeBufferPointer { plane in
            Ubiquitty.Rendering.measureInkBox(
                Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                geometry.slotWidthInPixels,
                geometry.slotHeightInPixels
            )
        }
        rasterizer.coverage.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: Int(geometry.slotWidthInPixels),
                region: region(for: Int(slot)),
                into: texture
            )
        }
        return true
    }
}

extension GlyphAtlas: ClusterGlyphSource {
    /// The atlas rect for a combining cluster, rasterising it on a miss.
    ///
    /// Clusters live on the mono sheet under Core's cluster keyspace
    /// (`coverageClusterKey`), so a base plus its marks shares one slot per
    /// style and phase with no second cache to keep in step. The weight is
    /// not part of that key — Core folds the cluster's content, style and
    /// phase only — so it is accepted and unused here, exactly as the Metal
    /// arm's adapter accepts and drops it.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - face: Which face to shape it in.
    ///   - weight: Variable-font weight; not a key lane for clusters.
    ///   - phase: Subpixel phase the cluster was positioned at.
    /// - Returns: The cluster's atlas rect, or an absent one.
    func clusterGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        phase: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        // One extraction at the seam's consumer: the helpers below take typed
        // buffers, and the span's borrow covers this call. The span itself
        // survives beside the buffer because the miss path re-enters the seam
        // through ``rasteriseClusterGlyph``, which speaks the span.
        let codePointsSpan = codePoints
        let codePoints = UnsafeBufferPointer(start: codePoints.__dataUnsafe(), count: Int(codePoints.size()))
        guard let base = codePoints.baseAddress, !codePoints.isEmpty else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        var fresh = false
        let key = Ubiquitty.Rendering.glyphSlotKey(
            Ubiquitty.Rendering.coverageClusterKey(
                base,
                Int32(codePoints.count),
                Int32(Ubiquitty.Rendering.variantPhase(phase)),
                face
            ),
            phase
        )
        // Verified, because the key is a 23-bit fold of a variable-length run:
        // two clusters can land on one key, and a hit that skipped the contents
        // comparison serves the other cluster's pixels for as long as the slot
        // stays resident. The verified probe re-rasterises on that collision,
        // which is what makes the fold's width a cost question rather than a
        // correctness one — the same discipline LigatureSheet already applies to
        // its strips, and the one Core states in faultClusterSlot.
        let slot = Int(cache.slotForKeyVerified(key, base, Int32(codePoints.count), &fresh))
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if fresh {
            // Discarded for the reason the mono path states: this backend writes
            // the slot on every path, so it never declines one.
            _ = rasteriseClusterGlyph(codePointsSpan, face: face, phase: phase, slot: Int32(slot))
        }
        return atlasGlyph(for: slot)
    }

    /// Shapes a cluster into a line, in the face its base belongs to, without
    /// the code points only LastResort draws.
    ///
    /// One CTLine over the whole run, so CoreText positions each mark against the
    /// base's advance and substitutes a face for a mark the base face lacks.
    ///
    /// The base's face is resolved rather than assumed to be the primary one: a
    /// line left to fall back on its own picks a face CoreText chooses, and for a
    /// base the primary face does not carry that is not the face the single-glyph
    /// path draws — so the same character would render at two sizes depending on
    /// whether a mark rode with it.
    ///
    /// A code point no installed face carries falls to LastResort, whose glyph is
    /// a drawn box. Those code points are left out and the rest shaped again, so
    /// one of them costs only its own glyph and not the whole cluster's.
    ///
    /// The base is the first code point that is not a Prepend, which a cluster
    /// led by one carries ahead of it.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, in order.
    ///   - face: The requested face.
    /// - Returns: The shaped line and the base it was shaped for, or `nil` when
    ///   LastResort is the only face for every code point in it.
    private func drawableClusterLine(
        _ codePoints: UnsafeBufferPointer<UInt32>,
        face: Ubiquitty.Rendering.FontFace
    ) -> (line: CTLine, base: UInt32)? {
        let base =
            codePoints.isEmpty
            ? 0 : codePoints[Int(Ubiquitty.Unicode.clusterBaseIndex(Ubiquitty.Rendering.ClusterSpan(codePoints)))]
        let font = codePoints.isEmpty ? faces[face] : faceCarrying(base, face: face)
        let string = clusterString(codePoints)
        let line = clusterLine(string, font: font)
        guard ctLineHasLastResortRun(line) else {
            return (line, base)
        }
        let kept = stringOutsideLastResort(string, shapedAs: line)
        guard !kept.isEmpty else {
            return nil
        }
        let reshaped = clusterLine(kept, font: font)
        return ctLineHasLastResortRun(reshaped) ? nil : (reshaped, base)
    }

    /// A cluster's code points as a string, up to the pool's longest cluster.
    ///
    /// - Parameter codePoints: The cluster, in order.
    /// - Returns: The string, without any value that is not a Unicode scalar.
    private func clusterString(_ codePoints: some Sequence<UInt32>) -> String {
        var scalars = String.UnicodeScalarView()
        for codePoint in codePoints.prefix(Int(Ubiquitty.clusterPoolMaximumCodePoints)) {
            guard let scalar = Unicode.Scalar(codePoint) else {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Shapes a cluster's string into a line in a given base font.
    ///
    /// - Parameters:
    ///   - string: The cluster.
    ///   - baseFace: The font the base is drawn in.
    /// - Returns: The shaped line.
    private func clusterLine(_ string: String, font baseFace: CTFont) -> CTLine {
        let attributed = NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): baseFace,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
        )
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Shapes a cluster into a slot the cache has already assigned.
    ///
    /// One CTLine over the cluster's string, so CoreText positions each mark
    /// against the base's advance and substitutes a face for a mark the base
    /// face lacks — a decomposed cluster then sits exactly where its
    /// precomposed twin would, at the same baseline pen the mono path uses.
    /// The code points CoreText resolved to LastResort are left out: that
    /// fallback carries a drawn box for every code point, so baking it puts
    /// tofu in a slot the cache then serves for the cluster's whole lifetime.
    /// A cluster with nothing else to draw is left blank. The upload happens
    /// either way, because the slot may hold a previous glyph and blank has to
    /// overwrite the sheet rather than leave it.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - face: Which face to shape it in.
    ///   - phase: Subpixel phase to position it at.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Always true, for the reason ``rasteriseMonoGlyph(_:face:phase:slot:)``
    ///   states: the upload happens on every path, including the LastResort blank,
    ///   so the slot is this key's whatever the shaping produced.
    func rasteriseClusterGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        phase: UInt32,
        slot: Int32
    ) -> Bool {
        // One extraction at the seam's consumer: the helpers below take typed
        // buffers, and the span's borrow covers this call.
        let codePoints = UnsafeBufferPointer(start: codePoints.__dataUnsafe(), count: Int(codePoints.size()))
        if unifontScale > 0 {
            rasterizer.rasteriseUnifontCluster(Ubiquitty.Rendering.ClusterSpan(codePoints), scale: unifontScale)
        } else if let shaped = drawableClusterLine(codePoints, face: face) {
            // The phase rides the pen here as it does on the mono path: a cluster
            // keyed per phase and drawn at phase zero is the same eight-copies
            // shape, one cache over.
            let pen = CGPoint(
                x: CGFloat(geometry.glyphMarginInPixels.width) + CGFloat(Ubiquitty.Rendering.variantPhase(phase))
                    / CGFloat(subpixelPhaseCount),
                y: CGFloat(baselinePenInPixels)
            )
            rasterizer.rasterise(line: shaped.line, at: pen, style: rasterStyle(for: phase))
        } else {
            rasterizer.rasteriseBlank()
        }
        // A cluster shares the mono sheet's slots, so it owes the ink table the
        // same entry every other writer of those slots owes: the box left by an
        // evicted mono glyph would otherwise describe pixels this raster just
        // replaced.
        inkBoxForSlot[Int(slot)] = rasterizer.coverage.withUnsafeBufferPointer { plane in
            Ubiquitty.Rendering.measureInkBox(
                Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                geometry.slotWidthInPixels,
                geometry.slotHeightInPixels
            )
        }
        rasterizer.coverage.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: Int(geometry.slotWidthInPixels),
                region: region(for: Int(slot)),
                into: texture
            )
        }
        return true
    }
}

extension GlyphAtlas: ColorGlyphSource {
    /// Hands Core the colour sheet's slot cache and grid for this frame.
    ///
    /// Left empty when there is no colour sheet, which is Core's signal to
    /// keep an emoji on the mono path rather than emit into a pass this
    /// backend cannot draw.
    ///
    /// - Parameter binding: The binding to fill.
    func bindColorAtlas(into binding: inout Ubiquitty.Rendering.ColorAtlasBinding) {
        guard let color else {
            return
        }
        binding.cache = color.cache
        binding.columns = Int32(color.columns)
        binding.rows = Int32(color.rows)
        binding.slotInPixels = Int32(color.slotInPixels)
        binding.slotCapacity = Int32(color.slotCapacity)
    }

    /// Draws a colour cluster into a slot the colour cache assigned.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster to draw; one code point is a lone emoji.
    ///   - slot: The slot the cache assigned.
    func rasteriseColorGlyph(_ codePoints: Ubiquitty.Rendering.ClusterSpan, slot: Int32) -> Bool {
        // One extraction at the seam's consumer: the helpers below take typed
        // buffers, and the span's borrow covers this call.
        let codePoints = UnsafeBufferPointer(start: codePoints.__dataUnsafe(), count: Int(codePoints.size()))
        guard let color,
            let font = router?.routedFont(for: codePoints.span, face: .Regular, variableWeight: 0, wantsEmoji: true)
        else {
            return false
        }
        return color.rasterise(codePoints, font: font, slot: slot)
    }
}

extension GlyphAtlas: LigatureGlyphSource {
    var canPrepareLigatures: Bool { ligature?.canPrepareLigatures == true }

    func prepareLigatureRow(_ row: Ubiquitty.Rendering.LigatureRowSpan, cellWidthInPixels: Float) {
        withLigatureCells(row) { cells in
            ligature?.prepareRow(cells, pitch: cellWidthInPixels)
        }
    }

    /// Borrows the callback's C++ row for Swift consumers without copying cells.
    private func withLigatureCells(
        _ row: Ubiquitty.Rendering.LigatureRowSpan,
        _ body: (Span<Ubiquitty.Rendering.LigatureCell>) -> Void
    ) {
        let cells = UnsafeBufferPointer(start: row.__dataUnsafe(), count: Int(row.size()))
        body(cells.span)
    }

    func finishLigaturePreparation() {
        ligature?.finishPreparation()
    }

    /// Shapes one row's ligature runs, or leaves every entry empty when the
    /// geometry published no strip slot.
    ///
    /// - Parameters:
    ///   - row: The distilled row, one entry per column.
    ///   - rowOriginXInPixels: The row's left edge, for the run pen's phase.
    ///   - cellWidthInPixels: One cell's width in device pixels.
    ///   - pass: Whether the row draws subpixel-snapped or cell-baked.
    ///   - runs: One entry per column to fill.
    func shapeLigatureRuns(
        _ row: Ubiquitty.Rendering.LigatureRowSpan,
        rowOriginXInPixels: Float,
        cellWidthInPixels: Float,
        pass: Ubiquitty.Rendering.GlyphPass,
        into runs: Ubiquitty.Rendering.LigatureRunStream
    ) {
        // One extraction at the seam's consumer: the helpers below take typed
        // buffers, and the span's borrow covers this call.
        let runs = UnsafeMutableBufferPointer(start: runs.__dataUnsafe(), count: Int(runs.size()))
        guard let ligature else {
            for index in 0..<runs.count {
                runs[index].length = 0
            }
            return
        }
        withLigatureCells(row) { cells in
            cells.withUnsafeBufferPointer { buffer in
                ligature.shapeRuns(
                    buffer,
                    rowOriginXInPixels: rowOriginXInPixels,
                    cellWidthInPixels: cellWidthInPixels,
                    pass: pass,
                    into: runs
                )
            }
        }
    }
}

extension GlyphAtlas: ProportionalStripSource {
    /// Returns the strip for a proportional run and its placement, or an
    /// absent strip when the geometry published no strip slot.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - widthCells: The cells the run occupies.
    ///   - horizontalAlign: Left, right or centred inside them.
    ///   - penResidualInPixels: The pen's fraction past its whole pixel.
    ///   - face: Regular or bold.
    ///   - weight: Variable-font weight; the UI face takes none.
    ///   - variant: The raster variant the run's foreground selects.
    ///   - tileIndex: The zero-based horizontal tile of the complete run.
    ///   - size: The run's scale, the band asked for and its doubling across.
    /// - Returns: The placement.
    func proportionalStrip(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        widthCells: Int32,
        horizontalAlign: UInt8,
        penResidualInPixels: Float,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32,
        tileIndex: Int32,
        size: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.ProportionalStripPlacement {
        guard let proportionalStrip else {
            return Ubiquitty.Rendering.ProportionalStripPlacement()
        }
        let points = UnsafeBufferPointer(start: codePoints.__dataUnsafe(), count: Int(codePoints.size()))
        return proportionalStrip.proportionalStrip(
            points,
            widthCells: Int(widthCells),
            horizontalAlign: horizontalAlign,
            penResidualInPixels: Double(penResidualInPixels),
            face: face,
            variant: variant,
            tileIndex: Int(tileIndex),
            scale: max(Int(size.scale), 1),
            band: Int(size.band),
            widthScale: size.widthScale == 2 ? 2 : 1
        )
    }

    /// The cells a proportional run needs in the proportional face, for the
    /// measurement the application asks for before it prints; zero when the
    /// atlas has no strip sheet to shape with.
    ///
    /// - Parameter codePoints: The run's text.
    /// - Returns: The cell count.
    public func proportionalRunCells(_ codePoints: UnsafeBufferPointer<UInt32>) -> Int {
        proportionalStrip?.proportionalRunCells(codePoints) ?? 0
    }

    /// Shapes a run for the model's measurer, from the ingest thread the way
    /// ``proportionalRunCells(_:)`` is.
    ///
    /// The route the builder shapes the drawn run by, face, weight and the
    /// bitmap tier's strike included: the layout Core derives a run's cells,
    /// letters and pointer positions from is the layout the frame draws, or
    /// a letter is copied from one cell and lit in another.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The face the run is set in.
    ///   - weight: The run's SGR 1:n variable weight, 0 for the face's own.
    /// - Returns: The shaped glyphs, empty when the run does not shape.
    // The one caller is the surface's measurer closure, in this package.
    // swift-only: an Array of an imported struct has no C++ thunk.
    public func shapeProportionalRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        measuringIn face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] {
        shapeProportionalRun(codePoints, face: face, weight: weight)
    }

    /// One cell's advance in the sheet's pixels, for the measurer seam.
    public var proportionalCellAdvanceInPixels: Float {
        Float(geometry.referenceAdvanceInPixels)
    }
}

extension GlyphAtlas: BoxGlyphSource {
    private static func isTerminalGraphicsFamily(_ codePoint: UInt32) -> Bool {
        (0x23B8...0x23CC).contains(codePoint)
    }

    /// Returns the atlas rect for one box glyph, rasterising on a miss.
    ///
    /// Core's routing decides the split: `prefersProcedural` keeps the area
    /// fills, shades, diagonals, and analytic Powerline separators on geometry
    /// whatever the font offers — their glyphs are inset by the bearings that
    /// make text readable — and the line family is font-first, so the font's
    /// weight and dashes survive. Absent when the face lacks the glyph, which
    /// keeps that cell on the procedural route.
    ///
    /// - Parameters:
    ///   - codePoint: The box-drawing character to resolve.
    ///   - face: Which face of the family to draw it in.
    /// - Returns: The glyph's atlas rect, or an absent one.
    func boxGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        guard !Ubiquitty.Rendering.BoxDrawing.prefersProcedural(codePoint) else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        // A bitmap family answers from its own face below, so the CoreText
        // coverage probe applies only to the CoreText route — consulting the
        // substituted face's coverage would route on a face the raster never
        // reads.
        if unifontScale <= 0, boxFaceCarrying(codePoint, face: face) == nil {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        // Weight zero, matching the raster: this atlas draws one weight per
        // configuration, and the key only has to be consistent with what the
        // slot holds — the box keyspace's bit keeps it clear of the text keys.
        let key = Ubiquitty.Rendering.boxFontKey(codePoint, 0, face)
        var isFresh = false
        let slot = cache.slotForKey(UInt64(key), &isFresh)
        guard slot >= 0 else {
            return Ubiquitty.Rendering.AtlasGlyph()
        }
        if isFresh {
            rasteriseBoxFontGlyph(codePoint, face: face, slot: slot)
        }
        // The glyph box, not the builder rect: a box cell bakes into its cell
        // quad with no subpixel shift — a rule that has to meet its
        // neighbour's cannot ride a phase — and the slot's one-texel headroom
        // must stay out of the sample or a grid of lines stops meeting.
        let uv = geometry.atlasRectForSlot(slot, Int32(slotCapacity))
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = uv.minU
        glyph.minUV.y = uv.minV
        glyph.maxUV.x = uv.maxU
        glyph.maxUV.y = uv.maxV
        glyph.present = true
        return glyph
    }

    /// Draws one box glyph from the font into a slot the cache assigned.
    ///
    /// The font raster is drawn at phase zero, moved by the family's one
    /// centring shift, then 9-slice stretched to the cell edges — the order
    /// matters, because a per-glyph recentre would move an asymmetric corner
    /// off the family's shared row and reintroduce the seam.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - face: The face to draw it in.
    ///   - slot: The slot the cache assigned.
    private func rasteriseBoxFontGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        slot: Int32
    ) {
        measureBoxCenterShiftIfNeeded()
        // The box raster rides the one source the text does in Unifont mode.
        // Drawn from CoreText instead, a scene's box strokes come from a
        // different face than the words beside them — a different weight and
        // a different row, so a dashed continuation sits rows away from the
        // solid line it continues. The shift and the 9-slice below are
        // bitmap-space transforms and operate on whatever plane the raster
        // filled.
        if unifontScale > 0 {
            rasterizer.rasteriseUnifont(codePoint, scale: unifontScale, nativeWidthInPixels: 8)
        } else {
            guard let carrier = boxFaceCarrying(codePoint, face: face) else {
                return
            }
            let routedTerminalGraphic =
                Self.isTerminalGraphicsFamily(codePoint)
                && carrier.font !== faces[face]
                && carrier.font !== router?.adoptedSymbolFallbackFace
            rasterizer.rasterise(
                glyph: carrier.glyph,
                in: carrier.font,
                at: CGPoint(
                    x: CGFloat(geometry.glyphMarginInPixels.width),
                    y: CGFloat(baselinePenInPixels)
                )
            )
            if routedTerminalGraphic {
                inkBoxForSlot[Int(slot)] = rasterizer.coverage.withUnsafeBufferPointer { plane in
                    Ubiquitty.Rendering.measureInkBox(
                        Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                        geometry.slotWidthInPixels,
                        geometry.slotHeightInPixels
                    )
                }
                rasterizer.coverage.withUnsafeBytes { bytes in
                    uploader.stage(
                        bytes.baseAddress!,
                        bytesPerRow: Int(geometry.slotWidthInPixels),
                        region: region(for: Int(slot)),
                        into: texture
                    )
                }
                return
            }
        }
        rasterizer.applyBoxFamilyTransforms(
            codePoint: codePoint,
            centerShiftY: boxCenterShiftY,
            glyphBoxLeft: geometry.glyphMarginInPixels.width,
            glyphBoxRight: geometry.glyphMarginInPixels.width + geometry.glyphWidthInPixels,
            glyphBoxTop: geometry.glyphMarginInPixels.height,
            glyphBoxBottom: geometry.slotHeightInPixels - geometry.glyphMarginInPixels.height
        )
        // A box-drawing glyph shares the mono sheet's slots too — same debt to
        // the ink table as the cluster path above.
        inkBoxForSlot[Int(slot)] = rasterizer.coverage.withUnsafeBufferPointer { plane in
            Ubiquitty.Rendering.measureInkBox(
                Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                geometry.slotWidthInPixels,
                geometry.slotHeightInPixels
            )
        }
        rasterizer.coverage.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: Int(geometry.slotWidthInPixels),
                region: region(for: Int(slot)),
                into: texture
            )
        }
    }

    /// Measures the family's centring shift from the reference U+2500.
    ///
    /// The reference is rasterised exactly as every box glyph is — phase
    /// zero, the same pen — so the measured row is the row the slots hold. A
    /// shift measured on another face or pen would move every stroke to a
    /// row nothing else agrees with.
    /// Measures the font's box strokes into Core's profile, once.
    ///
    /// Each reference is drawn by the exact pipeline the box sheet draws it
    /// with — the same source (Unifont or the face), the family's centring
    /// shift, the 9-slice stretch — because the profile must describe what
    /// reaches the screen, not what the font file holds. The cell box is
    /// cropped out of the slot plane before the fold, since Core scans the
    /// bitmap as the cell. The fold, the band policy and every consumer are
    /// Core's; this arm only draws and hands over bytes.
    private func measureBoxStrokeProfileIfNeeded() {
        guard !isBoxStrokeProfileMeasured else {
            return
        }
        isBoxStrokeProfileMeasured = true
        measureBoxCenterShiftIfNeeded()
        let planeWidth = Int(geometry.slotWidthInPixels)
        let boxLeft = Int(geometry.glyphMarginInPixels.width)
        let boxRight = boxLeft + Int(geometry.glyphWidthInPixels)
        let boxTop = Int(geometry.glyphMarginInPixels.height)
        let boxBottom = Int(geometry.slotHeightInPixels) - boxTop
        guard boxRight > boxLeft, boxBottom > boxTop else {
            return
        }
        let cellWidth = boxRight - boxLeft
        let cellHeight = boxBottom - boxTop
        var cell = [UInt8](repeating: 0, count: cellWidth * cellHeight)
        let references = Ubiquitty.Rendering.BoxDrawing.boxStrokeReferenceCodePoints()
        for index in 0..<references.size() {
            let codePoint = references[index]
            if unifontScale > 0 {
                rasterizer.rasteriseUnifont(codePoint, scale: unifontScale, nativeWidthInPixels: 8)
            } else {
                guard let carrier = boxFaceCarrying(codePoint, face: .Regular) else {
                    continue
                }
                rasterizer.rasterise(
                    glyph: carrier.glyph,
                    in: carrier.font,
                    at: CGPoint(
                        x: CGFloat(geometry.glyphMarginInPixels.width),
                        y: CGFloat(baselinePenInPixels)
                    )
                )
            }
            if ProcessInfo.processInfo.environment["UBQ_PROBE_NO_STRETCH"] == nil {
                rasterizer.applyBoxFamilyTransforms(
                    codePoint: codePoint,
                    centerShiftY: boxCenterShiftY,
                    glyphBoxLeft: geometry.glyphMarginInPixels.width,
                    glyphBoxRight: geometry.glyphMarginInPixels.width + geometry.glyphWidthInPixels,
                    glyphBoxTop: geometry.glyphMarginInPixels.height,
                    glyphBoxBottom: geometry.slotHeightInPixels - geometry.glyphMarginInPixels.height
                )
            }
            rasterizer.coverage.withUnsafeBufferPointer { plane in
                for y in 0..<cellHeight {
                    for x in 0..<cellWidth {
                        cell[y * cellWidth + x] = plane[(boxTop + y) * planeWidth + boxLeft + x]
                    }
                }
            }
            cell.withUnsafeBufferPointer { bytes in
                Ubiquitty.Rendering.BoxDrawing.foldBoxReferenceScan(
                    &boxStrokeProfile,
                    codePoint,
                    bytes.baseAddress!,
                    Int32(bytes.count),
                    Int32(cellWidth),
                    Int32(cellHeight)
                )
            }
        }
    }

    private func measureBoxCenterShiftIfNeeded() {
        guard !isBoxCenterShiftMeasured else {
            return
        }
        isBoxCenterShiftMeasured = true
        boxCenterShiftY = 0
        let planeWidth = Int(geometry.slotWidthInPixels)
        let boxLeft = Int(geometry.glyphMarginInPixels.width)
        let boxRight = boxLeft + Int(geometry.glyphWidthInPixels)
        let boxTop = Int(geometry.glyphMarginInPixels.height)
        let boxBottom = Int(geometry.slotHeightInPixels) - boxTop
        guard boxRight > boxLeft, boxBottom > boxTop else {
            return
        }
        if unifontScale > 0 {
            // The reference rides the same source the slots hold in Unifont
            // mode; measuring the CoreText face instead computes a shift for
            // a raster nothing draws.
            rasterizer.rasteriseUnifont(0x2500, scale: unifontScale, nativeWidthInPixels: 8)
        } else {
            // Through the same resolution the family draws through: a primary
            // with no box glyphs measures no shift at all otherwise, and that
            // is the very configuration whose family comes from the fallback.
            guard let reference = boxFaceCarrying(0x2500, face: Ubiquitty.Rendering.FontFace.Regular) else {
                return
            }
            rasterizer.rasterise(
                glyph: reference.glyph,
                in: reference.font,
                at: CGPoint(
                    x: CGFloat(geometry.glyphMarginInPixels.width),
                    y: CGFloat(baselinePenInPixels)
                )
            )
        }
        // The ink band over the glyph-box columns, at the oracle's threshold:
        // half coverage, so an antialiased fringe row does not widen the band
        // the centring is computed from.
        var inkTop = boxBottom
        var inkBottom = boxTop - 1
        rasterizer.coverage.withUnsafeBufferPointer { plane in
            for y in boxTop..<boxBottom {
                for x in boxLeft..<boxRight where plane[y * planeWidth + x] >= 128 {
                    inkTop = min(inkTop, y)
                    inkBottom = max(inkBottom, y)
                    break
                }
            }
        }
        guard inkBottom >= inkTop else {
            return
        }
        boxCenterShiftY = Ubiquitty.Rendering.BoxDrawing.centerShiftY(
            Int32(inkTop),
            Int32(inkBottom),
            Int32(boxTop),
            Int32(boxBottom)
        )
    }

    /// Resolves a code point to the font's glyph identifier.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve, surrogate-split as needed.
    ///   - font: The face to resolve against.
    /// - Returns: The glyph, or nil when the face lacks it.
    /// The face that draws a box code point, and its glyph in that face.
    ///
    /// The atlas's own faces and the router's symbol face, handed to the
    /// ladder that decides between them.
    ///
    /// - Parameters:
    ///   - codePoint: The box-drawing character to draw.
    ///   - face: Which face of the primary family the cell asked for.
    /// - Returns: The face and glyph, or nil when neither carries it.
    private func boxFaceCarrying(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace
    ) -> (font: CTFont, glyph: CGGlyph)? {
        if let carrier = BoxFaceLadder.faceCarrying(
            codePoint,
            primary: faces[face],
            symbolFallback: router?.adoptedSymbolFallbackFace
        ) {
            return carrier
        }
        guard Self.isTerminalGraphicsFamily(codePoint),
            let routed = router?.routedFont(for: codePoint, face: face, variableWeight: 0, wantsEmoji: false),
            let glyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: routed)
        else {
            return nil
        }
        return (routed, glyph)
    }

    static func glyphIdentifier(for codePoint: UInt32, in font: CTFont) -> CGGlyph? {
        let count = codePoint <= 0xFFFF ? 1 : 2
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: count) { characters in
            if codePoint <= 0xFFFF {
                characters[0] = UInt16(codePoint)
            } else {
                let value = codePoint - 0x10000
                characters[0] = UInt16(0xD800 + (value >> 10))
                characters[1] = UInt16(0xDC00 + (value & 0x3FF))
            }
            return withUnsafeTemporaryAllocation(of: CGGlyph.self, capacity: count) { glyphs in
                glyphs.initialize(repeating: 0)
                guard CTFontGetGlyphsForCharacters(font, characters.baseAddress!, glyphs.baseAddress!, count),
                    glyphs[0] != 0
                else {
                    return nil
                }
                return glyphs[0]
            }
        }
    }
}

/// Fill census under UBIQUITTY_PERFLOG.
///
/// More fills, costlier fills and a different resolved face cannot be told
/// apart from outside the process. Each distinct face prints once; each
/// lane prints a cumulative line every 512 fills.
enum FillCensus {
    static let enabled = getenv("UBIQUITTY_PERFLOG") != nil
    /// Guards the three tallies below.
    ///
    /// The whole of ``note(lane:font:spent:)`` runs inside it, so a face line
    /// cannot interleave with a lane line. The gate at each call site reads
    /// ``enabled``, which is immutable and takes no lock.
    private static let censusLock = NSLock()
    /// Fills per lane, guarded by ``censusLock``.
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    /// Nanoseconds spent per lane, guarded by ``censusLock``.
    nonisolated(unsafe) private static var nanos: [String: UInt64] = [:]
    /// The faces already reported, guarded by ``censusLock``.
    nonisolated(unsafe) private static var faces = Set<String>()

    static func note(lane: String, font: CTFont?, spent: UInt64) {
        censusLock.withLock {
            counts[lane, default: 0] += 1
            nanos[lane, default: 0] += spent
            if let font {
                let face = CTFontCopyPostScriptName(font) as String
                if faces.insert(face).inserted {
                    fputs("[perf] fill arm=swift face=\(face)\n", stderr)
                }
            }
            let n = counts[lane, default: 0]
            if n % 512 == 0 {
                fputs("[perf] fill arm=swift lane=\(lane) n=\(n) ms=\(nanos[lane, default: 0] / 1_000_000)\n", stderr)
            }
        }
    }
}
