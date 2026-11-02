// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// LigatureSheet.swift — the strip sheet shaped ligature runs live on.
//
// A strip holds a whole shaped run — `=>` fused into one image — and every
// covered cell draws the slice of it its own column occupies, so a colour
// boundary inside the run recolours without moving a glyph. The slot is cut to
// Core's published geometry (`ligatureSlotWidthInPixels`), the run walk is
// Core's `identifyLigatureRuns`, and the inked extent is Core's rule too: what
// stays here is CoreText — shaping the run with its context, measuring the
// context's caret offset, and drawing coverage.
//
// The features that make the font ligate are not decided here either.
// `LigatureFeatureClassifier` probes which feature tags the face answers to and
// serialises the result in Core's font-feature grammar; this sheet parses that
// spelling back with Core's parser and applies it. One probe, one grammar.

import CoreText
import Metal
import UbiquittyCore

/// The R8 strip sheet and Core's slot cache over it.
///
/// Not thread-safe: the context, its plane and the key scratch are reused
/// strip to strip, which is what keeps a steady-state frame free of
/// allocation.
package final class LigatureSheet {
    /// The sheet the ligature pass samples.
    let texture: MTLTexture
    /// Where a rasterised slot waits for the GPU to copy it into the sheet.
    ///
    /// A `MTLTexture.replace` is a CPU write ordered against nothing: the frame
    /// still sampling this sheet is not finished with the slot being rewritten,
    /// and a run then reads the new occupant's ink under its own coordinates.
    /// Staging the bytes and copying them with a blit on the queue that draws
    /// puts the write on the GPU's timeline, where the queue's own ordering
    /// keeps it behind the frames that read the slot before it.
    /// The staged path to this sheet; see ``AtlasUploader``.
    ///
    /// Shared with every other sheet of the atlas so one flush carries them
    /// all: the ordering the copies need is the queue's, not each sheet's.
    private let uploader: AtlasUploader

    /// Strips per texture row, after the device-limit clamp.
    let columns: Int

    /// Rows of strips in the sheet, after the same clamp.
    let rows: Int

    /// One strip slot's width in pixels — Core's published derivation.
    let slotWidthInPixels: Int

    /// One strip slot's height in pixels — the mono slot's.
    let slotHeightInPixels: Int

    /// Core's hash-and-LRU over the strips, content-verified: the key is a
    /// fold of a variable-length run, so a hit memcmps the stored run before
    /// serving pixels.
    let cache: Ubiquitty.Rendering.GlyphSlotCache

    /// The user toggle, read per row. The sheet exists whenever the geometry
    /// does, so flipping the setting keeps every cached strip warm.
    var isEnabled = true

    var canPrepareLigatures: Bool { isEnabled && doesLigate }

    private let context: CGContext
    /// One glyph at a time, before it joins the slot by maximum (see
    /// ``drawGlyphsJoined``).
    private let glyphScratch: CGContext
    /// The fill gray the slot is being drawn at, which the scratch draws at too.
    private var stripFillGray: CGFloat = 1.0
    /// The pen grid the owning atlas keys, the one CoreText quantises onto at
    /// this size; the strip's phase is chosen and drawn on the same grid.
    private let subpixelPhaseCount: Int
    private let regularFont: CTFont
    private let boldFont: CTFont
    private var regularCandidateFilter: ShapingCandidateFilter?
    private var boldCandidateFilter: ShapingCandidateFilter?
    private let verifiesCandidateFilter = ProcessInfo.processInfo.environment["UBIQUITTY_SHAPING_FILTER_VERIFY"] == "1"
    private var verifiedCandidateRuns = 0
    private var mismatchedCandidateRuns = 0
    #if canImport(HarfBuzzProbe)
    private var uniformRegularShaper: UniformFaceShaper?
    private var uniformBoldShaper: UniformFaceShaper?
    private let verifiesUniformShaping = ProcessInfo.processInfo.environment["UBIQUITTY_HARFBUZZ_VERIFY"] == "1"
    private var verifiedUniformRuns = 0
    private var mismatchedUniformRuns = 0
    #endif
    private struct GroupGlyph {
        let glyph: CGGlyph
        let font: CTFont
        let face: UInt32
        let source: Int
        let position: CGPoint
        let ink: CGRect
    }
    private struct RasterGroup {
        let firstCell: Int
        let cellCount: Int
        let glyphs: [GroupGlyph]
        let rasterKey: [UInt32]
    }
    /// Jobs are immutable; results cross to the caller only after all workers finish.
    private final class ShapeBatch: @unchecked Sendable {
        let jobs: [(Int, NSAttributedString)]
        private let lock = NSLock()
        private var lines: [Int: CTLine] = [:]

        init(jobs: [(Int, NSAttributedString)]) { self.jobs = jobs }

        func perform() -> [Int: CTLine] {
            let workerCount = min(4, jobs.count)
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                autoreleasepool {
                    var completed: [(Int, CTLine)] = []
                    for index in stride(from: worker, to: self.jobs.count, by: workerCount) {
                        let job = self.jobs[index]
                        completed.append((job.0, CTLineCreateWithAttributedString(job.1)))
                    }
                    self.lock.lock()
                    for (index, line) in completed { self.lines[index] = line }
                    self.lock.unlock()
                }
            }
            return lines
        }
    }
    private var pendingShapeJobs: [(Int, NSAttributedString)] = []
    private var pendingShapeKeys: [[UInt32]] = []
    private var pendingShapeSet: Set<[UInt32]> = []
    private var preparedFrameLines: [[UInt32]: CTLine] = [:]
    private var preparedGroups: [[UInt32]: [RasterGroup]] = [:]
    private var preparedGroupKeys: [[UInt32]] = []
    private var nextPreparedGroupKey = 0
    /// The proportional faces a proportional run shapes in
    /// (Docs/proportional-text.md): the platform's UI face at the grid face's
    /// device size, regular and bold. Built with the sheet rather than on first
    /// use: a measurement arrives on the reader thread while the render thread
    /// draws, and two faces that are never swapped need no lock.
    private let proportionalRegularFont: CTFont
    /// The em size the proportional face draws at, in points.
    package var proportionalPointSizeForTesting: Double { CTFontGetSize(proportionalRegularFont) }
    private let proportionalBoldFont: CTFont
    private let proportionalItalicFont: CTFont
    private let proportionalBoldItalicFont: CTFont
    /// Whether the face shapes any ligature at all — the classifier's probe
    /// verdict. False leaves every row unshaped without consulting CoreText.
    private let doesLigate: Bool
    /// The strip font's healing-probe verdict: which stretches the row walk
    /// shapes. Probed here because this object owns the font strips draw
    /// with; the frontend copies it into the slot geometry so the builder's
    /// prescan reads the same answer.
    let participation: Ubiquitty.Rendering.LigatureParticipation
    private let penXInPixels: Double
    /// The strip's top from the row's top: the vertical margin and, in the
    /// bitmap tier, Core's strike overhang above the cell, negated; every
    /// placement carries it so the builder draws the strip's own slot.
    private let stripTopInPixels: Double
    private let penYInPixels: Double
    private let cellAdvanceInPixels: Double
    /// The bitmap family's upscale, or zero for a face CoreText rasterises.
    ///
    /// Non-zero, a proportional run is shaped and drawn by Core's own strike
    /// (Docs/proportional-text.md) into this sheet's slots, so the bitmap
    /// tier draws the reference's bytes here as it does for every grid glyph;
    /// CoreText's proportional face answers only the native tier.
    private let unifontScale: Int
    /// One slot of coverage for a strip Core draws, reused per strip.
    private var unifontStripScratch: [UInt8] = []
    /// Key-and-verify scratch: the run's characters, then the split — the
    /// context length and the drawn length — then which characters are bold.
    /// Two identical buffers split differently are two different strips, and
    /// so are two identical buffers drawn through different faces; the key
    /// hash alone cannot say either, so the contents carry both.
    /// What the shaper answered, kept between frames and keyed by the segment
    /// rather than by a slot.
    ///
    /// A slot is the wrong home for it: a run that draws entirely from glyph
    /// identities needs no slot, and holding its answers in one would keep the
    /// sheet's key space exactly as crowded as it was while the pixels went
    /// unused. Core's cache holds no pixels, so its key may be the text; the
    /// atlas holds pixels, so its key is the identity.
    private var answerCache = Ubiquitty.Rendering.ShapedCellCache()
    /// The number of native shaping calls performed during this frame.
    private(set) var shapedLinesThisFrame = 0
    /// The segments held by the two active frames, excluding the bounded warm cache.
    var retainedShapingSegments: Int { answerCache.retainedSegments() }

    /// The perf tallies this sheet counts into; see ``StripCensus``.
    private var census = StripCensus()
    private var keyScratch: [UInt32]
    private var proportionalVerification = Ubiquitty.Rendering.ProportionalStripVerification()
    private var proportionalSourceOffsets = Ubiquitty.Rendering.ProportionalSourceOffsets()
    private var candidateScratch: [Ubiquitty.Rendering.LigatureRunCandidate]
    /// The two possible attribute sets, built once: only the font varies
    /// between strips, so a per-strip dictionary is pure allocation churn.
    private let regularAttributes: [NSAttributedString.Key: Any]
    private let boldAttributes: [NSAttributedString.Key: Any]

    /// How many strips the sheet holds, after the clamp.
    var slotCapacity: Int { columns * rows }

    /// Builds a strip sheet over one family's ligature-enabled faces.
    ///
    /// - Parameters:
    ///   - device: The device the sheet allocates on.
    ///   - faces: The family's faces; regular and bold gain the features.
    ///   - slotWidthInPixels: Core's published strip slot width.
    ///   - slotHeightInPixels: Core's published strip slot height.
    ///   - marginXInPixels: The horizontal glyph margin, the pen's rest x.
    ///   - baselinePenInPixels: The pen baseline above the slot bottom.
    ///   - cellAdvanceInPixels: The font's advance, for the inked extent.
    ///   - worstCaseCellsOnScreen: The cell count the mono sheet was cut for,
    ///     which bounds the strips one frame can demand.
    ///   - featureSpec: The probed ligature features, in Core's grammar.
    ///   - doesLigate: The probe's verdict on whether the face ligates at all.
    ///   - maxTextureDimension: The API's largest 2D texture edge.
    ///   - proportionalFamilyName: The family proportional runs are set in,
    ///     or empty for the platform's UI face.
    ///   - proportionalPointSize: The em size proportional runs are set at,
    ///     or zero for one optical step over the grid's.
    init?(
        device: MTLDevice,
        uploader: AtlasUploader,
        faces: FontFaces,
        slotWidthInPixels: Int,
        slotHeightInPixels: Int,
        marginXInPixels: Double,
        baselinePenInPixels: Double,
        cellAdvanceInPixels: Double,
        worstCaseCellsOnScreen: Int = 0,
        featureSpec: String,
        doesLigate: Bool,
        subpixelPhaseCount: Int = Int(Ubiquitty.Rendering.subpixelPhaseCount),
        maxTextureDimension: Int,
        unifontScale: Int = 0,
        marginYInPixels: Double = 0,
        proportionalFamilyName: String = "",
        proportionalPointSize: Double = 0
    ) {
        self.subpixelPhaseCount = subpixelPhaseCount
        self.unifontScale = unifontScale
        self.stripTopInPixels =
            -(marginYInPixels
            + (unifontScale > 0
                ? Double(Ubiquitty.Rendering.unifontProportionalStripOverhangInPixels(Int32(unifontScale)))
                : 0))
        let worstCaseStrips = Ubiquitty.Rendering.worstCaseLigatureStripsForCells(
            Int32(worstCaseCellsOnScreen)
        )
        guard slotWidthInPixels > 0, slotHeightInPixels > 0 else {
            return nil
        }
        // The strip fonts come first because the grid is sized by their probe:
        // a healing face shapes prose and needs Core's larger nominal, an
        // operator face keeps the economy.
        let features = LigatureSheet.featureSettings(fromSpec: featureSpec)
        let probedRegular = LigatureSheet.applying(features, to: faces[Ubiquitty.Rendering.FontFace.Regular])
        let participation = LigatureSheet.probeParticipation(font: probedRegular)
        if ProcessInfo.processInfo.environment["UBQ_SHEETLOG"] != nil {
            NSLog(
                "UBQ_SHEETLOG participation=%@ face=%@ spec=%@ ligates=%@",
                participation == .AllEligibleRuns ? "healing" : "operator",
                CTFontCopyFamilyName(probedRegular) as String,
                featureSpec,
                doesLigate ? "1" : "0"
            )
        }
        // Core's nominal grid under the device's clamp — the same derivation
        // the portable sheet runs, so the two arms cannot carry different
        // capacities for one screen.
        let fit = Ubiquitty.Rendering.clampAtlasGridToTextureLimit(
            Ubiquitty.Rendering.ligatureStripNominalGrid(
                participation,
                worstCaseStrips,
                Ubiquitty.IntSize(width: Int32(slotWidthInPixels), height: Int32(slotHeightInPixels))
            ),
            Ubiquitty.IntSize(width: Int32(slotWidthInPixels), height: Int32(slotHeightInPixels)),
            Int32(maxTextureDimension)
        )
        guard fit.valid, fit.columns > 0, fit.rows > 0 else {
            return nil
        }
        let columns = Int(fit.columns)
        let rows = Int(fit.rows)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: columns * slotWidthInPixels,
            height: rows * slotHeightInPixels,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        guard let texture = device.makeTexture(descriptor: descriptor),
            let cache = Ubiquitty.Rendering.makeGlyphSlotCache(
                Int32(columns * rows),
                Ubiquitty.Rendering.recommendedHashBuckets(Int32(columns * rows)),
                Int32(columns)
            ),
            let context = CGContext(
                data: nil,
                width: slotWidthInPixels,
                height: slotHeightInPixels,
                bitsPerComponent: 8,
                bytesPerRow: slotWidthInPixels,
                space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ),
            let glyphScratch = CGContext(
                data: nil,
                width: slotWidthInPixels,
                height: slotHeightInPixels,
                bitsPerComponent: 8,
                bytesPerRow: slotWidthInPixels,
                space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        else {
            return nil
        }
        // Alpha-only, like the single-glyph plane (GlyphRasterizer): the fill
        // gray steers CoreText's smoothing tier and the alpha that comes back
        // is that tier's coverage. Foreground-from-context is what lets the
        // strip's attributes take the fill from here. Smoothing is left at the
        // context default so the user's AppleFontSmoothing preference reaches
        // the strips as it reaches every AppKit view.
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.setShouldAntialias(true)
        glyphScratch.setShouldAntialias(true)
        self.glyphScratch = glyphScratch
        self.texture = texture
        self.uploader = uploader
        // Sixty-four slots is the flush granularity, not a budget: a build that
        // rasterises more issues its copies in batches, and the queue orders
        // every batch behind the frames already reading the sheet.
        self.columns = columns
        self.rows = rows
        self.slotWidthInPixels = slotWidthInPixels
        self.slotHeightInPixels = slotHeightInPixels
        self.cache = cache
        // Core's owned-ink ledger rides the shared cache, so the builder can
        // cut strips by ownership; the policy lives with the slots, and this
        // arm only feeds it measurements.
        cache.enableOwnedInkRecords(Ubiquitty.Rendering.stripSlotCells, Int32(slotWidthInPixels))
        self.context = context
        self.doesLigate = doesLigate
        self.penXInPixels = marginXInPixels
        self.penYInPixels = baselinePenInPixels
        self.cellAdvanceInPixels = cellAdvanceInPixels
        self.participation = participation
        self.regularFont = probedRegular
        let proportional = LigatureSheet.ProportionalFaceRequest(
            familyName: proportionalFamilyName,
            pointSize: proportionalPointSize
        )
        self.proportionalRegularFont = LigatureSheet.proportionalFace(
            sizedLike: faces,
            request: proportional,
            isBold: false,
            isItalic: false
        )
        self.proportionalBoldFont = LigatureSheet.proportionalFace(sizedLike: faces, request: proportional, isBold: true, isItalic: false)
        self.proportionalItalicFont = LigatureSheet.proportionalFace(sizedLike: faces, request: proportional, isBold: false, isItalic: true)
        self.proportionalBoldItalicFont = LigatureSheet.proportionalFace(
            sizedLike: faces,
            request: proportional,
            isBold: true,
            isItalic: true
        )
        self.boldFont = LigatureSheet.applying(features, to: faces[Ubiquitty.Rendering.FontFace.Bold])
        // Foreground-from-context makes CTLineDraw fill with the context's
        // white instead of its default black — without it the strip
        // rasterises black and uploads zero coverage.
        self.regularAttributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): self.regularFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        self.boldAttributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): self.boldFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let ligatureScratch = Int(Ubiquitty.Rendering.ligatureMaxCells) + 2 * Int(Ubiquitty.Rendering.ligatureContextCells)
        // The characters, then the split — context length and drawn length —
        // then the run's face pattern. All three ride the verified contents,
        // because two runs can carry one text and still be different images.
        self.keyScratch = [UInt32](
            repeating: 0,
            count: ligatureScratch + 4
        )
        self.candidateScratch = [Ubiquitty.Rendering.LigatureRunCandidate](
            repeating: Ubiquitty.Rendering.LigatureRunCandidate(),
            count: 1
        )
        if ProcessInfo.processInfo.environment["UBIQUITTY_SHAPING_FILTER"] != "0" {
            regularCandidateFilter = ShapingCandidateFilter(font: regularFont)
            boldCandidateFilter = ShapingCandidateFilter(font: boldFont)
        }
        #if canImport(HarfBuzzProbe)
        if ProcessInfo.processInfo.environment["UBIQUITTY_HARFBUZZ_IDENTITIES"] == "1" {
            uniformRegularShaper = UniformFaceShaper(font: regularFont, featureSpecification: featureSpec)
            uniformBoldShaper = UniformFaceShaper(font: boldFont, featureSpecification: featureSpec)
        }
        #endif
    }

    /// Opens a frame, after which touched strips survive eviction within it.
    func beginFrame() {
        pendingShapeJobs.removeAll(keepingCapacity: true)
        pendingShapeKeys.removeAll(keepingCapacity: true)
        pendingShapeSet.removeAll(keepingCapacity: true)
        preparedFrameLines.removeAll(keepingCapacity: true)
        if StripCensus.isEnabled {
            census.noteFrame(
                capacity: Int(cache.capacity()),
                pinned: Int(cache.pinnedSlots()),
                saturations: Int(cache.saturationsThisFrame()),
                staged: uploader.stagedCount,
                flushed: uploader.flushedCount,
                unordered: uploader.unorderedCount
            )
        }
        cache.beginFrame()
        answerCache.endFrame()
        shapedLinesThisFrame = 0
    }

    /// Shapes one row's ligature runs into the seam's per-column form.
    ///
    /// Core's walk decides which cells join a run; this resolves each
    /// candidate to a strip — probing the cache with the run, its context and
    /// its split, rasterising on a miss — and marks the covered columns. A
    /// full sheet declines the run, and those cells fall back to per-glyph
    /// drawing for the frame.
    ///
    /// - Parameters:
    ///   - row: The distilled row, one entry per column.
    ///   - rowOriginXInPixels: The row's left edge, for the run pen's phase.
    ///   - cellWidthInPixels: One cell's width in device pixels.
    ///   - pass: Whether the row draws subpixel-snapped or cell-baked.
    ///   - runs: One entry per column to fill; untouched entries stay empty.
    /// Strip census under UBIQUITTY_PERFLOG, the ligature lane's FillCensus.
    ///
    /// Separates the causes of rasteriser time that cannot be told apart from
    /// outside the process — first-time content, eviction of strips already
    /// served once, or per-call cost: `firstSeen` counts keys this cache never
    /// probed before, `repeatMiss` counts keys it already served fresh once.
    ///
    /// Two scopes meet in one census: the per-frame counters belong to the
    /// sheet that holds it, and ``LifetimeTallies`` — the tallies whose scope
    /// is the process — folds into ``sharedLifetimeTallies`` under
    /// ``lifetimeTalliesLock`` once per frame, so the sheets a configuration
    /// change mints count into one set of totals.
    struct StripCensus {
        static let isEnabled = getenv("UBIQUITTY_PERFLOG") != nil

        /// The tallies whose scope is the process rather than one frame.
        ///
        /// A configuration change — another point size, another backing scale —
        /// mints a second atlas and a second sheet over the same font, and what
        /// these count is the process's history, so every sheet folds its own
        /// copy into one shared set.
        private struct LifetimeTallies {
            /// Frames opened.
            var frames = 0
            /// Lookups made.
            var probes = 0
            /// Lookups a slot the sheet already held answered.
            var hits = 0
            /// Keys the cache had never probed before.
            var firstSeen = 0
            /// Keys it had already served fresh once.
            var repeatMiss = 0
            /// Lookups the sheet could seat nowhere.
            ///
            /// Counted apart from a hit, which is what a refusal looked like
            /// from here: the cache reports `isFresh == false` for both, so a
            /// sheet under enough pressure to leave rows unshaped read as one
            /// with a perfect hit rate.
            var refusals = 0
            /// Nanoseconds spent drawing strips.
            var rasteriseNanoseconds: UInt64 = 0
            /// Every key probed, whose count is the key space reached so far.
            var seenKeys = Set<UInt32>()
            /// The worst frame since launch, which is the one a viewer sees flip.
            var worstRefusalsInAFrame = 0
            /// Runs asked of the answer cache, and the runs it answered.
            var answerProbes = 0
            var answerHits = 0
            /// Misses whose segment this process had shaped before: the share
            /// an answer that outlived its frame would have served.
            var answerMissesSeenBefore = 0
            /// Every segment asked, folded to a word.
            var answerSeenSegments = Set<UInt64>()

            /// Folds one sheet's contribution into these tallies.
            ///
            /// - Parameters:
            ///   - counted: What that sheet has counted so far.
            ///   - carried: What it had already contributed, which makes each
            ///     scalar's difference the part not yet folded in. Both
            ///     operands are monotone per sheet, so no difference is
            ///     negative.
            mutating func absorb(_ counted: LifetimeTallies, since carried: LifetimeTallies) {
                frames += counted.frames - carried.frames
                probes += counted.probes - carried.probes
                hits += counted.hits - carried.hits
                firstSeen += counted.firstSeen - carried.firstSeen
                repeatMiss += counted.repeatMiss - carried.repeatMiss
                refusals += counted.refusals - carried.refusals
                rasteriseNanoseconds += counted.rasteriseNanoseconds - carried.rasteriseNanoseconds
                worstRefusalsInAFrame = max(worstRefusalsInAFrame, counted.worstRefusalsInAFrame)
                seenKeys.formUnion(counted.seenKeys)
                answerProbes += counted.answerProbes - carried.answerProbes
                answerHits += counted.answerHits - carried.answerHits
                answerMissesSeenBefore += counted.answerMissesSeenBefore - carried.answerMissesSeenBefore
                answerSeenSegments.formUnion(counted.answerSeenSegments)
            }
        }

        /// Guards ``sharedLifetimeTallies``.
        ///
        /// Taken in ``carryLifetimeTallies()`` alone, once per frame under the
        /// ``isEnabled`` gate; nothing on the candidate or the column path
        /// reaches it.
        private static let lifetimeTalliesLock = NSLock()

        /// The tallies every sheet folds into, guarded by
        /// ``lifetimeTalliesLock``.
        nonisolated(unsafe) private static var sharedLifetimeTallies = LifetimeTallies()

        /// This sheet's copy of them: what its notes count into, and what its
        /// printed lines read.
        private var lifetimeTallies = LifetimeTallies()

        /// What this sheet last handed to ``sharedLifetimeTallies``, the
        /// baseline the next fold subtracts.
        private var carriedLifetimeTallies = LifetimeTallies()

        /// Strips this frame asked for, and what happened to them.
        private var probesThisFrame = 0
        private var refusalsThisFrame = 0
        private var freshThisFrame = 0
        /// Runs Core offered that ended this frame with no strip at all.
        ///
        /// The refusal counters answer "was the cache full"; this answers the
        /// question a viewer asks, which is how many runs drew the per-cell
        /// unhealed path. They differ whenever a run reaches no slot for a
        /// reason other than pressure — a font that substituted nothing, a
        /// seam that fell elsewhere, an eligibility gate that flipped — and a
        /// flip with both refusal counts at zero is exactly that case.
        private var unstrippedThisFrame = 0
        /// Columns whose shaped answer was published this frame, and columns
        /// that could not carry one. The pair is what says whether a bounded
        /// key space is reachable for this workload at all: answers are the
        /// population that can key by identity, and refusals are the runs whose
        /// shaper reached another family, where an id would name a different
        /// glyph.
        private var shapedThisFrame = 0
        private var unshapedThisFrame = 0
        private var candidatesThisFrame = 0

        /// Makes a census with every tally at zero.
        init() {}

        /// Folds this sheet's contribution into the process-scoped tallies and
        /// takes the totals back.
        ///
        /// Reached from ``noteFrame(capacity:pinned:saturations:staged:flushed:unordered:)``
        /// ahead of the frame line, so that line carries what every sheet has
        /// counted, and a sheet a configuration change mints resumes the frame
        /// number, the 512-probe phase, the key set and the worst frame of the
        /// sheet it replaces.
        private mutating func carryLifetimeTallies() {
            StripCensus.lifetimeTalliesLock.withLock {
                StripCensus.sharedLifetimeTallies.absorb(lifetimeTallies, since: carriedLifetimeTallies)
                lifetimeTallies = StripCensus.sharedLifetimeTallies
            }
            carriedLifetimeTallies = lifetimeTallies
        }

        /// Counts a run Core's walk offered this frame.
        mutating func noteCandidate() {
            candidatesThisFrame += 1
        }

        /// Counts a run this frame left with no strip.
        mutating func noteUnstripped() {
            unstrippedThisFrame += 1
        }

        /// Counts a column that published a shaped answer.
        mutating func noteShaped() {
            shapedThisFrame += 1
        }

        /// Counts a column a strip covers that carries no shaped answer.
        mutating func noteUnshaped() {
            unshapedThisFrame += 1
        }

        /// Counts a lookup the sheet could seat nowhere.
        mutating func noteRefusal() {
            lifetimeTallies.refusals += 1
            refusalsThisFrame += 1
        }

        /// Counts one run's question to the answer cache and what came back.
        ///
        /// The segment is folded to a word so a miss can be told apart by
        /// whether this process has shaped it before: that share is what a
        /// cache outliving the frame recovers, and nothing else is.
        ///
        /// - Parameters:
        ///   - keyScratch: The segment's words, code points then context and mask.
        ///   - count: How many of them the key spans.
        ///   - isHit: Whether the cache answered.
        mutating func noteAnswer(keyScratch: [UInt32], count: Int, isHit: Bool) {
            lifetimeTallies.answerProbes += 1
            var hash: UInt64 = 1_469_598_103_934_665_603
            for word in keyScratch[..<count] {
                hash ^= UInt64(word)
                hash = hash &* 1_099_511_628_211
            }
            let isNew = lifetimeTallies.answerSeenSegments.insert(hash).inserted
            if isHit {
                lifetimeTallies.answerHits += 1
            } else if !isNew {
                lifetimeTallies.answerMissesSeenBefore += 1
            }
        }

        /// Closes the frame's tally and prints it.
        ///
        /// Per frame rather than per 512 probes: a refusal is what makes a run
        /// draw unhealed, so the count that matters is how many landed in one
        /// frame — a rate spread over frames cannot tell a steady drizzle from
        /// the burst that flips a screenful of letterforms at once.
        ///
        /// - Parameters:
        ///   - capacity: The sheet's slots.
        ///   - pinned: Slots a retained frame holds and no eviction can take.
        ///   - saturations: Lookups this frame that found every candidate slot
        ///     already taken by it.
        ///   - staged: Slots the sheet's uploader has copied into a staging
        ///     buffer.
        ///   - flushed: Slots it has copied onward by a blit on the drawing
        ///     queue.
        ///   - unordered: Slots it wrote straight to a texture, unordered.
        mutating func noteFrame(
            capacity: Int,
            pinned: Int,
            saturations: Int,
            staged: Int,
            flushed: Int,
            unordered: Int
        ) {
            lifetimeTallies.frames += 1
            if refusalsThisFrame > lifetimeTallies.worstRefusalsInAFrame {
                lifetimeTallies.worstRefusalsInAFrame = refusalsThisFrame
            }
            carryLifetimeTallies()
            if probesThisFrame > 0 {
                fputs(
                    "[perf] ligature-frame arm=swift frame=\(lifetimeTallies.frames) candidates=\(candidatesThisFrame) unstripped=\(unstrippedThisFrame) shaped=\(shapedThisFrame) unshaped=\(unshapedThisFrame) probes=\(probesThisFrame) fresh=\(freshThisFrame) refused=\(refusalsThisFrame) saturated=\(saturations) worstRefused=\(lifetimeTallies.worstRefusalsInAFrame) distinctKeys=\(lifetimeTallies.seenKeys.count) capacity=\(capacity) pinned=\(pinned) staged=\(staged) blitted=\(flushed) unordered=\(unordered) answers=\(lifetimeTallies.answerProbes) answerHits=\(lifetimeTallies.answerHits) answerMissSeen=\(lifetimeTallies.answerMissesSeenBefore) answerSegments=\(lifetimeTallies.answerSeenSegments.count)\n",
                    stderr
                )
            }
            probesThisFrame = 0
            refusalsThisFrame = 0
            freshThisFrame = 0
            unstrippedThisFrame = 0
            shapedThisFrame = 0
            unshapedThisFrame = 0
            candidatesThisFrame = 0
        }

        /// Counts one lookup and what the cache answered.
        ///
        /// - Parameters:
        ///   - key: The strip key probed; zero for a run answered by identity.
        ///   - isFresh: Whether the slot came back needing a rasterise.
        mutating func noteProbe(key: UInt32, isFresh: Bool) {
            lifetimeTallies.probes += 1
            probesThisFrame += 1
            if isFresh {
                freshThisFrame += 1
                if lifetimeTallies.seenKeys.insert(key).inserted {
                    lifetimeTallies.firstSeen += 1
                } else {
                    lifetimeTallies.repeatMiss += 1
                }
            } else {
                lifetimeTallies.hits += 1
            }
            if lifetimeTallies.probes % 512 == 0 {
                fputs(
                    "[perf] ligature arm=swift probes=\(lifetimeTallies.probes) hits=\(lifetimeTallies.hits) firstSeen=\(lifetimeTallies.firstSeen) repeatMiss=\(lifetimeTallies.repeatMiss) refusals=\(lifetimeTallies.refusals) rasteriseMs=\(lifetimeTallies.rasteriseNanoseconds / 1_000_000)\n",
                    stderr
                )
            }
        }

        /// Adds what one strip's rasterise cost.
        ///
        /// - Parameter spent: The nanoseconds the draw took.
        mutating func noteRasterise(spent: UInt64) {
            lifetimeTallies.rasteriseNanoseconds += spent
        }
    }

    private func shapingKey(
        _ candidate: Ubiquitty.Rendering.LigatureRunCandidate,
        row: Span<Ubiquitty.Rendering.LigatureCell>
    ) -> [UInt32] {
        let leftSpace = Ubiquitty.Rendering.ligatureRunFlanksRowStart(candidate)
        let rightSpace = Ubiquitty.Rendering.ligatureRunFlanksRowEnd(candidate, Int32(row.count))
        var key: [UInt32] = []
        key.reserveCapacity(Int(candidate.leftContext + candidate.length + candidate.rightContext) + 5)
        if leftSpace { key.append(0x20) }
        var faceMask: UInt32 = 0
        for offset in 0..<Int(candidate.leftContext + candidate.length + candidate.rightContext) {
            let cell = row[Int(candidate.startColumn - candidate.leftContext) + offset]
            if key.count < 32, (cell.shape & Ubiquitty.Rendering.ligatureShapeBold) != 0 {
                faceMask |= 1 << UInt32(key.count)
            }
            key.append(cell.codePoint)
        }
        if rightSpace { key.append(0x20) }
        key.append(UInt32(candidate.leftContext) + (leftSpace ? 1 : 0))
        key.append(UInt32(candidate.length))
        key.append(faceMask)
        return key
    }

    func prepareRow(_ row: Span<Ubiquitty.Rendering.LigatureCell>, pitch: Float) {
        guard isEnabled, doesLigate, !row.isEmpty else { return }
        let capacity = row.count / 2 + 1
        if candidateScratch.count < capacity {
            candidateScratch = Array(repeating: .init(), count: capacity)
        }
        let count = row.withUnsafeBufferPointer { source in
            candidateScratch.withUnsafeMutableBufferPointer { buffer in
                Int(
                    Ubiquitty.Rendering.identifyLigatureRuns(
                        source.baseAddress,
                        Int32(row.count),
                        participation,
                        .ShapesMixedFaces,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                )
            }
        }
        for index in 0..<count {
            let key = shapingKey(candidateScratch[index], row: row)
            let preparationKey = key + [pitch.bitPattern]
            if let groups = preparedGroups[preparationKey], !groups.isEmpty { continue }
            if pendingShapeSet.contains(preparationKey) { continue }
            let hasAnswer = key.withUnsafeBufferPointer { buffer in
                let segment = Ubiquitty.Rendering.ShapedSegmentSpan(buffer)
                return !answerCache.lookup(segment, 0).isEmpty || answerCache.holdsNoAnswer(segment, 0)
            }
            if hasAnswer { continue }
            if prepareUnchangedIdentities(key) { continue }
            #if canImport(HarfBuzzProbe)
            if prepareUniformIdentities(key) { continue }
            #endif
            pendingShapeSet.insert(preparationKey)
            pendingShapeJobs.append(
                (
                    pendingShapeKeys.count,
                    attributedRun(codePoints: key, characterCount: key.count - 3, faceMask: key[key.count - 1])
                )
            )
            pendingShapeKeys.append(preparationKey)
        }
    }

    private func prepareUnchangedIdentities(_ key: [UInt32]) -> Bool {
        let characterCount = key.count - 3
        let faceMask = key[key.count - 1]
        let candidateFilter: ShapingCandidateFilter?
        if faceMask == 0 {
            candidateFilter = regularCandidateFilter
        } else if characterCount <= 32,
            faceMask == UInt32.max >> UInt32(32 - characterCount)
        {
            candidateFilter = boldCandidateFilter
        } else {
            return false
        }
        let leftContext = Int(key[characterCount])
        let drawnCells = Int(key[characterCount + 1])
        guard
            let answers = candidateFilter?
                .identities(
                    codePoints: key,
                    characterCount: characterCount,
                    leftContext: leftContext,
                    drawnCells: drawnCells
                )
        else { return false }
        if verifiesCandidateFilter {
            for index in key.indices { keyScratch[index] = key[index] }
            shapedLinesThisFrame += 1
            let line = shapeRun(characterCount: characterCount, faceMask: faceMask)
            let reference = shapedAnswers(
                line: line,
                leftContext: leftContext,
                drawnCells: drawnCells,
                characterCount: characterCount
            )
            verifiedCandidateRuns += 1
            guard let reference, reference.count == answers.count,
                zip(reference, answers).allSatisfy({ $0.glyphID == $1.glyphID && $0.coveredCells == $1.coveredCells })
            else {
                mismatchedCandidateRuns += 1
                NSLog("shaping-filter mismatch checked=%d mismatches=%d", verifiedCandidateRuns, mismatchedCandidateRuns)
                return false
            }
        }
        key.withUnsafeBufferPointer { words in
            answers.withUnsafeBufferPointer { cells in
                _ = answerCache.publish(
                    Ubiquitty.Rendering.ShapedSegmentSpan(words),
                    0,
                    Ubiquitty.Rendering.ShapedCellSpan(cells)
                )
            }
        }
        return true
    }

    #if canImport(HarfBuzzProbe)
    private func prepareUniformIdentities(_ key: [UInt32]) -> Bool {
        let characterCount = key.count - 3
        let faceMask = key[key.count - 1]
        let shaper: UniformFaceShaper?
        if faceMask == 0 {
            shaper = uniformRegularShaper
        } else if characterCount <= 32,
            faceMask == UInt32.max >> UInt32(32 - characterCount)
        {
            shaper = uniformBoldShaper
        } else {
            return false
        }
        let leftContext = Int(key[characterCount])
        let drawnCells = Int(key[characterCount + 1])
        guard
            let answers = shaper?
                .identities(
                    codePoints: key,
                    characterCount: characterCount,
                    leftContext: leftContext,
                    drawnCells: drawnCells
                )
        else { return false }
        if verifiesUniformShaping {
            for index in key.indices { keyScratch[index] = key[index] }
            let line = shapeRun(characterCount: characterCount, faceMask: faceMask)
            let reference = shapedAnswers(
                line: line,
                leftContext: leftContext,
                drawnCells: drawnCells,
                characterCount: characterCount
            )
            verifiedUniformRuns += 1
            guard let reference, reference.count == answers.count,
                zip(reference, answers).allSatisfy({ $0.glyphID == $1.glyphID && $0.coveredCells == $1.coveredCells })
            else {
                mismatchedUniformRuns += 1
                NSLog("uniform-shaping mismatch checked=%d mismatches=%d", verifiedUniformRuns, mismatchedUniformRuns)
                return false
            }
        }
        key.withUnsafeBufferPointer { words in
            answers.withUnsafeBufferPointer { cells in
                _ = answerCache.publish(
                    Ubiquitty.Rendering.ShapedSegmentSpan(words),
                    0,
                    Ubiquitty.Rendering.ShapedCellSpan(cells)
                )
            }
        }
        return true
    }
    #endif

    func finishPreparation() {
        if verifiesCandidateFilter {
            NSLog("shaping-filter checked=%d mismatches=%d", verifiedCandidateRuns, mismatchedCandidateRuns)
        }
        #if canImport(HarfBuzzProbe)
        if verifiesUniformShaping {
            NSLog("uniform-shaping checked=%d mismatches=%d", verifiedUniformRuns, mismatchedUniformRuns)
        }
        #endif
        guard !pendingShapeJobs.isEmpty else { return }
        shapedLinesThisFrame += pendingShapeJobs.count
        if pendingShapeJobs.count == 1 {
            preparedFrameLines[pendingShapeKeys[0]] = CTLineCreateWithAttributedString(pendingShapeJobs[0].1)
        } else {
            for (index, line) in ShapeBatch(jobs: pendingShapeJobs).perform() {
                preparedFrameLines[pendingShapeKeys[index]] = line
            }
        }
        pendingShapeJobs.removeAll(keepingCapacity: true)
        pendingShapeKeys.removeAll(keepingCapacity: true)
        pendingShapeSet.removeAll(keepingCapacity: true)
    }

    func shapeRuns(
        _ row: UnsafeBufferPointer<Ubiquitty.Rendering.LigatureCell>,
        rowOriginXInPixels: Float,
        cellWidthInPixels: Float,
        pass: Ubiquitty.Rendering.GlyphPass,
        into runs: UnsafeMutableBufferPointer<Ubiquitty.Rendering.LigatureRun>
    ) {
        var groupRuns = runs.mutableSpan
        for index in 0..<runs.count {
            runs[index].length = 0
        }
        guard isEnabled, doesLigate, let rowBase = row.baseAddress, let runsBase = runs.baseAddress else {
            return
        }
        let columnsInRow = Int32(min(row.count, runs.count))
        // A row cannot hold more runs than half its columns (two cells is the
        // floor), and the walk emits in column order — the scratch grows once
        // per resize rather than per row.
        let candidateCapacity = Int(columnsInRow / 2) + 1
        if candidateScratch.count < candidateCapacity {
            candidateScratch = [Ubiquitty.Rendering.LigatureRunCandidate](
                repeating: Ubiquitty.Rendering.LigatureRunCandidate(),
                count: candidateCapacity
            )
        }
        let candidateCount = candidateScratch.withUnsafeMutableBufferPointer { buffer in
            Int(
                Ubiquitty.Rendering.identifyLigatureRuns(
                    rowBase,
                    columnsInRow,
                    participation,
                    .ShapesMixedFaces,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            )
        }
        guard candidateCount > 0 else {
            return
        }
        let slotWidth = Float(slotWidthInPixels)
        for candidateIndex in 0..<candidateCount {
            let candidate = candidateScratch[candidateIndex]
            var didSeatThisCandidate = false
            defer {
                if StripCensus.isEnabled {
                    census.noteCandidate()
                    if !didSeatThisCandidate {
                        census.noteUnstripped()
                    }
                }
            }
            // The row edge shapes as a space: an OpenType backtrack cannot
            // match past the run's first glyph, so a word at the margin would
            // otherwise heal differently from the same word after a real
            // space, and the padding beside it reads as whitespace to the
            // person looking. Core names the flanks; a glyph neighbour —
            // a pane border, a bullet — still shapes as itself.
            let shouldStandLeftSpace = Ubiquitty.Rendering.ligatureRunFlanksRowStart(candidate)
            let shouldStandRightSpace = Ubiquitty.Rendering.ligatureRunFlanksRowEnd(candidate, columnsInRow)
            let virtualLeft: Int32 = shouldStandLeftSpace ? 1 : 0
            let leftContext = candidate.leftContext + virtualLeft
            let total = leftContext + candidate.length + candidate.rightContext + (shouldStandRightSpace ? 1 : 0)
            let shapeKey = shapingKey(candidate, row: row.span)
            for index in shapeKey.indices { keyScratch[index] = shapeKey[index] }
            let faceMask = shapeKey[shapeKey.count - 1]
            let isBold = (rowBase[Int(candidate.startColumn)].shape & Ubiquitty.Rendering.ligatureShapeBold) != 0
            let face = Ubiquitty.Rendering.fontFace(isBold, false)
            let penX = rowOriginXInPixels + Float(candidate.startColumn) * cellWidthInPixels
            let phase =
                pass == .Subpixel
                ? Int32(Ubiquitty.Rendering.phaseForPen(penX, Int32(subpixelPhaseCount), .Floor).phase)
                : 0
            // The fraction the run's origin pixel drops. CoreText floors every
            // pen of the line against the true origin, so the strip is drawn
            // from it and keyed on it; a strip drawn from the phase bucket put
            // each later glyph a step from where the same word sits as single
            // glyphs, and the word moved when a neighbour changed its run.
            let penResidualInPixels: Double = pass == .Subpixel ? Double(penX - penX.rounded(.down)) : 0.0
            let residualCode = Ubiquitty.Rendering.penResidualCode(penResidualInPixels)
            keyScratch[Int(total) + 3] = residualCode
            // The raster variants the drawn cells select — one for a run of one
            // colour, which is nearly every run. Each gets its own strip, keyed
            // and weighted for it, and each column takes the strip drawn at its
            // own; the run itself is not split, so the pen anchors once.
            var variants: [UInt32] = []
            for column in Int(candidate.startColumn)..<Int(candidate.startColumn + candidate.length) {
                let variant = rowBase[column].variant
                if !variants.contains(variant) {
                    variants.append(variant)
                }
            }
            // What the shaper answered for this run, from the cache when it has
            // been shaped before. A hit costs neither a shaping pass nor a slot:
            // the answers are the run's own identities, and a run that can be
            // drawn from them needs no pixels of its own. Asked once for the run,
            // outside the variants, and keyed with no style: the bold mask is
            // already a word of the segment, and the paint a variant selects is
            // a strip's, never a glyph's, so one answer serves every colour the
            // run is drawn in.
            // A genuinely non-escaping `Span` here hits an interop limit this
            // toolchain does not yet resolve: `lookup`'s returned span is
            // cache-owned (ShapedCellCache.cpp copies codePoints/cells into
            // the frame's own storage before returning a view of it), but
            // the imported signature still ties the return's lifetime to the
            // argument's, and a `Span` sourced from `.extracting(...)` is
            // itself scope-bound to the one call expression -- so `held`
            // reads as escaping before it can be used on the next line.
            // `UnsafeBufferPointer` keeps the prefix slice's bounds check
            // (`rebasing:` traps on an out-of-range range, same as `Span`
            // would) without asking the compiler to track a lifetime
            // `lookup`'s C++ signature does not yet state.
            let preparationKey = shapeKey + [cellWidthInPixels.bitPattern]
            if let groups = preparedGroups[preparationKey], !groups.isEmpty {
                if StripCensus.isEnabled {
                    census.noteAnswer(keyScratch: keyScratch, count: Int(total) + 3, isHit: true)
                }
                seatRasterGroups(
                    groups,
                    candidate: candidate,
                    row: row.span,
                    rowOriginX: rowOriginXInPixels,
                    pitch: cellWidthInPixels,
                    pass: pass,
                    into: &groupRuns
                )
                didSeatThisCandidate = true
                continue
            }
            let answers: [Ubiquitty.Rendering.ShapedCell]? = keyScratch.withUnsafeBufferPointer { buffer in
                let segment = Ubiquitty.Rendering.ShapedSegmentSpan(UnsafeBufferPointer(rebasing: buffer[..<(Int(total) + 3)]))
                let held = answerCache.lookup(segment, 0)
                return held.isEmpty ? nil : (0..<held.count).map { held[$0] }
            }
            // A run the shaper answers with no identities draws from its strip
            // alone. That verdict is kept like an answer, so the run is shaped
            // again only when its strip is — `drawStrip` shapes on a fresh slot.
            let isKnownUnanswered =
                answers == nil
                && keyScratch.withUnsafeBufferPointer { buffer in
                    answerCache.holdsNoAnswer(
                        Ubiquitty.Rendering.ShapedSegmentSpan(UnsafeBufferPointer(rebasing: buffer[..<(Int(total) + 3)])),
                        0
                    )
                }
            if StripCensus.isEnabled {
                census.noteAnswer(keyScratch: keyScratch, count: Int(total) + 3, isHit: answers != nil || isKnownUnanswered)
            }
            var shaped = answers
            var line: CTLine? = nil
            if shaped == nil && !isKnownUnanswered {
                let shapedLine = frameLine(key: preparationKey, characterCount: Int(total), faceMask: faceMask)
                line = shapedLine
                shaped = self.shapedAnswers(
                    line: shapedLine,
                    leftContext: Int(leftContext),
                    drawnCells: Int(candidate.length),
                    characterCount: Int(total)
                )
                keyScratch.withUnsafeBufferPointer { buffer in
                    let segment = Ubiquitty.Rendering.ShapedSegmentSpan(UnsafeBufferPointer(rebasing: buffer[..<(Int(total) + 3)]))
                    if let published = shaped {
                        published.withUnsafeBufferPointer { cells in
                            _ = answerCache.publish(segment, 0, Ubiquitty.Rendering.ShapedCellSpan(cells))
                        }
                    } else {
                        _ = answerCache.publish(segment, 0, Ubiquitty.Rendering.ShapedCellSpan())
                    }
                }
            }
            if shaped == nil {
                let groups: [RasterGroup]
                if let cached = preparedGroups[preparationKey] {
                    groups = cached
                } else {
                    let shapedLine = line ?? frameLine(key: preparationKey, characterCount: Int(total), faceMask: faceMask)
                    line = shapedLine
                    groups = makeRasterGroups(
                        line: shapedLine,
                        characterCount: Int(total),
                        leftContext: Int(leftContext),
                        drawnCells: Int(candidate.length),
                        pitch: Double(cellWidthInPixels)
                    )
                    if preparedGroupKeys.count == 4096 {
                        preparedGroups.removeValue(forKey: preparedGroupKeys[nextPreparedGroupKey])
                        preparedGroupKeys[nextPreparedGroupKey] = preparationKey
                        nextPreparedGroupKey = (nextPreparedGroupKey + 1) % preparedGroupKeys.count
                    } else {
                        preparedGroupKeys.append(preparationKey)
                    }
                    preparedGroups[preparationKey] = groups
                }
                if !groups.isEmpty {
                    seatRasterGroups(
                        groups,
                        candidate: candidate,
                        row: row.span,
                        rowOriginX: rowOriginXInPixels,
                        pitch: cellWidthInPixels,
                        pass: pass,
                        into: &groupRuns
                    )
                    didSeatThisCandidate = true
                    continue
                }
            }
            for variant in variants {
                // A run every column of which answers by identity takes no slot
                // and draws no strip: that is the whole saving. The sheet's
                // capacity, its rasterise and its upload are then spent only on
                // the runs that genuinely need pixels — a cluster the face draws
                // from one carrier, a fallback family, a glyph that draws
                // nothing.
                if let identities = shaped {
                    if StripCensus.isEnabled {
                        census.noteProbe(key: 0, isFresh: false)
                    }
                    var run = Ubiquitty.Rendering.LigatureRun()
                    run.startColumn = candidate.startColumn
                    run.length = candidate.length
                    for column in Int(candidate.startColumn)..<Int(candidate.startColumn + candidate.length)
                    where rowBase[column].variant == variant {
                        var columnRun = run
                        columnRun.shaped = identities[column - Int(candidate.startColumn)]
                        columnRun.hasShapedGlyph = true
                        if StripCensus.isEnabled {
                            census.noteShaped()
                        }
                        runsBase[column] = columnRun
                    }
                    continue
                }
                var isFresh = false
                var probedKey: UInt32 = 0
                let slot = keyScratch.withUnsafeBufferPointer { buffer -> Int32 in
                    let stripKey = Ubiquitty.Rendering.ligatureStripKey(buffer.baseAddress, total, face, UInt32(phase))
                    probedKey = stripKey
                    return cache.slotForKeyVerified(
                        Ubiquitty.Rendering.ligatureStripSlotKey(stripKey, variant, residualCode),
                        buffer.baseAddress,
                        total + 4,
                        &isFresh
                    )
                }
                if StripCensus.isEnabled {
                    census.noteProbe(key: probedKey, isFresh: isFresh)
                    census.noteUnshaped()
                }
                guard slot >= 0 else {
                    if StripCensus.isEnabled {
                        census.noteRefusal()
                    }
                    continue
                }
                if isFresh {
                    let rasteriseStart = StripCensus.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                    drawStrip(
                        line: line ?? frameLine(key: preparationKey, characterCount: Int(total), faceMask: faceMask),
                        characterCount: Int(total),
                        leftContext: Int(leftContext),
                        drawnCells: Int(candidate.length),
                        penResidualInPixels: penResidualInPixels,
                        anchorPitchInPixels: Double(cellWidthInPixels),
                        slot: slot,
                        style: style(for: variant)
                    )
                    if StripCensus.isEnabled {
                        census.noteRasterise(spent: DispatchTime.now().uptimeNanoseconds - rasteriseStart)
                    }
                }
                didSeatThisCandidate = true
                var run = Ubiquitty.Rendering.LigatureRun()
                run.startColumn = candidate.startColumn
                run.length = candidate.length
                run.slotWidthInAtlasPixels = slotWidth
                run.usedWidthInAtlasPixels = Ubiquitty.Rendering.ligatureStripUsedWidthInAtlasPixels(
                    candidate.length,
                    Double(cellWidthInPixels),
                    penXInPixels,
                    slotWidth
                )
                // How much of the slot this run's outer cells must leave alone: at
                // a chunk seam the margin beside them holds the neighbouring
                // chunk's context glyphs, which that chunk draws itself.
                let insets = Ubiquitty.Rendering.ligatureStripContextInsets(
                    candidate.leftContext,
                    candidate.rightContext,
                    candidate.length,
                    Double(cellWidthInPixels),
                    penXInPixels,
                    run.usedWidthInAtlasPixels
                )
                run.contextInsetLeftInAtlasPixels = insets.leftInAtlasPixels
                run.contextInsetRightInAtlasPixels = insets.rightInAtlasPixels
                run.strip = stripGlyph(forSlot: Int(slot))
                Ubiquitty.Rendering.attachInkRows(&run, cache.inkRowsForSlot(slot))
                let isSlotInkMeasured = cache.slotHasOwnedInk(slot)
                for column in Int(candidate.startColumn)..<Int(candidate.startColumn + candidate.length)
                where rowBase[column].variant == variant {
                    var columnRun = run
                    if isSlotInkMeasured {
                        Ubiquitty.Rendering.attachOwnedInk(
                            &columnRun,
                            cache.ownedInkForSlot(slot, Int32(column - Int(candidate.startColumn)))
                        )
                    }
                    runsBase[column] = columnRun
                }
            }
        }
    }

    private func makeRasterGroups(
        line: CTLine,
        characterCount: Int,
        leftContext: Int,
        drawnCells: Int,
        pitch: Double
    ) -> [RasterGroup] {
        guard pitch > 0, !ctLineHasLastResortRun(line) else { return [] }
        var glyphs: [GroupGlyph] = []
        let shift = pitch - cellAdvanceInPixels
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            guard let value = attributes[NSAttributedString.Key(kCTFontAttributeName as String)] else { return [] }
            let font = value as! CTFont
            let face: UInt32
            if CFEqual(font, regularFont) { face = 0 } else if CFEqual(font, boldFont) { face = 1 } else { return [] }
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var boxes = [CGRect](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTFontGetBoundingRectsForGlyphs(font, .default, &ids, &boxes, count)
            for index in 0..<count {
                let source = indices[index]
                guard source >= 0, source < characterCount,
                    glyphs.last.map({ $0.source <= source }) ?? true
                else { return [] }
                var position = positions[index].applying(CTFontGetMatrix(font))
                position.x += Double(source) * shift
                glyphs.append(
                    GroupGlyph(
                        glyph: ids[index],
                        font: font,
                        face: face,
                        source: source,
                        position: position,
                        ink: boxes[index]
                    )
                )
            }
        }
        guard !glyphs.isEmpty else { return [] }
        var extents: [Ubiquitty.Rendering.ShapedGlyphExtent] = []
        var nextSourceIndex = 0
        for glyph in glyphs {
            while nextSourceIndex < glyphs.count && glyphs[nextSourceIndex].source <= glyph.source {
                nextSourceIndex += 1
            }
            let next = nextSourceIndex < glyphs.count ? glyphs[nextSourceIndex].source : characterCount
            var extent = Ubiquitty.Rendering.ShapedGlyphExtent()
            extent.firstCell = Int32(glyph.source)
            extent.cellCount = Int32(next - glyph.source)
            if !glyph.ink.isNull, glyph.ink.width > 0 {
                extent.inkLeftInCells = (glyph.position.x + glyph.ink.minX - 1) / pitch
                extent.inkRightInCells = (glyph.position.x + glyph.ink.maxX + 1) / pitch
            }
            extents.append(extent)
        }
        var boundaries = [UInt8](repeating: 0, count: characterCount)
        var partitions = [Ubiquitty.Rendering.ShapedGlyphGroup](repeating: .init(), count: characterCount)
        let count = extents.withUnsafeBufferPointer { input in
            boundaries.withUnsafeMutableBufferPointer { scratch in
                partitions.withUnsafeMutableBufferPointer { output in
                    Ubiquitty.Rendering.partitionShapedGlyphGroups(
                        Ubiquitty.Rendering.ShapedGlyphExtentSpan(input),
                        Int32(characterCount),
                        Ubiquitty.Rendering.ShapedGlyphBoundarySpan(scratch),
                        Ubiquitty.Rendering.ShapedGlyphGroupSpan(output)
                    )
                }
            }
        }
        var result: [RasterGroup] = []
        var memberIndex = 0
        for partition in partitions.prefix(Int(count)) {
            let first = Int(partition.firstCell)
            let end = first + Int(partition.cellCount)
            if end <= leftContext || first >= leftContext + drawnCells { continue }
            // A carrier crossing the candidate edge stays in the enclosing strip.
            guard first >= leftContext, end <= leftContext + drawnCells else { return [] }
            // The group starts at its first cell, on the grid's pitch.
            let anchor = CTLineGetOffsetForStringIndex(line, first, nil) + Double(first) * shift
            while memberIndex < glyphs.count && glyphs[memberIndex].source < first {
                memberIndex += 1
            }
            let memberStart = memberIndex
            while memberIndex < glyphs.count && glyphs[memberIndex].source < end {
                memberIndex += 1
            }
            let members = glyphs[memberStart..<memberIndex]
                .map {
                    GroupGlyph(
                        glyph: $0.glyph,
                        font: $0.font,
                        face: $0.face,
                        source: $0.source - first,
                        position: CGPoint(x: $0.position.x - anchor, y: $0.position.y),
                        ink: $0.ink
                    )
                }
            var rasterKey: [UInt32] = [0x4752_5031, UInt32(end - first)]
            rasterKey.reserveCapacity(2 + members.count * 7)
            for glyph in members {
                rasterKey.append(contentsOf: [
                    glyph.face, UInt32(glyph.glyph), UInt32(glyph.source),
                    UInt32(truncatingIfNeeded: glyph.position.x.bitPattern),
                    UInt32(truncatingIfNeeded: glyph.position.x.bitPattern >> 32),
                    UInt32(truncatingIfNeeded: glyph.position.y.bitPattern),
                    UInt32(truncatingIfNeeded: glyph.position.y.bitPattern >> 32),
                ])
            }
            result.append(
                RasterGroup(
                    firstCell: first - leftContext,
                    cellCount: end - first,
                    glyphs: members,
                    rasterKey: rasterKey
                )
            )
        }
        return result
    }

    private func seatRasterGroups(
        _ groups: [RasterGroup],
        candidate: Ubiquitty.Rendering.LigatureRunCandidate,
        row: Span<Ubiquitty.Rendering.LigatureCell>,
        rowOriginX: Float,
        pitch: Float,
        pass: Ubiquitty.Rendering.GlyphPass,
        into runs: inout MutableSpan<Ubiquitty.Rendering.LigatureRun>
    ) {
        for group in groups {
            let first = Int(candidate.startColumn) + group.firstCell
            let pen = rowOriginX + Float(first) * pitch
            let residual = pass == .Subpixel ? Double(pen - pen.rounded(.down)) : 0
            var variants: [UInt32] = []
            for column in first..<(first + group.cellCount) where !variants.contains(row[column].variant) {
                variants.append(row[column].variant)
            }
            for variant in variants {
                var fresh = false
                var probedKey: UInt32 = 0
                let slot = withUnsafeTemporaryAllocation(of: UInt32.self, capacity: group.rasterKey.count + 4) { key in
                    for index in group.rasterKey.indices { key[index] = group.rasterKey[index] }
                    let offset = group.rasterKey.count
                    key[offset] = pitch.bitPattern
                    key[offset + 1] = variant
                    key[offset + 2] = UInt32(truncatingIfNeeded: residual.bitPattern)
                    key[offset + 3] = UInt32(truncatingIfNeeded: residual.bitPattern >> 32)
                    var hash: UInt32 = 2_166_136_261
                    for word in key { hash = (hash ^ word) &* 16_777_619 }
                    probedKey = hash
                    return cache.slotForKeyVerified(UInt64(hash), key.baseAddress, Int32(key.count), &fresh)
                }
                if StripCensus.isEnabled {
                    census.noteProbe(key: probedKey, isFresh: fresh)
                    census.noteUnshaped()
                }
                guard slot >= 0 else {
                    if StripCensus.isEnabled { census.noteRefusal() }
                    continue
                }
                if fresh {
                    let rasteriseStart = StripCensus.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                    context.clear(CGRect(x: 0, y: 0, width: slotWidthInPixels, height: slotHeightInPixels))
                    stripFillGray = GlyphRasterizer.fillGray(forTier: style(for: variant).tier)
                    context.setFillColor(gray: stripFillGray, alpha: 1)
                    cache.beginOwnedInkRecord(slot)
                    for glyph in group.glyphs {
                        let id: InlineArray<1, CGGlyph> = [glyph.glyph]
                        let position = CGPoint(
                            x: penXInPixels + residual + glyph.position.x,
                            y: penYInPixels + glyph.position.y
                        )
                        let pen: InlineArray<1, CGPoint> = [position]
                        drawGlyphsJoined(glyph.font, id.span, pen.span)
                        if !glyph.ink.isNull, glyph.ink.width > 0 {
                            cache.recordShapedGlyphInk(
                                slot,
                                Int32(glyph.source),
                                0,
                                Int32(group.cellCount),
                                Int32((position.x + glyph.ink.minX).rounded(.down)),
                                Int32((position.x + glyph.ink.maxX).rounded(.up)),
                                Self.outlineInkFringeInPixels
                            )
                        }
                    }
                    cache.finalizeOwnedInkRecord(slot)
                    uploadSlot(slot)
                    if StripCensus.isEnabled {
                        census.noteRasterise(spent: DispatchTime.now().uptimeNanoseconds - rasteriseStart)
                    }
                }
                var run = Ubiquitty.Rendering.LigatureRun()
                run.startColumn = Int32(first)
                run.length = Int32(group.cellCount)
                run.slotWidthInAtlasPixels = Float(slotWidthInPixels)
                run.usedWidthInAtlasPixels = Ubiquitty.Rendering.ligatureStripUsedWidthInAtlasPixels(
                    Int32(group.cellCount),
                    Double(pitch),
                    penXInPixels,
                    Float(slotWidthInPixels)
                )
                run.strip = stripGlyph(forSlot: Int(slot))
                Ubiquitty.Rendering.attachInkRows(&run, cache.inkRowsForSlot(slot))
                for column in first..<(first + group.cellCount) where row[column].variant == variant {
                    var cellRun = run
                    Ubiquitty.Rendering.attachOwnedInk(&cellRun, cache.ownedInkForSlot(slot, Int32(column - first)))
                    runs[column] = cellRun
                }
            }
        }
    }

    /// The rasteriser style a variant selects: its tier.
    private func style(for variant: UInt32) -> GlyphRasterizer.Style {
        GlyphRasterizer.Style(tier: Ubiquitty.Rendering.variantTier(variant))
    }

    /// The full-slot UV rect for one strip.
    ///
    /// The rect spans the whole slot; the builder maps each covered cell's
    /// atlas-pixel range onto it linearly, so no per-cell UV crosses the seam.
    private func stripGlyph(forSlot slot: Int) -> Ubiquitty.Rendering.AtlasGlyph {
        let column = slot % columns
        let row = slot / columns
        var glyph = Ubiquitty.Rendering.AtlasGlyph()
        glyph.minUV.x = Float(column * slotWidthInPixels)
        glyph.minUV.y = Float(row * slotHeightInPixels)
        glyph.maxUV.x = Float((column + 1) * slotWidthInPixels)
        glyph.maxUV.y = Float((row + 1) * slotHeightInPixels)
        glyph.present = true
        return glyph
    }

    /// What the configuration asks of the proportional face.
    package struct ProportionalFaceRequest {
        /// The family, or empty for the platform's UI face.
        package var familyName: String = ""
        /// The em size in points, or zero for one optical step over the
        /// grid's.
        package var pointSize: Double = 0

        package init(familyName: String = "", pointSize: Double = 0) {
            self.familyName = familyName
            self.pointSize = pointSize
        }
    }

    /// The proportional face, scaled to the grid's pixels by a font matrix:
    /// the platform's UI face, or the configured family when it names one
    /// the system has; at the configured size when that is set, and
    /// otherwise at Core's ``proportionalFacePointSize``, one optical step
    /// over the grid's em.
    ///
    /// Built at the point size rather than the pixel size because the system
    /// face is not one design: its optical size and its tracking follow the
    /// point size it is asked for, and AppKit draws a 10pt label on a 2x
    /// display from the 10pt face under a 2x transform. Asked for at 20 the
    /// face comes back tighter — `Remind me later` measures 142px against
    /// the 156px a 10pt label takes — and no label would line up with the
    /// same text in a window beside it.
    ///
    /// - Parameters:
    ///   - faces: The grid's faces, which carry the pixel size and the scale.
    ///   - request: The configured family and size, each empty for the
    ///     default.
    ///   - isBold: Whether the bold face is wanted; the family's own bold, as
    ///     the grid's bold is the grid family's.
    ///   - isItalic: Whether the italic face is wanted; the family's own
    ///     italic, so an SGR 3 label slants the way a label in the
    ///     platform's dialogs slants.
    /// - Returns: The proportional face, or the grid's regular face when the
    ///   system has none to give.
    package static func proportionalFace(
        sizedLike faces: FontFaces,
        request: ProportionalFaceRequest,
        isBold: Bool,
        isItalic: Bool
    ) -> CTFont {
        let gridPointSize = faces.size / faces.pixelsPerPoint
        let pointSize = Ubiquitty.Rendering.proportionalFacePointSize(gridPointSize, request.pointSize)
        var matrix = CGAffineTransform(scaleX: faces.pixelsPerPoint, y: faces.pixelsPerPoint)
        // A shipped family is drawn from its own files in every style, never
        // matched by name or trait against what the machine has installed.
        if let shipped = FontFaces.shippedStyle(
            family: request.familyName,
            size: pointSize,
            matrix: matrix,
            isBold: isBold,
            isItalic: isItalic
        ) {
            return shipped
        }
        return (namedProportionalFace(request.familyName, pointSize: pointSize) ?? CTFontCreateUIFontForLanguage(.system, pointSize, nil))
            .map { base in
                let upright: CTFont
                if isBold {
                    // The symbolic trait asks the family for its bold member. A
                    // weight trait copied onto the regular moves only a
                    // variable face's axis, so a family of static faces — SF
                    // Pro Text, Helvetica Neue — would set its bold in its
                    // regular; it remains the route for a family that has an
                    // axis and no bold member.
                    let traits: [CFString: Any] = [kCTFontWeightTrait: 0.4]
                    let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
                    upright =
                        CTFontCreateCopyWithSymbolicTraits(base, pointSize, &matrix, .boldTrait, .boldTrait)
                        ?? CTFontCreateCopyWithAttributes(base, pointSize, &matrix, descriptor)
                } else {
                    let traits: [CFString: Any] = [kCTFontWeightTrait: 0.0]
                    let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
                    upright = CTFontCreateCopyWithAttributes(base, pointSize, &matrix, descriptor)
                }
                guard isItalic else {
                    return upright
                }
                // The symbolic trait asks the family for its italic; a family
                // without one keeps the upright rather than a slanted copy of
                // a different face.
                return CTFontCreateCopyWithSymbolicTraits(upright, pointSize, &matrix, .italicTrait, .italicTrait) ?? upright
            } ?? faces[Ubiquitty.Rendering.FontFace.Regular]
    }

    /// The configured family's face, when the system has that family.
    ///
    /// Matched by family name rather than taken from `CTFontCreateWithName`,
    /// which answers a name it cannot find with a substitute and says
    /// nothing: a configuration naming a family that is not installed then
    /// draws Helvetica under the name the reader typed. A miss answers nil,
    /// and the caller takes the platform's UI face.
    ///
    /// - Parameters:
    ///   - familyName: The configured family, or empty for none.
    ///   - pointSize: The em size to build at.
    /// - Returns: The family's upright face, or nil when the configuration
    ///   names none or the system has none by that name.
    package static func namedProportionalFace(_ familyName: String, pointSize: Double) -> CTFont? {
        let wanted = familyName.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else {
            return nil
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: wanted] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
        let family = CTFontCopyFamilyName(font) as String
        guard family.caseInsensitiveCompare(wanted) == .orderedSame else {
            return nil
        }
        return font
    }

    /// The proportional face a grid face selects.
    ///
    /// - Parameter face: The run's grid face, whose weight and slant carry.
    /// - Returns: The matching proportional face.
    private func proportionalFont(for face: Ubiquitty.Rendering.FontFace) -> CTFont {
        switch (Ubiquitty.Rendering.isBold(face), Ubiquitty.Rendering.isItalic(face)) {
        case (false, false): return proportionalRegularFont
        case (true, false): return proportionalBoldFont
        case (false, true): return proportionalItalicFont
        case (true, true): return proportionalBoldItalicFont
        }
    }

    /// Shapes a proportional run as one line in the proportional face.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The grid face whose weight and slant the run carries.
    ///   - widenedFont: The face widened on its `wdth` axis, for a run on a
    ///     DECDWL row, or `nil` for the face at its own width.
    /// - Returns: The line, and its typographic width in device pixels.
    private func proportionalLine(
        _ codePoints: UnsafeBufferPointer<UInt32>,
        face: Ubiquitty.Rendering.FontFace,
        widenedFont: CTFont? = nil
    ) -> (line: CTLine, width: Double) {
        let font = widenedFont ?? proportionalFont(for: face)
        let isWidened = widenedFont != nil
        let key = ProportionalLineKey(codePoints: Array(codePoints), face: face, isWidened: isWidened)
        proportionalLinesLock.lock()
        let cached = proportionalLineStore[key]
        proportionalLinesLock.unlock()
        if let cached {
            return cached
        }
        var scalars = String.UnicodeScalarView()
        for codePoint in codePoints {
            scalars.append(Unicode.Scalar(codePoint) ?? "\u{FFFD}")
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(scalars), attributes: attributes))
        let shaped = (line, CTLineGetTypographicBounds(line, nil, nil, nil))
        // Bounded by emptying: a screen of labels holds a few hundred, and a
        // stream that mints new text without end would otherwise hold every
        // line it ever shaped.
        proportionalLinesLock.lock()
        if proportionalLineStore.count >= LigatureSheet.proportionalLineCapacity {
            proportionalLineStore.removeAll(keepingCapacity: true)
        }
        proportionalLineStore[key] = shaped
        proportionalLinesLock.unlock()
        return shaped
    }

    /// What names a shaped proportional line: its text and its face.
    private struct ProportionalLineKey: Hashable {
        let codePoints: [UInt32]
        let face: Ubiquitty.Rendering.FontFace
        let isWidened: Bool
    }

    /// How many shaped lines ``proportionalLine(_:face:widenedFont:)`` keeps.
    private static let proportionalLineCapacity = 4096

    /// The lines shaped so far, so a label drawn every frame is shaped once.
    ///
    /// Read on the render thread for strips and on the reader thread for a
    /// measurement, under ``proportionalLinesLock``.
    private var proportionalLineStore: [ProportionalLineKey: (line: CTLine, width: Double)] = [:]
    private let proportionalLinesLock = NSLock()

    /// Maps CoreText's UTF-16 offsets to the source run's code-point indices.
    ///
    /// - Parameter codePoints: The source run, bounded by the protocol.
    /// - Returns: One source index per UTF-16 unit and the terminal boundary.
    static func proportionalUTF16SourceIndices(_ codePoints: borrowing [UInt32]) -> [UInt16] {
        var indices: [UInt16] = []
        indices.reserveCapacity(codePoints.count * 2 + 1)
        for (index, codePoint) in codePoints.enumerated() {
            indices.append(UInt16(clamping: index))
            if codePoint > 0xFFFF && codePoint <= 0x10FFFF {
                indices.append(UInt16(clamping: index))
            }
        }
        indices.append(UInt16(clamping: codePoints.count))
        return indices
    }

    /// The cells a proportional run needs in the proportional face.
    ///
    /// The measurement the application asks for before it prints
    /// (`OSC 66 p=1:q=1`): the line's typographic width over the cell advance,
    /// rounded up, at least one.
    ///
    /// - Parameter codePoints: The run's text.
    /// - Returns: The cell count.
    /// The proportional face a run is shaped in, for a backend drawing its
    /// glyphs by identity.
    ///
    /// - Parameter face: The style the run was shaped in.
    /// - Returns: The regular or the bold proportional face.
    func proportionalFont(forFace face: Ubiquitty.Rendering.FontFace) -> CTFont {
        proportionalFont(for: face)
    }

    /// The proportional faces widened on their `wdth` axis, built on first use.
    private lazy var doubleWidthProportionalFonts: [CTFont?] = [
        Ubiquitty.Rendering.FontFace.Regular, .Bold, .Italic, .BoldItalic,
    ]
    .map { FontFaces.doubleWidthInstance(of: proportionalFont(for: $0)) }

    /// The proportional face a run on a DECDWL row draws from, where the
    /// family can widen.
    ///
    /// - Parameter face: The style the run was shaped in.
    /// - Returns: The widened face, or `nil` when the family has no room to widen.
    func doubleWidthProportionalFont(forFace face: Ubiquitty.Rendering.FontFace) -> CTFont? {
        doubleWidthProportionalFonts[Int(face.rawValue) & 0x3]
    }

    /// Shapes a proportional run and answers its glyphs, advances and
    /// clusters (Docs/proportional-text.md), for Core to place.
    ///
    /// The shaper's answer and nothing more: positions are in the line's text
    /// space scaled by the face's matrix, which is how the proportional face
    /// built at the point size reaches atlas pixels, and each glyph names the
    /// code point it begins at. Alignment, justification and cells are Core's
    /// (Rendering/ProportionalRun.h), so this arm and every other place a
    /// letter by one arithmetic.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The style to shape in; italic reduces to its weight, since the
    ///     proportional face pair carries no slant.
    /// - Returns: One entry per glyph in text order, empty when the run does
    ///   not shape in the proportional face.
    func shapeProportionalRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace
    ) -> [Ubiquitty.ProportionalShapedGlyph] {
        let count = Int(codePoints.size())
        // The bitmap tier has no per-glyph route: Core's strike draws the
        // run as one strip, and an identity answered here would be read by
        // the wide sheet as CoreText's.
        guard isEnabled, unifontScale == 0, count > 0, let data = codePoints.__dataUnsafe() else {
            return []
        }
        var text = [UInt32](repeating: 0, count: count)
        for index in 0..<count {
            text[index] = data[index]
        }
        let shaped = text.withUnsafeBufferPointer { proportionalLine($0, face: face) }
        let sourceIndices = Self.proportionalUTF16SourceIndices(text)
        var out: [Ubiquitty.ProportionalShapedGlyph] = []
        var penBefore = 0.0
        for run in (CTLineGetGlyphRuns(shaped.line) as? [CTRun] ?? []) {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0,
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                let runFontAny = attributes[NSAttributedString.Key(kCTFontAttributeName as String)]
            else {
                continue
            }
            let runFont = runFontAny as! CTFont
            // A run the shaper handed to another face is not this face's
            // identity: its ids would be read by the proportional face as
            // other letters. The whole run then refuses, and the caller draws
            // it the way it already can.
            guard CFEqual(runFont, proportionalFont(for: face)) else {
                return []
            }
            let fontMatrix = CTFontGetMatrix(runFont)
            let range = CFRangeMake(0, glyphCount)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var indices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            CTRunGetAdvances(run, range, &advances)
            CTRunGetStringIndices(run, range, &indices)
            // CoreText answers advances with the face's matrix applied and
            // positions without it (measured: a 2x face's advances sum to the
            // line's typographic width, its last position to half of it), so
            // only the positions are scaled here.
            for index in 0..<glyphCount {
                let position = positions[index].applying(fontMatrix)
                var glyph = Ubiquitty.ProportionalShapedGlyph()
                glyph.glyph = UInt32(glyphs[index])
                glyph.advanceInPixels = Float(advances[index].width)
                // The shaper's position already holds the advances before
                // this glyph; Core re-sums advances, so the offset is what is
                // left after those are taken back out.
                glyph.offsetXInPixels = Float(position.x - penBefore)
                glyph.offsetYInPixels = Float(position.y)
                glyph.cluster = sourceIndices[min(max(Int(indices[index]), 0), sourceIndices.count - 1)]
                out.append(glyph)
                penBefore += advances[index].width
            }
        }
        return out
    }

    func proportionalRunCells(_ codePoints: UnsafeBufferPointer<UInt32>) -> Int {
        guard cellAdvanceInPixels > 0, !codePoints.isEmpty else {
            return 0
        }
        if unifontScale > 0 {
            return Int(
                Ubiquitty.Rendering.unifontProportionalRunCells(
                    Int32(unifontScale),
                    Ubiquitty.Rendering.ClusterSpan(codePoints),
                    Float(cellAdvanceInPixels)
                )
            )
        }
        let width = proportionalLine(codePoints, face: Ubiquitty.Rendering.FontFace.Regular).width
        return max(1, Int((width / cellAdvanceInPixels - 1e-6).rounded(.up)))
    }

    /// Returns the strip for a proportional run and where its quad goes,
    /// rasterising on a miss.
    ///
    /// The strip holds the text's ink with a margin each side, not the run's
    /// cells: a run may be wider than the slot, and the quad wants the ink.
    /// Keyed like a ligature strip on the run's text, with a marker, the
    /// width, the alignment and the aligned pen's residual folded into the
    /// verified contents, so a proportional run of some text and a ligature
    /// run of the same text never share a slot, and the same label at two
    /// pen phases draws at each.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - widthCells: The cells the run occupies.
    ///   - horizontalAlign: Left, right or centred inside them.
    ///   - penResidualInPixels: The run's pen past its whole pixel.
    ///   - face: Regular or bold.
    ///   - variant: The raster variant the run's foreground selects.
    ///   - tileIndex: The zero-based horizontal tile of the complete run.
    ///   - scale: How many times its size the run is drawn both ways: 2 on a
    ///     DECDHL pair, its OSC 66 scale, 1 otherwise. The run is then drawn
    ///     under a CTM that scale on a canvas that many slots tall, of which
    ///     the slot is the one `band` slot heights down.
    ///   - band: Which slot height of a run drawn at `scale`, from the top.
    ///   - widthScale: 2 for a run on a DECDWL row: the run is laid out twice
    ///     as wide over twice the cells and drawn from the face widened on its
    ///     `wdth` axis, scaled across by what the axis left. A justified run
    ///     draws the face itself twice as wide.
    /// - Returns: The placement; an absent strip when the sheet refuses.
    func proportionalStrip(
        _ codePoints: UnsafeBufferPointer<UInt32>,
        widthCells: Int,
        horizontalAlign: UInt8,
        penResidualInPixels: Double,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        tileIndex: Int,
        scale: Int = 1,
        band: Int = 0,
        widthScale: Int = 1
    ) -> Ubiquitty.Rendering.ProportionalStripPlacement {
        var placement = Ubiquitty.Rendering.ProportionalStripPlacement()
        guard isEnabled, !codePoints.isEmpty, widthCells >= 1 else {
            return placement
        }
        let run = codePoints
        let drawnScale = max(scale, 1)
        let drawnBand = band < drawnScale ? band : 0
        if unifontScale > 0 {
            return unifontProportionalStrip(
                Ubiquitty.Rendering.ClusterSpan(run),
                widthCells: widthCells,
                horizontalAlign: horizontalAlign,
                penResidualInPixels: penResidualInPixels,
                face: face,
                variant: variant,
                tileIndex: tileIndex,
                scale: drawnScale,
                band: drawnBand,
                widthScale: widthScale == 2 ? 2 : 1
            )
        }
        let shaped = proportionalLine(run, face: face)
        let isDoubled = widthScale == 2
        // A justified run opens its gaps by Core's arithmetic on the face's own
        // line, so it is doubled from that line rather than the widened face's.
        let isWidened = isDoubled && horizontalAlign != 3
        // The doubled run's letterforms: the widened face's line where the
        // family has one, drawn across at the factor that brings it to twice
        // the ordinary line's width.
        let widenedFont = isWidened ? doubleWidthProportionalFont(forFace: face) : nil
        let doubledLine = widenedFont.map { proportionalLine(run, face: face, widenedFont: $0) } ?? shaped
        let doubledScale = isDoubled && doubledLine.width > 0 ? 2 * shaped.width / doubledLine.width : 1
        // How many times its own width the strip is laid out across.
        let across = drawnScale * (isDoubled ? 2 : 1)
        // Justified: Core's gap arithmetic opens each interior space by the
        // same amount, and the widened width is what the layout below places
        // — a justified run fills its cells, so it has no slack to align.
        var gapExtraInPixels = 0.0
        if horizontalAlign == 3 {
            let gapCount = Ubiquitty.Rendering.proportionalJustifyGapCount(Ubiquitty.Rendering.ClusterSpan(run))
            gapExtraInPixels = Ubiquitty.Rendering.proportionalJustifyGapInPixels(
                shaped.width,
                Int32(widthCells),
                cellAdvanceInPixels,
                gapCount
            )
        }
        let gapCountForWidth =
            horizontalAlign == 3
            ? Int(Ubiquitty.Rendering.proportionalJustifyGapCount(Ubiquitty.Rendering.ClusterSpan(run))) : 0
        let justifiedWidth = shaped.width + gapExtraInPixels * Double(gapCountForWidth)
        // Core's one layout: the aligned pen, its whole pixels and residual,
        // the clip and the strip's width, so this arm places a label where
        // every other arm places it.
        let layout = Ubiquitty.Rendering.proportionalStripLayout(
            Double(across) * justifiedWidth,
            Int32(across * widthCells),
            horizontalAlign,
            penResidualInPixels,
            cellAdvanceInPixels,
            penXInPixels,
            Double(slotWidthInPixels),
            Int32(tileIndex)
        )
        guard layout.tileCount > 0 else { return placement }
        var request = Ubiquitty.Rendering.ProportionalStripRequest()
        request.widthCells = Int32(widthCells)
        request.horizontalAlign = horizontalAlign
        request.face = face
        request.tileIndex = Int32(tileIndex)
        request.widthScale = isDoubled ? 2 : 1
        request.scale = UInt8(drawnScale)
        request.band = UInt8(drawnBand)
        let resolved = Ubiquitty.Rendering.resolveProportionalStripSlot(
            cache,
            Ubiquitty.Rendering.ClusterSpan(run),
            request,
            layout,
            variant,
            &proportionalVerification
        )
        let slot = resolved.slot
        guard slot >= 0 else {
            return placement
        }
        if resolved.isFresh {
            cache.clearOwnedInkRecord(slot)
            context.clear(CGRect(x: 0, y: 0, width: CGFloat(slotWidthInPixels), height: CGFloat(slotHeightInPixels)))
            stripFillGray = GlyphRasterizer.fillGray(forTier: style(for: variant).tier)
            context.setFillColor(gray: stripFillGray, alpha: 1.0)
            // Drawn glyph by glyph at the line's own positions rather than by
            // `CTLineDraw`: that call leaves the context's text position at
            // the line's end, and `CTFontDrawGlyphs` adds the text position to
            // every position it is handed, so one line drawn that way moved
            // every strip rasterised after it in the frame out of its slot.
            context.saveGState()
            context.clip(
                to: CGRect(
                    x: layout.clipLeftInSlotPixels,
                    y: 0,
                    width: layout.clipRightInSlotPixels - layout.clipLeftInSlotPixels,
                    height: CGFloat(slotHeightInPixels)
                )
            )
            // Core's source shifts are repeated for both UTF-16 units of a
            // supplementary scalar because CoreText indices name those units.
            var gapShiftByIndex: [Double] = []
            if gapExtraInPixels > 0 {
                Ubiquitty.Rendering.proportionalJustificationOffsets(
                    Ubiquitty.Rendering.ProportionalSourceSpan(run),
                    gapExtraInPixels,
                    &proportionalSourceOffsets
                )
                gapShiftByIndex.reserveCapacity(run.count * 2 + 1)
                for index in 0..<run.count {
                    let offset = proportionalSourceOffsets[index]
                    gapShiftByIndex.append(offset)
                    if run[index] > 0xFFFF && run[index] <= 0x10FFFF {
                        gapShiftByIndex.append(offset)
                    }
                }
                gapShiftByIndex.append(proportionalSourceOffsets[run.count])
            }
            if across > 1 {
                // The run at its size: a CTM `scale` both ways, and the
                // doubling across on a DECDWL row, about the pen, with the
                // canvas `scale` slots tall standing so the band's slot height
                // is this slot. In device pixels from the slot's bottom-left.
                let factor = CGFloat(drawnScale)
                context.translateBy(x: layout.penXInSlotPixels, y: -CGFloat((drawnScale - 1 - drawnBand) * slotHeightInPixels))
                context.scaleBy(x: factor * (isDoubled ? doubledScale : 1), y: factor)
                drawAnchoredGlyphs(
                    isWidened ? doubledLine.line : shaped.line,
                    at: CGPoint(x: 0, y: penYInPixels),
                    shiftPerCell: 0,
                    gapShiftByIndex: gapShiftByIndex
                )
            } else {
                drawAnchoredGlyphs(
                    shaped.line,
                    at: CGPoint(x: layout.penXInSlotPixels, y: penYInPixels),
                    shiftPerCell: 0,
                    gapShiftByIndex: gapShiftByIndex
                )
            }
            context.restoreGState()
            uploadSlot(slot)
        }
        placement.strip = stripGlyph(forSlot: Int(slot))
        placement.strip.minUV.x += layout.rasterInsetInPixels
        placement.strip.maxUV.x = placement.strip.minUV.x + layout.usedWidthInSlotPixels
        placement.leftInPixels = layout.quadLeftInPixels
        placement.widthInPixels = layout.usedWidthInSlotPixels
        // At a size the slot is a slot height of the strip `scale` times as
        // tall, standing `scale` times the strip's top above the block and the
        // band's slot heights down.
        placement.topInPixels = Float(Double(drawnScale) * stripTopInPixels + Double(drawnBand * slotHeightInPixels))
        placement.tileCount = layout.tileCount
        placement.drawnWidthScale = Float(across)
        placement.drawnScale = Float(drawnScale)
        return placement
    }

    /// The bitmap tier's strip: Core shapes the run in its strike, lays it
    /// out and draws it into one slot of coverage, and this sheet keys the
    /// slot the way the native tier's strip is keyed and uploads the bytes.
    ///
    /// - Parameters:
    ///   - run: The complete run's text.
    ///   - widthCells: The cells the run occupies.
    ///   - horizontalAlign: Left, right, centred or justified inside them.
    ///   - penResidualInPixels: The run's pen past its whole pixel.
    ///   - face: Regular or bold.
    ///   - variant: The raster variant the run's foreground selects.
    ///   - tileIndex: The zero-based horizontal tile of the complete run.
    ///   - scale: How many times its size the run is drawn both ways.
    ///   - band: Which slot height of a run drawn at `scale`, from the top.
    ///   - widthScale: 2 for a run on a DECDWL row, 1 otherwise.
    /// - Returns: The placement; an absent strip when Core refuses the run.
    private func unifontProportionalStrip(
        _ run: Ubiquitty.Rendering.ClusterSpan,
        widthCells: Int,
        horizontalAlign: UInt8,
        penResidualInPixels: Double,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        tileIndex: Int,
        scale: Int,
        band: Int,
        widthScale: Int
    ) -> Ubiquitty.Rendering.ProportionalStripPlacement {
        var placement = Ubiquitty.Rendering.ProportionalStripPlacement()
        var request = Ubiquitty.Rendering.ProportionalStripRequest()
        request.widthCells = Int32(widthCells)
        request.horizontalAlign = horizontalAlign
        request.penResidualInPixels = Float(penResidualInPixels)
        request.cellAdvanceInPixels = Float(cellAdvanceInPixels)
        request.marginXInPixels = Float(penXInPixels)
        request.slotWidthInPixels = Int32(slotWidthInPixels)
        request.slotHeightInPixels = Int32(slotHeightInPixels)
        request.face = face
        request.tileIndex = Int32(tileIndex)
        request.scale = UInt8(scale)
        request.band = UInt8(band)
        request.widthScale = UInt8(widthScale)
        let shape = Ubiquitty.Rendering.shapeUnifontProportionalStrip(Int32(unifontScale), run, request)
        guard shape.glyphCount > 0 else {
            return placement
        }
        let layout = shape.layout
        guard layout.tileCount > 0 else { return placement }
        let resolved = Ubiquitty.Rendering.resolveProportionalStripSlot(
            cache,
            run,
            request,
            layout,
            variant,
            &proportionalVerification
        )
        let slot = resolved.slot
        guard slot >= 0 else {
            return placement
        }
        if resolved.isFresh {
            let slotBytes = slotWidthInPixels * slotHeightInPixels
            if unifontStripScratch.count != slotBytes {
                unifontStripScratch = [UInt8](repeating: 0, count: slotBytes)
            }
            let isDrawn = unifontStripScratch.withUnsafeMutableBufferPointer { plane in
                Ubiquitty.Rendering.rasteriseUnifontProportionalStrip(
                    Int32(unifontScale),
                    run,
                    request,
                    Ubiquitty.Rendering.CoverageSlot(plane)
                )
            }
            guard isDrawn else {
                cache.forgetKeyAtSlot(resolved.key, resolved.slot)
                return placement
            }
            cache.clearOwnedInkRecord(slot)
            let box = Ubiquitty.Rendering.atlasSlotRegion(
                slot,
                Int32(columns),
                Int32(slotWidthInPixels),
                Int32(slotHeightInPixels)
            )
            unifontStripScratch.withUnsafeBytes { bytes in
                uploader.stage(
                    bytes.baseAddress!,
                    bytesPerRow: slotWidthInPixels,
                    region: MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height)),
                    into: texture
                )
            }
        }
        placement.strip = stripGlyph(forSlot: Int(slot))
        placement.strip.minUV.x += layout.rasterInsetInPixels
        placement.strip.maxUV.x = placement.strip.minUV.x + layout.usedWidthInSlotPixels
        placement.leftInPixels = layout.quadLeftInPixels
        placement.widthInPixels = layout.usedWidthInSlotPixels
        placement.topInPixels = Float(Double(scale) * stripTopInPixels + Double(band * slotHeightInPixels))
        placement.tileCount = layout.tileCount
        placement.drawnWidthScale = Float(scale * widthScale)
        placement.drawnScale = Float(scale)
        return placement
    }

    /// Reuses a frame's shape across rows and raster variants, including strip-only results.
    private func frameLine(key: [UInt32], characterCount: Int, faceMask: UInt32) -> CTLine {
        if let line = preparedFrameLines[key] { return line }
        let line = shapeRun(characterCount: characterCount, faceMask: faceMask)
        preparedFrameLines[key] = line
        return line
    }

    /// Shapes the context and drawn cells from `keyScratch` with their original faces.
    private func shapeRun(characterCount: Int, faceMask: UInt32) -> CTLine {
        CTLineCreateWithAttributedString(attributedRun(codePoints: keyScratch, characterCount: characterCount, faceMask: faceMask))
    }

    private func attributedRun(codePoints: [UInt32], characterCount: Int, faceMask: UInt32) -> NSAttributedString {
        let text = withUnsafeTemporaryAllocation(of: UInt16.self, capacity: characterCount) { buffer in
            for index in 0..<characterCount {
                buffer[index] = UInt16(codePoints[index])
            }
            return String(utf16CodeUnits: buffer.baseAddress!, count: characterCount)
        }
        // One line, faces applied per character — the shape CoreText resolves a
        // mixed-style run through. A bold `t` before a regular `mux` shapes as
        // one line here, and the contextual form of the `m` survives the
        // boundary; shaping the two halves apart returns the default `m`
        // instead, which is the fault a reader sees as a word healing on one
        // line and not on the next.
        let attributed = NSMutableAttributedString(string: text, attributes: regularAttributes)
        if faceMask != 0 {
            let utf16 = Array(text.utf16)
            var offset = 0
            while offset < utf16.count {
                guard offset < 32, (faceMask & (1 << UInt32(offset))) != 0 else {
                    offset += 1
                    continue
                }
                var end = offset
                while end < utf16.count, end < 32, (faceMask & (1 << UInt32(end))) != 0 {
                    end += 1
                }
                attributed.setAttributes(boldAttributes, range: NSRange(location: offset, length: end - offset))
                offset = end
            }
        }
        return attributed.copy() as! NSAttributedString
    }

    /// Draws a shaped run into a slot, and records the ink each column owns.
    ///
    /// Reached only for a run that cannot be drawn from glyph identities: the
    /// face answered part of it with a glyph that draws nothing, or from
    /// another family, or with a cluster spanning cells. Everything else skips
    /// this, and skips the slot it would have taken.
    ///
    /// - Parameters:
    ///   - line: The shaped line from ``shapeRun(characterCount:faceMask:)``.
    ///   - characterCount: The shaped text's length, context included.
    ///   - leftContext: How many context entries precede the drawn run.
    ///   - drawnCells: How many cells the run draws.
    ///   - penResidualInPixels: The fraction the run's origin pixel drops.
    ///   - anchorPitchInPixels: The cell pitch each cluster anchors to.
    ///   - slot: The slot to draw into.
    ///   - style: The rasteriser style the variant selects.
    private func drawStrip(
        line: CTLine,
        characterCount: Int,
        leftContext: Int,
        drawnCells: Int,
        penResidualInPixels: Double,
        anchorPitchInPixels: Double,
        slot: Int32,
        style: GlyphRasterizer.Style
    ) {
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(slotWidthInPixels), height: CGFloat(slotHeightInPixels)))
        stripFillGray = GlyphRasterizer.fillGray(forTier: style.tier)
        context.setFillColor(gray: stripFillGray, alpha: 1.0)
        // How far each cluster moves from the shaper's pen to its own cell.
        // The seam's contract (``GlyphBackend/shapeLigatureRuns``): column K
        // sits at K cells, whatever the face's own advance, as on the portable
        // sheet; a pen-run raster beside it puts a neighbour's edge into cell K
        // wherever the two rulers disagree.
        // Zero whenever the pitch is the face's advance, which is every
        // untracked monospace frame; under tracking it is the inter-cluster
        // padding, so ligature ink stays whole and letterforms keep the shape
        // the face drew.
        let anchorShiftPerCell = anchorPitchInPixels - cellAdvanceInPixels
        if !ctLineHasLastResortRun(line) {
            // The typographic x of the run's first character within the
            // shaped line — exact even where a ligature spans the
            // context/run boundary, plus the context's own anchor shift.
            let contextOffset =
                (leftContext > 0 ? CTLineGetOffsetForStringIndex(line, leftContext, nil) : 0.0)
                + Double(leftContext) * anchorShiftPerCell
            let textOrigin = CGPoint(
                x: penXInPixels + penResidualInPixels - contextOffset,
                y: penYInPixels
            )
            if ProcessInfo.processInfo.environment["UBQ_STRIPLOG"] != nil {
                var glyphInfo: [String] = []
                for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
                    let n = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: n)
                    var positions = [CGPoint](repeating: .zero, count: n)
                    var boxes = [CGRect](repeating: .zero, count: n)
                    CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
                    CTRunGetPositions(run, CFRangeMake(0, n), &positions)
                    let runFont =
                        (CTRunGetAttributes(run) as! [NSAttributedString.Key: Any])[NSAttributedString.Key(kCTFontAttributeName as String)]
                        as! CTFont
                    CTFontGetBoundingRectsForGlyphs(runFont, .default, glyphs, &boxes, n)
                    for i in 0..<n {
                        glyphInfo.append(
                            String(
                                format: "g%d@%.2f[%.2f..%.2f]",
                                Int(glyphs[i]),
                                textOrigin.x + positions[i].x,
                                textOrigin.x + positions[i].x + boxes[i].minX,
                                textOrigin.x + positions[i].x + boxes[i].maxX
                            )
                        )
                    }
                }
                NSLog(
                    "UBQ_STRIPLOG chars=%d leftContext=%d drawn=%d penX=%.2f residual=%.4f contextOffset=%.2f origin=%.2f glyphs=%@",
                    characterCount,
                    leftContext,
                    drawnCells,
                    penXInPixels,
                    penResidualInPixels,
                    contextOffset,
                    textOrigin.x,
                    glyphInfo.joined(separator: " ")
                )
            }
            drawAnchored(line, at: textOrigin, shiftPerCell: anchorShiftPerCell, style: style)
            recordOwnedInk(
                line: line,
                textOriginX: textOrigin.x,
                shiftPerCell: anchorShiftPerCell,
                leftContext: leftContext,
                drawnCells: drawnCells,
                slot: slot
            )
        } else {
            cache.clearOwnedInkRecord(slot)
        }

        uploadSlot(slot)
    }

    /// Draws glyphs into the slot, joining overlapping coverage the way
    /// macOS CoreText joins it for this face.
    ///
    /// Where two glyphs' antialiased edges overlap — a run of `=` whose bars
    /// reach into the next cell, a W whose arms meet its neighbour's —
    /// CoreText's join depends on the face object. Measured on macOS 27:
    /// a face registered for the process takes the per-pixel maximum of the
    /// two coverages (Monaspace Neon's `=` run at 28 px); a system face, and
    /// a face built from a file's descriptor without registering it, lays one
    /// glyph over the other, source-over. iOS lays every face over, so a
    /// registered face's maximum is drawn here on both platforms, which keeps
    /// the two arms one picture.
    ///
    /// - Parameters:
    ///   - font: The face.
    ///   - glyphs: The glyphs.
    ///   - positions: Their pens in slot pixels, already through the face's
    ///     matrix.
    private func drawGlyphsJoined(
        _ font: CTFont,
        _ glyphs: Span<CGGlyph>,
        _ positions: Span<CGPoint>
    ) {
        let count = min(glyphs.count, positions.count)
        guard count > 0 else { return }
        let scope = (CTFontCopyAttribute(font, kCTFontRegistrationScopeAttribute) as? NSNumber)?.uint32Value
        guard scope == CTFontManagerScope.process.rawValue else {
            // Source-over, which is what the slot context does with each draw.
            for index in 0..<count {
                var glyph = glyphs[index]
                var position = positions[index]
                CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            }
            return
        }
        guard let slotPlane = context.data, let scratchPlane = glyphScratch.data else { return }
        let width = slotWidthInPixels
        let height = slotHeightInPixels
        let slotBounds = CGRect(x: 0, y: 0, width: width, height: height)
        // A doubled strip draws under a scale; the scratch draws under the
        // same transform, and the merge works in the plane's own pixels.
        let transform = context.ctm
        let clip = context.boundingBoxOfClipPath.applying(transform).intersection(slotBounds)
        guard !clip.isNull, !clip.isEmpty else { return }
        // CoreText answers these bounds with the face's matrix already
        // applied; applying it again misplaces the region a glyph is merged
        // through, and ink outside that region is lost.
        var inks = [CGRect](repeating: .zero, count: count)
        _ = glyphs.withUnsafeBufferPointer { CTFontGetBoundingRectsForGlyphs(font, .horizontal, $0.baseAddress!, &inks, count) }
        let slot = slotPlane.assumingMemoryBound(to: UInt8.self)
        let scratch = scratchPlane.assumingMemoryBound(to: UInt8.self)
        let slotStride = context.bytesPerRow
        let scratchStride = glyphScratch.bytesPerRow
        glyphScratch.setFillColor(gray: stripFillGray, alpha: 1)
        for index in 0..<count {
            let ink = inks[index]
            guard !ink.isNull, !ink.isEmpty else { continue }
            // Three pixels of slack for the antialiased rim past the outline.
            let region = ink.offsetBy(dx: positions[index].x, dy: positions[index].y).applying(transform)
                .insetBy(dx: -3, dy: -3).intersection(clip).integral.intersection(slotBounds)
            guard !region.isNull, !region.isEmpty else { continue }
            glyphScratch.clear(region)
            glyphScratch.saveGState()
            // The slot's own clip, not the whole-pixel region: a strip's clip
            // edge can fall inside a pixel, and the slot draw antialiases that
            // edge where the rounded region would ink the pixel whole.
            glyphScratch.clip(to: region.intersection(clip))
            glyphScratch.concatenate(transform)
            var glyph = glyphs[index]
            var position = positions[index]
            CTFontDrawGlyphs(font, &glyph, &position, 1, glyphScratch)
            glyphScratch.restoreGState()
            // The planes are stored top row first; the region is in the
            // context's bottom-up coordinates.
            let left = Int(region.minX)
            let right = Int(region.maxX)
            for y in Int(region.minY)..<Int(region.maxY) {
                let row = height - 1 - y
                let slotRow = slot + row * slotStride
                let scratchRow = scratch + row * scratchStride
                for x in left..<right where scratchRow[x] > slotRow[x] {
                    slotRow[x] = scratchRow[x]
                }
            }
        }
    }

    /// Copies the context's plane into the sheet at a slot.
    ///
    /// - Parameter slot: The slot the cache assigned.
    private func uploadSlot(_ slot: Int32) {
        guard let plane = context.data else {
            return
        }
        // The strip's inked rows, measured from the plane being uploaded, so
        // its quads can stop at the ink rather than at the slot's margins.
        // The context is alpha-only and packed, one byte per pixel.
        let count = slotWidthInPixels * slotHeightInPixels
        cache.recordInkRows(
            slot,
            Ubiquitty.Rendering.GlyphSlotCache.InkPlaneSpan(
                UnsafeBufferPointer(start: plane.assumingMemoryBound(to: UInt8.self), count: count)
            ),
            Int32(slotWidthInPixels),
            Int32(slotHeightInPixels)
        )
        let box = Ubiquitty.Rendering.atlasSlotRegion(
            slot,
            Int32(columns),
            Int32(slotWidthInPixels),
            Int32(slotHeightInPixels)
        )
        uploader.stage(
            plane,
            bytesPerRow: context.bytesPerRow,
            region: MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height)),
            into: texture
        )
    }

    /// Draws the shaped line with every cluster anchored to its cell.
    ///
    /// The shaper's positions carry two things: the pen's cumulative advance,
    /// which the grid overrules, and the face's own offsets within a cluster,
    /// which nothing else knows. The shift keeps the second and cancels the
    /// first against the cell pitch, per string index — a ligature is one
    /// glyph at its lead character's index, so its art moves whole.
    ///
    /// - Parameters:
    ///   - line: The shaped line.
    ///   - textOrigin: Where the line's pen starts, in slot pixels.
    ///   - shiftPerCell: The per-cell anchor shift, zero at natural pitch.
    private func drawAnchored(_ line: CTLine, at textOrigin: CGPoint, shiftPerCell: Double, style: GlyphRasterizer.Style) {
        // The smoothed fill at the tier's gray, with the strip's anchored positions.
        drawAnchoredGlyphs(line, at: textOrigin, shiftPerCell: shiftPerCell)
    }

    private func drawAnchoredGlyphs(
        _ line: CTLine,
        at textOrigin: CGPoint,
        shiftPerCell: Double,
        gapShiftByIndex: [Double] = []
    ) {
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0,
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                let runFontAny = attributes[NSAttributedString.Key(kCTFontAttributeName as String)]
            else {
                continue
            }
            let runFont = runFontAny as! CTFont
            // A run's positions are in the line's text space, before the
            // font's own matrix; `CTFontDrawGlyphs` applies that matrix to
            // the outlines and not to the positions it is handed, so a face
            // scaled by its matrix — the proportional face, built at the
            // point size — needs its positions scaled the same way here, as
            // `CTLineDraw` would have scaled them.
            let fontMatrix = CTFontGetMatrix(runFont)
            withUnsafeTemporaryAllocation(of: CGGlyph.self, capacity: glyphCount) { glyphs in
                withUnsafeTemporaryAllocation(of: CGPoint.self, capacity: glyphCount) { positions in
                    withUnsafeTemporaryAllocation(of: CFIndex.self, capacity: glyphCount) { indices in
                        let range = CFRangeMake(0, glyphCount)
                        CTRunGetGlyphs(run, range, glyphs.baseAddress!)
                        CTRunGetPositions(run, range, positions.baseAddress!)
                        CTRunGetStringIndices(run, range, indices.baseAddress!)
                        for index in 0..<glyphCount {
                            let scaled = positions[index].applying(fontMatrix)
                            let stringIndex = Int(indices[index])
                            let gapShift =
                                gapShiftByIndex.isEmpty
                                ? 0.0
                                : gapShiftByIndex[min(max(stringIndex, 0), gapShiftByIndex.count - 1)]
                            positions[index].x = scaled.x + textOrigin.x + Double(stringIndex) * shiftPerCell + gapShift
                            positions[index].y = scaled.y + textOrigin.y
                        }
                        drawGlyphsJoined(runFont, glyphs.span, positions.span)
                    }
                }
            }
        }
    }

    /// Records what the shaper answered for each drawn column of a slot.
    ///
    /// The answers ride the slot rather than the call because a slot is
    /// rasterised on a miss and reused on every hit after it: an answer held
    /// only where the line was built would be missing on exactly the frames the
    /// cache is earning its keep.
    ///
    /// A run whose shaper reached another family records no answer at all. A
    /// glyph id names a glyph inside the face that produced it, so an id from a
    /// fallback
    /// family served against the primary face draws a different letter rather
    /// than a missing one — the seam's own clause, enforced where the fallback
    /// is visible instead of trusted to the caller.
    ///
    /// - Parameters:
    ///   - line: The shaped line, context included.
    ///   - leftContext: How many context entries precede the drawn run.
    ///   - drawnCells: How many cells the run draws.
    ///   - characterCount: The shaped text's length, context included.
    ///   - slot: The slot being rasterised.
    private func shapedAnswers(line: CTLine, leftContext: Int, drawnCells: Int, characterCount: Int) -> [Ubiquitty.Rendering.ShapedCell]? {
        let answersPerSlot = Int(Ubiquitty.Rendering.ligatureMaxCells)
        guard drawnCells <= answersPerSlot else {
            return nil
        }
        var answers = [Ubiquitty.Rendering.ShapedCell](
            repeating: Ubiquitty.Rendering.ShapedCell(),
            count: drawnCells
        )

        // The cluster each drawn column's glyph carries, and the cluster of the
        // next glyph after it: a ligature maps several characters to one glyph,
        // so the distance between consecutive clusters is how many cells that
        // glyph covers.
        var clusters: [Int] = []
        var ids: [CGGlyph] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0,
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                let runFontAny = attributes[NSAttributedString.Key(kCTFontAttributeName as String)]
            else {
                continue
            }
            let runFont = runFontAny as! CTFont
            guard CFEqual(runFont, regularFont) || CFEqual(runFont, boldFont) else {
                // A fallback family shaped part of this run; no id here names a
                // glyph the primary face can draw.
                return nil
            }
            var runGlyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var runIndices = [CFIndex](repeating: 0, count: glyphCount)
            var runBoxes = [CGRect](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &runGlyphs)
            CTRunGetStringIndices(run, CFRangeMake(0, glyphCount), &runIndices)
            CTFontGetBoundingRectsForGlyphs(runFont, .default, &runGlyphs, &runBoxes, glyphCount)
            for index in 0..<glyphCount {
                // A glyph that draws nothing is part of a cluster whose image
                // one carrier holds: the face answers `///` with three glyphs
                // for three characters, and two of them are blank while the
                // third carries the whole ligature. Advances do not separate
                // them — all three advance a cell — so the ink does.
                //
                // Read as three substitutions, the two blanks draw nothing and
                // the carrier draws the ligature inside its own cell, and `///`
                // renders as `//`, 204 ink pixels against the golden's 306: the
                // defect the chunk-seam retreat closes from the other direction.
                //
                // The whole run is refused rather than the cluster, because a
                // partial answer leaves the carrier's cells drawing under a
                // strip its neighbours have left. Refusing costs the run
                // nothing: it keeps the strip it already drew. A space is the
                // one character whose glyph draws nothing by design.
                let isBlank = runBoxes[index].isNull || runBoxes[index].width <= 0.01
                let isSpace = keyScratch[Int(runIndices[index])] == 0x20
                guard !isBlank || isSpace else {
                    return nil
                }
                ids.append(runGlyphs[index])
                clusters.append(Int(runIndices[index]))
            }
        }
        // One glyph per character, and every one of them advancing. The count
        // alone does not separate a substitution run from a ligated one — a
        // face answers `///` with three glyphs for three characters — so the
        // advance above is the discriminator and this is the cheaper guard
        // beside it.
        guard !ids.isEmpty, ids.count == characterCount else {
            return nil
        }

        for index in 0..<ids.count {
            let column = Int(
                Ubiquitty.Rendering.shapedGlyphColumn(Int32(clusters[index]), Int32(leftContext), Int32(drawnCells))
            )
            guard column >= 0 else {
                continue
            }
            // The cluster's extent: the next glyph's cluster, or the end of the
            // shaped text for the last one. A substitution covers one cell and
            // a ligature covers the cells its characters occupied.
            let nextCluster = index + 1 < clusters.count ? clusters[index + 1] : characterCount
            let covered = max(1, min(nextCluster - clusters[index], answersPerSlot - column))
            var answer = Ubiquitty.Rendering.ShapedCell()
            answer.glyphID = UInt32(ids[index])
            answer.coveredCells = UInt8(covered)
            answers[column] = answer
        }
        // Every drawn column must have answered, or the run cannot be drawn
        // from identities at all: a column left blank here would draw nothing
        // beside neighbours that drew, which is worse than the strip it would
        // have taken.
        for answer in answers where answer.glyphID == 0 {
            return nil
        }
        return answers
    }

    /// The pixels a strip column draws past its glyphs' outline box.
    ///
    /// The box bounds the outline, and the antialiased coverage of an edge
    /// that lands mid-pixel can spill into the next one. The fringe keeps
    /// that coverage inside the column's slice without claiming it as ink.
    private static let outlineInkFringeInPixels: Int32 = 1

    /// Records each shaped glyph's horizontal ink into Core's ledger.
    ///
    /// The arm contributes only the platform truth — where CoreText put each
    /// glyph and how wide its outline box is — and Core's
    /// ``GlyphSlotCache/recordShapedGlyphInk`` owns the policy: which column
    /// the cluster names, that context clusters record nothing, and the
    /// clamp to the slot. The outline box rounded outward is the ink; the
    /// antialiased edge can reach past it, so the record also carries
    /// ``outlineInkFringeInPixels``, which widens the pixels the column draws
    /// and leaves the ink — where a following underline ends — as measured.
    /// Core's finalize settles any overlap the fringe opens between
    /// neighbours, so no strip pixel is composited twice.
    private func recordOwnedInk(line: CTLine, textOriginX: Double, shiftPerCell: Double, leftContext: Int, drawnCells: Int, slot: Int32) {
        cache.beginOwnedInkRecord(slot)
        defer { cache.finalizeOwnedInkRecord(slot) }
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else {
                continue
            }
            guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                let runFontAny = attributes[NSAttributedString.Key(kCTFontAttributeName as String)]
            else {
                continue
            }
            let runFont = runFontAny as! CTFont
            withUnsafeTemporaryAllocation(of: CGGlyph.self, capacity: glyphCount) { glyphs in
                withUnsafeTemporaryAllocation(of: CGPoint.self, capacity: glyphCount) { positions in
                    withUnsafeTemporaryAllocation(of: CFIndex.self, capacity: glyphCount) { indices in
                        withUnsafeTemporaryAllocation(of: CGRect.self, capacity: glyphCount) { boxes in
                            let range = CFRangeMake(0, glyphCount)
                            CTRunGetGlyphs(run, range, glyphs.baseAddress!)
                            CTRunGetPositions(run, range, positions.baseAddress!)
                            CTRunGetStringIndices(run, range, indices.baseAddress!)
                            CTFontGetBoundingRectsForGlyphs(runFont, .default, glyphs.baseAddress!, boxes.baseAddress!, glyphCount)
                            for index in 0..<glyphCount {
                                let box = boxes[index]
                                guard !box.isNull, box.width > 0 else {
                                    continue
                                }
                                let anchoredX =
                                    textOriginX + positions[index].x
                                    + Double(indices[index]) * shiftPerCell
                                let inkLeft = anchoredX + box.minX
                                let inkRight = anchoredX + box.maxX
                                cache.recordShapedGlyphInk(
                                    slot,
                                    Int32(indices[index]),
                                    Int32(leftContext),
                                    Int32(drawnCells),
                                    Int32(inkLeft.rounded(.down)),
                                    Int32(inkRight.rounded(.up)),
                                    Self.outlineInkFringeInPixels
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Answers Core's healing probe for one strip font.
    ///
    /// Shapes ``ligatureHealingProbe`` as one line — what a strip would draw —
    /// and maps the same characters one at a time, which is what the per-cell
    /// mono path draws; Core's ``decideLigatureParticipation`` turns any
    /// disagreement into ``AllEligibleRuns``. The criterion and the text are
    /// Core's; this arm contributes only the platform shaper's answers.
    private static func probeParticipation(font: CTFont) -> Ubiquitty.Rendering.LigatureParticipation {
        let probe = String(cString: Ubiquitty.Rendering.ligatureHealingProbe)
        let characters = Array(probe.utf16)

        var isolated: [UInt32] = []
        isolated.reserveCapacity(characters.count)
        var scratch = [CGGlyph](repeating: 0, count: 1)
        for character in characters {
            var one = [character]
            guard CTFontGetGlyphsForCharacters(font, &one, &scratch, 1) else {
                return .OperatorRuns // a face this seam cannot ask stays on the economy
            }
            isolated.append(UInt32(scratch[0]))
        }

        let attributed = NSAttributedString(
            string: probe,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var shaped: [UInt32] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            shaped.append(contentsOf: glyphs.map { UInt32($0) })
        }

        return shaped.withUnsafeBufferPointer { shapedBuffer in
            isolated.withUnsafeBufferPointer { isolatedBuffer in
                Ubiquitty.Rendering.decideLigatureParticipation(
                    shapedBuffer.baseAddress,
                    Int32(shapedBuffer.count),
                    isolatedBuffer.baseAddress,
                    Int32(isolatedBuffer.count)
                )
            }
        }
    }

    /// Resolves a feature spec in Core's grammar into CoreText settings.
    private static func featureSettings(fromSpec spec: String) -> [[CFString: Any]] {
        var settings: [[CFString: Any]] = []
        let parsed = Ubiquitty.Rendering.parseFontFeatureSpecification(std.string(spec))
        for setting in parsed {
            settings.append([
                kCTFontOpenTypeFeatureTag: String(setting.tag),
                kCTFontOpenTypeFeatureValue: Int(setting.value),
            ])
        }
        return settings
    }

    /// A face copy with feature settings applied, or the face when none are.
    private static func applying(_ settings: [[CFString: Any]], to base: CTFont) -> CTFont {
        guard !settings.isEmpty else {
            return base
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: settings] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, 0.0, nil, descriptor)
    }
}
