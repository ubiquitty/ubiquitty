// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// AppKit-only: the battery drives the composition path from a desktop
// window. The draw-entry seam it does not cover is DrawEntrySmoke's, which
// both shells run.

#if canImport(AppKit)

// SurfaceSmoke.swift — the headless oracle for the TerminalSurface frame path.
//
// The surface renderer's composition — measurement, sheets, capture, encode,
// present — has no snapshot arm and no pixel gate of its own yet, so a broken
// wiring would fail only when a host embeds one. This drives the whole path
// twice from the command line: two frames, with content fed between them,
// because a first frame exercises only the build-everything path and says
// nothing about the frame after it.
//
// Before you trust a green leg: delete what it covers and watch it go RED. A
// leg that still passes was measuring the ENVIRONMENT rather than the
// behaviour. A zoom leg here asserted the re-fitted grid was under 80 columns;
// the simulator window is 54, so it passed with `resizeGridToBounds()` deleted
// — `columns < 80` is a true statement about the window, not about re-fitting.
// Anchor the comparison to what the FEATURE produces (the re-fit's own output),
// or delete the leg: a green that cannot go red is a claim of coverage rather
// than coverage, and it stops anyone writing the real one.

import AppKit
import Metal
import QuartzCore
internal import UbiquittyRenderKit
internal import UbiquittyCore

/// The smoke's entry, which the application's entry point dispatches.
public final class SurfaceSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether both frames drew through the full surface path.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            SurfaceSmoke.run()
        }
    }
}

/// The smoke's scenario, kept as a type so its pieces stay named.
@MainActor
enum SurfaceSmoke {
    /// Builds a surface and its renderer, then draws two frames into an
    /// offscreen layer.
    ///
    /// - Returns: Whether every stage reported success.
    static func run() -> Bool {
        // The whole run is pinned at tick zero — the blink curve's solid
        // hold — so the cursor's fade cannot make the reuse legs
        // phase-dependent: a mid-fade cursor is a plan hazard, and with a
        // live clock the legs would pass or fail by wall time. The clock leg
        // moves the pin to a value it asserts, then restores it.
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)
        guard let device = SystemMetalDevice.resolve() else {
            return failed("no Metal device")
        }
        guard let library = MetalPipelines.moduleShaderLibrary(for: device) else {
            return failed("no module shader library")
        }
        // Every pipeline this device will build, asked before anything draws. A
        // state that fails costs its own pass, the encoder skips a nil pipeline
        // without reporting it, and the frame arrives missing a whole layer
        // while the render reports success — so an arm can draw no underline,
        // strike, selection, search pill or inline image and still pass every
        // case that does not happen to look at one. The failure writes a log
        // line, which nothing here can read; this asks the object instead.
        let pipelines = MetalPipelines(device: device, pixelFormat: .bgra8Unorm, library: library)
        guard pipelines.unbuiltPipelines.isEmpty else {
            let names = pipelines.unbuiltPipelines.joined(separator: ", ")
            return failed("pipelines this device could not build: \(names)")
        }
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no surface session")
        }
        guard
            let renderer = SurfaceRenderer(
                device: device,
                library: library,
                familyName: "Menlo",
                pointSize: 12
            )
        else {
            return failed("no surface renderer")
        }
        surface.renderer = renderer
        // The surface's OWN layer, which is the one a window presents. Every
        // other leg here draws into a layer this smoke made, so a surface whose
        // layer can hand out no drawable passes all of them and still shows a
        // viewer an empty window: attaching a renderer is the moment that layer
        // becomes usable, and nothing else asserts it did.
        guard surface.metalLayer.device != nil else {
            return failed("attaching a renderer left the surface's own layer without a device")
        }
        let cell = renderer.cellSize(for: surface)
        guard cell.width > 0, cell.height > 0 else {
            return failed("degenerate cell size")
        }

        // The typography leg. `GlyphAtlas.shared(key:)` hands two renderers one
        // set of sheets when their keys match, so a field of the configuration
        // the key does not name merges two configurations that draw
        // differently — and the merge is invisible downstream, because both
        // sides then rasterise into sheets that look like their own.
        //
        // Asserted field by field rather than on one changed value: a key built
        // from a subset passes the whole-struct test on whichever field the
        // subset happens to include. Each of these is a different way for the
        // key to be built from too little.
        let baseKey = renderer.currentSheetKey
        var typographies: [(String, SurfaceTypography)] = []
        typographies.append(("wideGlyphBoostCap", SurfaceTypography(wideGlyphBoostCap: 1.25)))
        typographies.append(("unifontScale", SurfaceTypography(unifontScale: 2)))
        typographies.append(("cjkFallbackFamily", SurfaceTypography(cjkFallbackFamily: "Hiragino Sans")))
        typographies.append(("cjkFallbackLanguage", SurfaceTypography(cjkFallbackLanguage: "ja")))
        typographies.append(("symbolFamilyName", SurfaceTypography(symbolFamilyName: "Symbols Nerd Font")))
        typographies.append(("symbolFontPath", SurfaceTypography(symbolFontPath: "/tmp/symbols.ttf")))
        typographies.append(("ligatureFeatureSpec", SurfaceTypography(ligatureFeatureSpec: "calt")))
        typographies.append(("canLigate", SurfaceTypography(canLigate: true)))
        typographies.append(("lineSpacingInPoints", SurfaceTypography(lineSpacingInPoints: 4)))
        typographies.append(("fontVariationSpec", SurfaceTypography(fontVariationSpec: "slnt=-6")))
        var nominalFallbacks = SurfaceTypography()
        nominalFallbacks.shouldMatchFallbackSize = false
        typographies.append(("shouldMatchFallbackSize", nominalFallbacks))
        var rangeTypography = SurfaceTypography()
        var range = SurfaceTypography.FallbackRule()
        range.firstCodePoint = 0x2426
        range.lastCodePoint = 0x2426
        range.family = "Apple Symbols"
        range.mode = "custom"
        rangeTypography.rangeMaps = [range]
        let inheritedRangeKey = rangeTypography.routingKey
        rangeTypography.rangeMaps[0].shouldMatchSize = false
        guard rangeTypography.routingKey != inheritedRangeKey else {
            return failed("range size override did not change the glyph sheet identity")
        }
        typographies.append(("rangeSizing", rangeTypography))
        for (field, typography) in typographies {
            guard
                let varied = SurfaceRenderer(
                    device: device,
                    library: library,
                    familyName: "Menlo",
                    pointSize: 12,
                    typography: typography
                )
            else {
                return failed("no surface renderer for a typography varying \(field)")
            }
            guard varied.currentSheetKey != baseKey else {
                return failed("the sheet key does not name \(field), so two configurations share one atlas")
            }
        }
        // The Tektronix leg. Its styling reaches a renderer from Core's fold
        // of the configuration, and until that derivation existed nothing
        // wrote the field at all: a Tek frame drew under `SurfaceTekSettings`'
        // own defaults, which are not the configuration's. The writing spot
        // is the case that proves the difference — the type defaults it DRAWN
        // and `[tek] bright_pen` defaults it off — so a derivation that
        // stopped reading the fold and fell back to the type would fail here
        // rather than on a reader's screen.
        do {
            let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
            defer { _ = Ubiquitty.Preferences.configure(std.string(saved), .Permissive) }
            func configureTek(brightPen: Bool) {
                let tek = "\n[tek]\nbright_pen = \(brightPen)\nglow_vectors = true\ncolor_mode = 1\n"
                _ = Ubiquitty.Preferences.configure(std.string(saved + tek), .Permissive)
            }
            configureTek(brightPen: false)
            let derived = SurfaceTekSettings(configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration())
            guard !derived.drawsWritingSpot else {
                return failed("the tek derivation kept the type's drawn-spot default over the configuration's off")
            }
            guard derived.drawsGlowVectors, derived.usesCustomColors else {
                return failed("the tek derivation did not carry the configured glow and colour mode")
            }
            configureTek(brightPen: true)
            guard SurfaceTekSettings(configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration()).drawsWritingSpot else {
                return failed("the tek derivation answered the same styling for two configurations")
            }
            // The shared factory is the only renderer an iOS pane and the iOS
            // snapshot have, so it carries the configuration's styling itself;
            // one that took the type's defaults drew no bloom, the theme's
            // phosphor and a spot nobody asked for on that shell.
            configureTek(brightPen: false)
            guard let factoryRenderer = TerminalSurface.makeRenderer(device: device) as? SurfaceRenderer else {
                return failed("the shared factory built no surface renderer")
            }
            guard factoryRenderer.tekSettings.drawsGlowVectors, factoryRenderer.tekSettings.usesCustomColors,
                !factoryRenderer.tekSettings.drawsWritingSpot
            else {
                return failed("the shared factory's renderer kept the type's tek defaults over the configuration")
            }
        }

        // The underline leg. The configuration's frame styling reaches a
        // renderer through the shared factory, which every shell builds from;
        // a renderer styled from `SurfaceStyle`'s neutral defaults instead
        // cuts its rule around descenders with no clearance, so the rule runs
        // into the stroke it skips. The clearance is the field that tells the
        // two apart: the configuration's default keeps one, the type's does not.
        do {
            let configuration = Ubiquitty.Preferences.values().pointee
            let configuredPad = Ubiquitty.Preferences.Effective.underlineSkipInkPad(configuration)
            guard let shared = TerminalSurface.makeRenderer(device: device) as? SurfaceRenderer else {
                return failed("the shared factory built no surface renderer")
            }
            guard shared.style.shouldUnderlineSkipInk == Ubiquitty.Preferences.Effective.underlineSkipInk(configuration),
                configuredPad > 0, shared.style.underlineSkipInkPaddingInPoints == configuredPad
            else {
                return failed(
                    "the shared factory's renderer skips ink with a \(shared.style.underlineSkipInkPaddingInPoints) pt clearance where the configuration names \(configuredPad) pt"
                )
            }
        }

        // And the other direction, which is the half that would let the key be
        // trivially unique: the same configuration must resolve to the same key,
        // or every surface rasterises its own copy of every glyph.
        guard
            let repeated = SurfaceRenderer(
                device: device,
                library: library,
                familyName: "Menlo",
                pointSize: 12
            ),
            repeated.currentSheetKey == baseKey
        else {
            return failed("one configuration measured twice resolved to two sheet keys")
        }

        // Readied by the renderer, never by hand. A layer this smoke configured
        // itself is a layer the app does not build: the device and pixel format
        // are exactly what a shipping surface can lack while every leg here
        // passes, so setting them here is the oracle supplying the thing it is
        // supposed to be checking.
        let layer = CAMetalLayer()
        renderer.prepare(layer)
        guard layer.device != nil else {
            return failed("the renderer readied a layer with no device, so it can hand out no drawable")
        }
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 384)
        // Stated rather than left at the default: a drawable twice the frame
        // with a scale of one describes a layer AppKit never hands out, and the
        // scale is what this smoke goes on to assert against.
        layer.contentsScale = 2
        layer.drawableSize = CGSize(width: 1280, height: 768)

        guard layer.nextDrawable() != nil else {
            return failed("layer vends no drawable")
        }
        guard surface.drive.borrowTerminal() != nil else {
            return failed("no borrowed terminal")
        }
        feed(surface.drive, "surface-smoke-frame-one\r\n")
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("first frame declined")
        }
        feed(surface.drive, "surface-smoke-frame-two\r\n")
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("second frame declined")
        }

        // The typing phase probe. Every glyph's subpixel phase derives from its
        // pen x, and the pen is origin plus columns times advance — so with the
        // quads pinned to the pixel grid, these two numbers are the only ones
        // that can move ink INSIDE the quads. One character per frame; any
        // frame whose origin or advance differs from the previous one is the
        // live arm's "groups of 8 squeeze and restore" (subpixelPhaseCount is
        // 8, and the first cell of a line, phase zero, is the one that never
        // moves). The values are printed on failure: the numbers are the
        // diagnosis, not the adjectives.
        var previousOriginX = renderer.lastFrameOriginXInPixels
        var previousOriginY = renderer.lastFrameOriginYInPixels
        var previousAdvance = renderer.lastFrameCellWidthInAtlasPixels
        var phaseInputDrift = ""
        for step in 0..<24 {
            feed(surface.drive, "a")
            guard renderer.encodeFrame(for: surface, into: layer) else {
                return failed("typing probe frame \(step) declined")
            }
            let originX = renderer.lastFrameOriginXInPixels
            let originY = renderer.lastFrameOriginYInPixels
            let advance = renderer.lastFrameCellWidthInAtlasPixels
            if originX != previousOriginX || originY != previousOriginY || advance != previousAdvance {
                phaseInputDrift +=
                    " [\(step): origin (\(previousOriginX),\(previousOriginY))->(\(originX),\(originY))"
                    + " advance \(previousAdvance)->\(advance) reused=\(renderer.didReuseLastFrame)]"
            }
            previousOriginX = originX
            previousOriginY = originY
            previousAdvance = advance
        }
        guard phaseInputDrift.isEmpty else {
            return failed("typing moved the phase inputs:\(phaseInputDrift)")
        }
        guard previousOriginX == previousOriginX.rounded(), previousOriginY == previousOriginY.rounded() else {
            return failed(
                "the grid origin is a fraction of a device pixel (\(previousOriginX),\(previousOriginY)) — "
                    + "every pen inherits the fraction, so the phase the atlas rasterised for a cell no "
                    + "longer matches where its ink lands"
            )
        }

        // The proportional-text leg (Docs/proportional-text.md). A measurement
        // arrives on the reader thread through the model's client; the frame
        // above cut the renderer whose atlas answers it. Asserted through the
        // model's own client rather than the sheet, so an installation that
        // never reached the session fails here and not in an application's
        // layout. Proportional is the claim, and the grid face is the
        // fallback to tell it from: three `i` take three grid cells and fewer
        // in a face where `i` is narrow, six `W` take six and more.
        surface.drive.lockForRead()
        let measuredNarrow = surface.drive.measureProportionalRunCells([105, 105, 105])
        let measuredWide = surface.drive.measureProportionalRunCells([87, 87, 87, 87, 87, 87])
        surface.drive.unlockForRead()
        guard measuredNarrow >= 1, measuredWide >= 1 else {
            return failed("the model has no proportional-text measurer after a frame (answered \(measuredNarrow), \(measuredWide))")
        }
        guard measuredNarrow < 3, measuredWide > 6 else {
            return failed("the measurer answers in the grid face: iii=\(measuredNarrow) cells, WWWWWW=\(measuredWide)")
        }

        // The selection leg drives Core's facade end to end: select all,
        // read the text back through the wide-aware copy walk, draw a frame
        // whose options carry highlight spans, then clear.
        surface.selectAll(nil)
        guard surface.hasSelection else {
            return failed("select-all left no selection")
        }
        guard let text = surface.selectedText, text.contains("surface-smoke-frame-one") else {
            return failed("selected text misses the fed content")
        }
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("selected frame declined")
        }
        surface.clearSelection()
        guard !surface.hasSelection else {
            return failed("clear left a selection standing")
        }

        // The scale leg. A frame resolves its geometry against the layer's own
        // backing scale, and draws it from faces measured at that same scale:
        // geometry sourced from the atlas makes `atlasToDevice` the identity, and
        // faces left at the first scale draw a resampled raster on every display
        // that is not it.
        //
        // Two scales because one proves nothing here — the first measurement is
        // at 2, so an arm at 2 alone passes whichever source the frame used.
        guard renderer.lastFrameDeviceScale == 2, renderer.lastFrameAtlasScale == 2 else {
            return failed(
                "frame at scale 2 resolved \(renderer.lastFrameDeviceScale)"
                    + " against faces at \(renderer.lastFrameAtlasScale)"
            )
        }
        let scaled = CAMetalLayer()
        scaled.device = device
        scaled.pixelFormat = .bgra8Unorm
        scaled.frame = CGRect(x: 0, y: 0, width: 640, height: 384)
        scaled.contentsScale = 3
        scaled.drawableSize = CGSize(width: 1920, height: 1152)
        guard renderer.encodeFrame(for: surface, into: scaled) else {
            return failed("frame at scale 3 declined")
        }
        guard renderer.lastFrameDeviceScale == 3, renderer.lastFrameAtlasScale == 3 else {
            return failed(
                "frame at scale 3 resolved \(renderer.lastFrameDeviceScale)"
                    + " against faces at \(renderer.lastFrameAtlasScale)"
            )
        }
        // Back to the first layer. The scale arms above pass whether the
        // measurements are kept or replaced, so the count is what separates
        // them: a renderer that replaced has measured three times by here, and
        // remeasures on every frame a window spanning two displays draws.
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("frame back at scale 2 declined")
        }
        guard renderer.lastFrameDeviceScale == 2, renderer.lastFrameAtlasScale == 2 else {
            return failed(
                "frame back at scale 2 resolved \(renderer.lastFrameDeviceScale)"
                    + " against faces at \(renderer.lastFrameAtlasScale)"
            )
        }
        guard renderer.measuredScaleCount == 2 else {
            return failed("two scales drawn, \(renderer.measuredScaleCount) measurements held")
        }

        // The sharing leg. One SurfaceRenderer serves every surface in a window
        // — that is what the factory hands a host — so the state a second
        // surface must not inherit is the state a `TerminalRenderer` keeps
        // between frames: the retained grid, the instance streams, the capture,
        // and the cursor animator, which holds the in-flight slide and would
        // otherwise be ticked toward each surface's own cursor in turn.
        //
        // Asserted on the renderers rather than on pixels because this path has
        // no pixel oracle and the animator's effect is motion, which none of the
        // static-frame arms here can see. Identity is the property: a surface
        // that has drawn owns a renderer, and no two own the same one.
        guard let second = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no second surface session")
        }
        second.renderer = renderer
        let sharedLayer = CAMetalLayer()
        sharedLayer.device = device
        sharedLayer.pixelFormat = .bgra8Unorm
        sharedLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 384)
        sharedLayer.contentsScale = 2
        sharedLayer.drawableSize = CGSize(width: 1280, height: 768)
        feed(second.drive, "surface-smoke-second-surface\r\n")
        guard renderer.encodeFrame(for: second, into: sharedLayer) else {
            return failed("second surface's frame declined")
        }
        guard surface.frameRenderers.count == 2, second.frameRenderers.count == 1 else {
            return failed(
                "frame renderers: first surface \(surface.frameRenderers.count) (two scales),"
                    + " second \(second.frameRenderers.count) (one)"
            )
        }
        let firstAtTwo = surface.frameRenderers[2000]
        guard let firstAtTwo, let secondAtTwo = second.frameRenderers[2000] else {
            return failed("a surface that drew at scale 2 holds no renderer for it")
        }
        guard firstAtTwo !== secondAtTwo else {
            return failed("two surfaces share one frame renderer, and so share its cursor slide")
        }

        // The partial-frame leg. A first frame on a fresh target rebuilds — the
        // baseline has nothing to prove itself against — and a later frame that
        // changed one row must Load the retained pixels and re-read only that
        // row. Both halves are asserted because either alone passes for the
        // wrong reason: a path that never reuses satisfies the first, and one
        // that always reuses satisfies the second.
        guard renderer.encodeFrame(for: second, into: sharedLayer) else {
            return failed("second surface's steady frame declined")
        }
        guard renderer.didReuseLastFrame else {
            return failed(
                "a settled frame rebuilt in full: \(renderer.lastFrameDirtyRows)"
                    + " of \(renderer.lastFramePlannedRows) rows dirty"
            )
        }
        let settledDirty = renderer.lastFrameDirtyRows
        feed(second.drive, "one more line\r\n")
        guard renderer.encodeFrame(for: second, into: sharedLayer) else {
            return failed("second surface's dirtied frame declined")
        }
        guard renderer.didReuseLastFrame else {
            return failed("a frame that changed one row rebuilt the screen")
        }
        guard renderer.lastFrameDirtyRows > settledDirty else {
            return failed(
                "writing a line marked no more rows dirty than the settled frame:"
                    + " \(renderer.lastFrameDirtyRows) against \(settledDirty)"
            )
        }
        guard renderer.lastFrameDirtyRows < renderer.lastFramePlannedRows else {
            return failed(
                "one written line marked every row dirty: \(renderer.lastFrameDirtyRows)"
                    + " of \(renderer.lastFramePlannedRows)"
            )
        }

        // The scrollback leg. The surface's view offset must reach the frame:
        // the capture clamps it, the damage plan re-derives its rows from it,
        // and the boundary registration re-keys on it. Each hop is asserted
        // where a path that ignored the offset would still draw the tail.
        for line in 0..<60 {
            feed(second.drive, "scrollback-leg-line-\(line)\r\n")
        }
        // Read off the model under the lock, not off the published snapshot:
        // the snapshot republishes on the drain path, and a direct feed never
        // drains — the live surface's follow-tail always runs after a drain,
        // so production reads the published count coherently.
        let scrollableRows = scrollableRowCount(second.drive)
        guard scrollableRows > 0 else {
            return failed("sixty lines into a 24-row grid retained no scrollback")
        }
        // Settle the frame path so the scroll edge below is the only change.
        guard renderer.encodeFrame(for: second, into: sharedLayer),
            renderer.encodeFrame(for: second, into: sharedLayer),
            renderer.didReuseLastFrame
        else {
            return failed("the pre-scroll frames declined to settle")
        }
        second.setViewOffset(absolute: Int(Int32.max), limit: scrollableRows)
        guard second.viewOffset == scrollableRows else {
            return failed(
                "a saturating scroll clamped to \(second.viewOffset),"
                    + " not the reachable \(scrollableRows)"
            )
        }
        guard renderer.encodeFrame(for: second, into: sharedLayer) else {
            return failed("the scrolled frame declined")
        }
        guard renderer.lastFrameDirtyRows > 0 || !renderer.didReuseLastFrame else {
            return failed("a scroll to the top redrew nothing, so the frame ignored the offset")
        }
        guard second.registeredSyncViewOffset == second.viewOffset else {
            return failed(
                "the scroll edge left the boundary registration at offset"
                    + " \(String(describing: second.registeredSyncViewOffset))"
            )
        }

        // The held-viewport half: a selection pins the viewed rows, so the
        // tail growing underneath must move the offset by exactly the growth
        // — Core's compensation — rather than let the view drift toward the
        // tail one row per line of output.
        second.followTailOrHoldViewport(history: historyFacts(second.drive))
        second.selectAll(nil)
        let heldOffset = second.viewOffset
        let grownFrom = scrollableRows
        feed(second.drive, "tail-growth-one\r\ntail-growth-two\r\n")
        let grownTo = scrollableRowCount(second.drive)
        guard grownTo > grownFrom else {
            return failed("two fed lines grew no scrollback")
        }
        second.followTailOrHoldViewport(history: historyFacts(second.drive))
        guard second.viewOffset == heldOffset + (grownTo - grownFrom) else {
            return failed(
                "the held viewport moved to \(second.viewOffset), not"
                    + " \(heldOffset) compensated by \(grownTo - grownFrom)"
            )
        }
        // And the return edge: clearing the hold and snapping restores the
        // live tail.
        second.clearSelection()
        second.setViewOffset(absolute: 0, limit: grownTo)
        guard second.viewOffset == 0 else {
            return failed("the snap left the view at \(second.viewOffset)")
        }

        // The pointer-pipeline leg: press and drag as facts through the
        // session's ladder, no view event in sight. With no tracking mode on
        // the model, the encoder refuses and the facts fall through to the
        // local selection — the fall-through is itself the assertion, because
        // a ladder that consumed the press as a report would select nothing.
        var press = Ubiquitty.Runtime.TerminalSession.PointerFact()
        press.kind = .press
        press.button = .left
        press.row = 0
        press.column = 0
        let pressOutcome = surface.drive.pointerFact(press, selection: surface.selectionModel.session)
        guard pressOutcome.wasConsumed, pressOutcome.didOpenSelectionGesture else {
            return failed(
                "an unreported press did not open the local selection gesture"
                    + " (consumed \(pressOutcome.wasConsumed), opened \(pressOutcome.didOpenSelectionGesture),"
                    + " changed \(pressOutcome.didChangeSelection))"
            )
        }
        var drag = press
        drag.kind = .motion
        drag.isDragging = true
        drag.column = 10
        let dragOutcome = surface.drive.pointerFact(drag, selection: surface.selectionModel.session)
        guard dragOutcome.didChangeSelection else {
            return failed("a drag fact extended no selection")
        }
        guard let dragged = surface.selectedText, !dragged.isEmpty else {
            return failed("the fact-built selection reads back empty")
        }
        var release = drag
        release.kind = .release
        release.isDragging = false
        let releaseOutcome = surface.drive.pointerFact(release, selection: surface.selectionModel.session)
        guard releaseOutcome.wasConsumed else {
            return failed("the release fact fell past the open gesture")
        }
        // The close is asserted behaviourally: a drag arriving after the
        // release must extend nothing, or the session leaked its gesture
        // across the release edge.
        var straggler = drag
        straggler.column = 20
        let stragglerOutcome = surface.drive.pointerFact(straggler, selection: surface.selectionModel.session)
        guard !stragglerOutcome.didChangeSelection else {
            return failed("a drag after the release still extended the selection")
        }
        surface.clearSelection()

        // The search leg: the session's fold answers what a find bar shows —
        // the count, the active index, the compile failure — and the spans
        // reach the renderer through the model.
        feed(surface.drive, "needle-line\r\nfiller\r\n")
        let found = surface.searchScrollbackAndWait("needle")
        guard found.totalMatches == 1, found.activeIndex == 0 else {
            return failed("the search fold found \(found.totalMatches) (active \(found.activeIndex))")
        }
        let missing = surface.searchScrollbackAndWait("absent-text")
        guard missing.totalMatches == 0, missing.activeIndex == -1 else {
            return failed("an absent pattern matched")
        }
        let bad = surface.searchScrollbackAndWait("[unterminated", isRegex: true)
        guard bad.isPatternInvalid else {
            return failed("an unterminated pattern compiled")
        }
        surface.clearSearch()

        // The adoption leg — the tmux render-only pane's seam, driven with
        // two local sessions so no tmux server is needed: one surface owns a
        // model, a second adopts that model under the first one's lock, and
        // the adopted surface must read and render the owner's content. The
        // projection is the oracle because it walks the visible grid through
        // the same borrow the frame path takes.
        feed(surface.drive, "adoption-leg-content\r\n")
        guard let ownedTerminal = surface.drive.borrowTerminal() else {
            return failed("the owning drive lends no terminal")
        }
        let adopting = TerminalSurface.makeAdopting(
            terminal: unsafeBitCast(ownedTerminal, to: UnsafeMutableRawPointer.self),
            lockAddress: surface.drive.modelLockAddress(),
            rows: 24,
            columns: 80
        )
        guard let adopting else {
            return failed("the adopting surface declined to build")
        }
        adopting.noteAccessibilityContentChanged()
        guard adopting.accessibilityRebuiltText().contains("adoption-leg-content") else {
            return failed("the adopted surface reads its own anchor, not the owner's model")
        }
        adopting.renderer = renderer
        let adoptedLayer = CAMetalLayer()
        adoptedLayer.device = device
        adoptedLayer.pixelFormat = .bgra8Unorm
        adoptedLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 384)
        adoptedLayer.contentsScale = 2
        adoptedLayer.drawableSize = CGSize(width: 1280, height: 768)
        guard renderer.encodeFrame(for: adopting, into: adoptedLayer) else {
            return failed("the adopted surface's frame declined")
        }

        // The Tektronix leg. DECSET 38 hands the frame to the storage tube;
        // ESC ETX hands it back. The gate is the observable — no headless
        // arm compares Tek pixels — and each direction needs its own
        // assertion: a gate stuck on the tube draws no cell grid ever again,
        // and one that never engages draws Tek sessions as garbled text.
        // Vectors are fed so the
        // encoded frame carries a display list rather than proving an empty
        // pass encodes.
        // The republish after each feed is the drain's publication, which a
        // direct feed skips: the gate reads the published bit, and the mode
        // flip would otherwise wait for a drain this leg never runs.
        feed(surface.drive, "\u{1b}[?38h\u{1d}\u{20}\u{60}\u{40}\u{40}\u{7f}\u{60}")
        surface.drive.republishSnapshot()
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("the Tek frame declined")
        }
        guard renderer.didDrawTekFrame else {
            return failed("DECSET 38 drew the cell grid, not the storage tube")
        }
        feed(surface.drive, "\u{1b}\u{03}")
        surface.drive.republishSnapshot()
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("the post-Tek frame declined")
        }
        guard !renderer.didDrawTekFrame else {
            return failed("ESC ETX left the frame on the storage tube")
        }

        // The accessibility leg. VoiceOver reads the surface through Core's
        // one text projection; the wrapper's caching and its stale edge are
        // the only parts the host tests cannot see. The fed content must
        // appear in the value, and content fed after the read must appear in
        // the next one — a cache without the dirty edge answers the first
        // and fails the second forever.
        surface.noteAccessibilityContentChanged()
        let projected = surface.accessibilityRebuiltText()
        guard projected.contains("surface-smoke-frame-one") else {
            return failed("the accessibility value misses the fed content")
        }
        feed(surface.drive, "accessibility-stale-edge\r\n")
        surface.noteAccessibilityContentChanged()
        guard surface.accessibilityRebuiltText().contains("accessibility-stale-edge") else {
            return failed("content fed after a read never reached the next value")
        }
        guard surface.accessibilityRange(forLine: 0).location == 0 else {
            return failed("the first row's range does not start the projection")
        }

        // The hilite leg. Mode 1001 is xterm's documented hang — it blocks
        // its event loop until the host replies with XTHIMOUSE. This path
        // must never freeze: the press arms a bounded await, the deadline
        // aborts it with zero host output, and a release tears it down with
        // the end report. Each edge is asserted on the published snapshot,
        // because a stale await bit is what would hold the animation clock
        // armed forever.
        // The gesture is the ladder's: a press fact under mode 1001 is the
        // press report plus the armed await, and the release fact is the
        // end report plus the teardown.
        feed(surface.drive, "\u{1b}[?1001h")
        var hilitePress = Ubiquitty.Runtime.TerminalSession.PointerFact()
        hilitePress.kind = .press
        hilitePress.button = .left
        hilitePress.row = 1
        hilitePress.column = 1
        guard surface.drive.pointerFact(hilitePress, selection: surface.selectionModel.session).wasConsumed else {
            return failed("mode 1001 took no press")
        }
        guard surface.drive.readSnapshot().hiliteAwaiting else {
            return failed("the armed await never reached the published snapshot")
        }
        guard surface.drive.tickHiliteDeadline(100) else {
            return failed("a deadline long past aborted no await")
        }
        guard !surface.drive.readSnapshot().hiliteAwaiting else {
            return failed("the abort left the await published, holding the clock armed")
        }
        var secondHilitePress = hilitePress
        secondHilitePress.row = 2
        secondHilitePress.column = 2
        _ = surface.drive.pointerFact(secondHilitePress, selection: surface.selectionModel.session)
        guard surface.drive.readSnapshot().hiliteAwaiting else {
            return failed("a second press declined to arm")
        }
        var hiliteRelease = secondHilitePress
        hiliteRelease.kind = .release
        guard surface.drive.pointerFact(hiliteRelease, selection: surface.selectionModel.session).wasConsumed else {
            return failed("an in-flight gesture refused to finish")
        }
        guard !surface.drive.readSnapshot().hiliteAwaiting else {
            return failed("the finish left the await standing")
        }
        feed(surface.drive, "\u{1b}[?1001l")

        // The password-prompt leg. Mode 7401 is the application's way of
        // saying a secret comes next; the surface must show its lock, tell
        // the host, and keep a locally echoed keystroke off the screen —
        // SRM reset is the one state where the surface itself would draw it.
        // Then the mode's reset must take all three back. Before the shell
        // launches, so the only echo on screen is the surface's own: a pty
        // echoes a sent key back on its own schedule, and a cursor that moved
        // could not say which of the two moved it.
        let promptWitness = DeliveryWitness()
        surface.observer = promptWitness
        feed(surface.drive, "\u{1b}[12l\u{1b}[?7401h")
        surface.deliver([.screenDirty])
        guard surface.isPasswordPromptShown, !surface.passwordBadge.isHidden else {
            return failed("mode 7401 did not show the password lock")
        }
        guard promptWitness.passwordPromptChanges == [true] else {
            return failed("the host did not hear the password prompt begin: \(promptWitness.passwordPromptChanges)")
        }
        let columnBeforeSecret = cursorColumn(surface.drive)
        guard
            let secretKey = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "s",
                charactersIgnoringModifiers: "s",
                isARepeat: false,
                keyCode: 1
            )
        else {
            return failed("no key event for the secret")
        }
        _ = surface.sendKey(secretKey, eventType: .Press)
        guard cursorColumn(surface.drive) == columnBeforeSecret else {
            return failed("a keystroke under SRM reset echoed during a password prompt")
        }
        feed(surface.drive, "\u{1b}[?7401l")
        surface.deliver([.screenDirty])
        guard !surface.isPasswordPromptShown, promptWitness.passwordPromptChanges == [true, false] else {
            return failed("mode 7401 reset did not clear the password lock")
        }
        _ = surface.sendKey(secretKey, eventType: .Press)
        guard cursorColumn(surface.drive) == columnBeforeSecret + 1 else {
            return failed("local echo did not resume after the password prompt")
        }
        // Bytes sent other than as keys — a paste — echo under the same rule.
        let columnBeforePaste = cursorColumn(surface.drive)
        surface.transmitAsUserInputForTesting("ab")
        guard cursorColumn(surface.drive) == columnBeforePaste + 2 else {
            return failed("pasted text under SRM reset was not echoed locally")
        }
        feed(surface.drive, "\u{1b}[?7401h")
        surface.deliver([.screenDirty])
        let columnBeforeSecretPaste = cursorColumn(surface.drive)
        surface.transmitAsUserInputForTesting("cd")
        guard cursorColumn(surface.drive) == columnBeforeSecretPaste else {
            return failed("pasted text echoed during a password prompt")
        }
        feed(surface.drive, "\u{1b}[?7401l")
        surface.deliver([.screenDirty])
        feed(surface.drive, "\u{1b}[12h")
        guard firstFramePasswordBadgeLeg() else {
            return false
        }
        // The pipeline leg: a real shell, the ingest thread, and the drain
        // signal's hop back to main. The direct-feed frames above never cross
        // a thread, so they cannot see a dead deliver path — a surface whose
        // signal is unwired draws its first frame and then never hears the
        // session again, and every leg above still passes.
        let witness = DeliveryWitness()
        surface.observer = witness
        guard surface.launchShell() else {
            return failed("shell declined to launch")
        }
        // Every leg below sends a command line and reads what it printed, so
        // they need a shell that runs what it is sent. A shell still starting
        // has not claimed its terminal yet: the line discipline echoes what
        // arrives and the shell discards it on taking over, which puts the
        // command on screen having never run it.
        guard shellRunsWhatItIsSent(surface) else {
            return failed(
                "the launched shell never ran a line it was sent; \(screenReport(surface))"
            )
        }
        let updatesBeforeDrain = witness.screenUpdates
        surface.send("printf 'drain-signal-leg\\n'\n")
        let deadline = Date(timeIntervalSinceNow: 5)
        while witness.screenUpdates == updatesBeforeDrain, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard witness.screenUpdates > updatesBeforeDrain else {
            return failed("no screen delivery arrived from the shell session")
        }

        // The notification leg, through the shell for the reason the pipeline
        // leg gives. OSC 9 (iTerm), OSC 777;notify (urxvt) and OSC 99 (kitty)
        // reach a host only through `ShellClient::postNotification`, which no
        // Swift type can implement — cxx-interop does not subclass a C++ class
        // with virtual methods — so the session keeps a sink of its own and
        // reports its queue as an event. That report rides the drain signal,
        // which a direct feed never crosses.
        //
        // The three dialects the showcase's "Bell & notifications" entry emits,
        // verbatim, because what a host posts is the resolved pair rather than
        // what was parsed: OSC 9 and a metadata-less OSC 99 carry a body and no
        // title, and both promote it into the heading.
        let notifiedBefore = witness.notifications.count
        surface.send(
            #"printf '\033]9;OSC 9 carries a body and no title\033\\"#
                + #"\033]777;notify;OSC 777 notify;this body follows the title\033\\"#
                + #"\033]99;;OSC 99 carries a body and empty metadata\033\\'"#
                + "\n"
        )
        let notifyDeadline = Date(timeIntervalSinceNow: 5)
        while witness.notifications.count < notifiedBefore + 3, Date() < notifyDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        let banners = Array(witness.notifications.dropFirst(notifiedBefore))
        guard banners.count == 3 else {
            // The screen goes in the refusal because the count cannot say which
            // half failed. None arriving reads the same whether the shell never
            // ran the line, echoed it and stopped, or answered with an error —
            // and the grid is the only record here that tells those apart.
            return failed(
                "the three notification dialects reached the host as \(banners.count) banner(s): \(banners)"
                    + "; \(screenReport(surface))"
            )
        }
        guard banners[0] == Banner(title: "OSC 9 carries a body and no title", body: "") else {
            return failed("OSC 9 reached the host as \(banners[0])")
        }
        guard banners[1] == Banner(title: "OSC 777 notify", body: "this body follows the title") else {
            return failed("OSC 777;notify reached the host as \(banners[1])")
        }
        guard banners[2] == Banner(title: "OSC 99 carries a body and empty metadata", body: "") else {
            return failed("OSC 99 reached the host as \(banners[2])")
        }

        // The sync-frame leg, on the ingest thread where the boundary capture
        // lives: a direct feed is same-thread feed-then-draw and coherent by
        // construction, so only the drain path arms the capture. The
        // registration rode the encodes above; a 2026 frame through the shell
        // must land a frozen capture, the slot must not re-hand a drained
        // frame, and an encode must consume a waiting one.
        let promotedBeforeSync = surface.drive.syncFramePromoteCount
        let seenBeforeSync = surface.drive.syncClearSeenCount
        surface.send("printf '\\033[?2026hsync-frame-leg\\033[?2026l\\n'\n")
        // Waited on the parser reporting the frame, not on a screen update. The
        // shell echoes the line it was handed, so an update arrives before the
        // command has run at all — a wait on one returns while the block is still
        // in the future, and every count below then reads zero for a frame that
        // had not happened yet.
        let syncDeadline = Date(timeIntervalSinceNow: 5)
        while surface.drive.syncClearSeenCount == seenBeforeSync, Date() < syncDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard surface.drive.syncClearSeenCount > seenBeforeSync else {
            return failed(
                "the shell's 2026 block never reached the parser "
                    + "(clears seen \(surface.drive.syncClearSeenCount))"
            )
        }
        // The capture is the ingest thread's to arm and the frame link's to
        // present, and the link can tick between the delivery and this read:
        // then the slot is already drained and the promote count has moved.
        // Either says the boundary armed a capture; an empty slot with no
        // promote is the frame that was never captured.
        let isWaiting = surface.drive.takeSyncFrame() != nil
        guard isWaiting || surface.drive.syncFramePromoteCount > promotedBeforeSync else {
            return failed(
                "a completed 2026 boundary armed no sync capture "
                    + "(parser saw \(surface.drive.syncClearSeenCount), "
                    + "settle refused \(surface.drive.settlePublishRefusedCount), "
                    + "asked \(surface.drive.syncFrameBoundaryRequestCount), "
                    + "throttled \(surface.drive.syncFrameBoundaryThrottledCount), "
                    + "announced \(surface.drive.syncFrameBoundaryAnnounceCount), "
                    + "armed \(surface.drive.isSyncCaptureArmed), "
                    + "attempts \(surface.drive.syncFrameCaptureAttemptCount), "
                    + "published \(surface.drive.syncFramePublicationCount), "
                    + "no slot \(surface.drive.syncFrameNoSlotCount), "
                    + "stale replaced \(surface.drive.staleCaptureReplacedCount), "
                    + "promoted \(surface.drive.syncFramePromoteCount))"
            )
        }
        guard surface.drive.takeSyncFrame() == nil else {
            return failed("a drained slot re-handed its frame")
        }
        // Waited on the parser for the reason the first block is.
        let seenBeforeSecond = surface.drive.syncClearSeenCount
        surface.send("printf '\\033[?2026hsync-frame-two\\033[?2026l\\n'\n")
        let secondDeadline = Date(timeIntervalSinceNow: 5)
        while surface.drive.syncClearSeenCount == seenBeforeSecond, Date() < secondDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard surface.drive.syncClearSeenCount > seenBeforeSecond else {
            return failed("the shell's second 2026 block never reached the parser")
        }
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("sync-boundary frame declined")
        }
        guard surface.drive.takeSyncFrame() == nil else {
            return failed("the encode left the boundary frame undrained")
        }

        // The style leg. A host's styling must be the styling the frame
        // derives its uniforms from. The live route shares the assembled
        // options with the registration by construction, so the assertion
        // runs on the boundary route — the registered copy is the one a
        // capture far from any encode consumes, and a style change must
        // re-register or boundary frames keep the style it replaced.
        // Values, not presence: every field here is asserted against the
        // number set, because an agreement between two unfilled fields
        // passes over a style nobody carried.
        renderer.style = SurfaceStyle(
            backgroundOpacity: 0.5,
            defaultBackgroundRed: 0.25,
            defaultBackgroundGreen: 0.5,
            defaultBackgroundBlue: 0.75,
            shouldUnderlineLinks: true,
            linkColorRed: 0.125,
            linkColorGreen: 0.375,
            linkColorBlue: 0.625
        )
        waitForAdmittedFrame(surface)
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("styled frame declined")
        }
        // The damage drain saw no cell writes, so only the retained-target
        // stamp separates this from a frame that Loads pixels still wearing
        // the replaced styling.
        guard !renderer.didReuseLastFrame else {
            return failed("a restyled frame Loaded the target it painted under the replaced style")
        }
        // Waited on the parser for the reason the first block is.
        let seenBeforeStyled = surface.drive.syncClearSeenCount
        surface.send("printf '\\033[?2026hstyled-frame\\033[?2026l\\n'\n")
        let styledDeadline = Date(timeIntervalSinceNow: 5)
        while surface.drive.syncClearSeenCount == seenBeforeStyled, Date() < styledDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard surface.drive.syncClearSeenCount > seenBeforeStyled else {
            return failed("the shell's styled 2026 block never reached the parser")
        }
        guard let styled = surface.drive.takeSyncFrame() else {
            return failed("no boundary capture followed the style change")
        }
        let uniforms = styled.uniforms()
        guard abs(Double(uniforms.backgroundOpacity) - 0.5) < 0.001,
            abs(Double(uniforms.defaultBackground.x) - 0.25) < 0.001,
            abs(Double(uniforms.defaultBackground.y) - 0.5) < 0.001,
            abs(Double(uniforms.defaultBackground.z) - 0.75) < 0.001
        else {
            return failed(
                "the boundary capture derived uniforms from a style other than"
                    + " the set one: opacity \(uniforms.backgroundOpacity),"
                    + " background (\(uniforms.defaultBackground.x),"
                    + " \(uniforms.defaultBackground.y), \(uniforms.defaultBackground.z))"
            )
        }
        // The link half rides the same registration but not the uniforms —
        // the builder reads it per cell — so it is asserted off the capture's
        // own inputs, the same distance from the fill.
        let capturedLink = styled.linkColor()
        guard abs(Double(capturedLink.x) - 0.125) < 0.001,
            abs(Double(capturedLink.y) - 0.375) < 0.001,
            abs(Double(capturedLink.z) - 0.625) < 0.001
        else {
            return failed(
                "the boundary capture carried a link colour other than the set"
                    + " one: (\(capturedLink.x), \(capturedLink.y), \(capturedLink.z))"
            )
        }

        // A spacing change must reach boundary captures even when the drawable,
        // cell width, scale, and style stay fixed.
        let originalTypography = renderer.typography
        let originalPipelines = surface.frameRenderers.values.first?.pipelines
        guard originalPipelines != nil else { return failed("no pipelines before the font configuration change") }
        let captureScale = Double(styled.uniforms().cellSizeInPixels.y) / renderer.cellSize(for: surface).height
        for spacing in [originalTypography.lineSpacingInPoints + 4, originalTypography.lineSpacingInPoints] {
            var typography = originalTypography
            typography.lineSpacingInPoints = spacing
            renderer.adopt(pointSize: renderer.pointSize, typography: typography)
            waitForAdmittedFrame(surface)
            guard encodeAfterFontPreparation(renderer, for: surface, into: layer) else {
                let fontDeferred = surface.frameRenderers.values.contains(where: { $0.didDeferForFontPreparation })
                return failed(
                    "line-spacing frame declined: spacing=\(spacing), fontDeferred=\(fontDeferred), held=\(surface.drive.isFrameHeld), saturated=\(surface.drive.isDrainSaturated), staleDrawable=\(renderer.staleDrawableRefusals)"
                )
            }
            guard surface.frameRenderers.values.allSatisfy({ $0.pipelines === originalPipelines }) else {
                return failed("a font configuration change rebuilt the Metal pipelines")
            }
            let expectedHeight = renderer.cellSize(for: surface).height * captureScale
            let seenBeforeSpacing = surface.drive.syncClearSeenCount
            surface.send("printf '\\033[?2026hspacing-frame\\033[?2026l\\n'\n")
            let spacingDeadline = Date(timeIntervalSinceNow: 5)
            while surface.drive.syncClearSeenCount == seenBeforeSpacing, Date() < spacingDeadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            guard let spaced = surface.drive.takeSyncFrame() else {
                return failed("no boundary capture followed the spacing change")
            }
            guard abs(Double(spaced.uniforms().cellSizeInPixels.y) - expectedHeight) < 0.001 else {
                return failed("boundary capture kept row height \(spaced.uniforms().cellSizeInPixels.y), expected \(expectedHeight)")
            }
        }

        // The palette leg. The sink writes the model whole under the lock —
        // the round trip is read back off the terminal itself — and a
        // recolour that writes no cell must still invalidate the retained
        // target, or clean rows keep the colours the theme replaced.
        var indexed = [UInt8](repeating: 0, count: 768)
        indexed[3] = 200
        indexed[4] = 150
        indexed[5] = 100
        var defaults = [UInt8](repeating: 0, count: 9)
        defaults[0] = 250
        defaults[1] = 240
        defaults[2] = 230
        guard surface.applyPalette(indexedRGB: indexed, defaultsRGB: defaults) else {
            return failed("the palette apply refused well-formed tables")
        }
        guard surface.applyPalette(indexedRGB: [], defaultsRGB: defaults) == false else {
            return failed("the palette apply accepted a truncated table")
        }
        surface.drive.lockForRead()
        let appliedIndexOne = surface.drive.borrowTerminal()
            .map {
                (
                    $0.palette.indexed.1.red, $0.palette.indexed.1.green,
                    $0.palette.indexed.1.blue, $0.palette.defaultForeground.red
                )
            }
        surface.drive.unlockForRead()
        // Read back through the model's own conversion, not as the bytes that
        // went in. TermPalette's channels are 16-bit; asserting the raw byte
        // passes on a palette stored at 1/257 of the colour asked for, which is
        // what the screen would show.
        let narrowed = appliedIndexOne.map {
            (
                Ubiquitty.channel16To8($0.0), Ubiquitty.channel16To8($0.1),
                Ubiquitty.channel16To8($0.2), Ubiquitty.channel16To8($0.3)
            )
        }
        guard let narrowed, narrowed == (200, 150, 100, 250) else {
            return failed("the applied palette did not read back: \(String(describing: narrowed))")
        }
        waitForAdmittedFrame(surface)
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("post-palette frame declined")
        }
        guard !renderer.didReuseLastFrame else {
            return failed("a re-paletted frame Loaded the target painted with the replaced colours")
        }

        // The OSC 4 leg: the ingest-side twin of the host sink above. An
        // application that rewrites a palette entry recolours cells the
        // damage drain never saw, so only the model's own palette epoch
        // separates the next frame from one that Loads clean rows still
        // wearing the old colour. The frontend's windowClient is not
        // installed on this path, so the OSC handler's invalidate nudge
        // reaches nobody — the epoch is the whole mechanism.
        feed(surface.drive, "\u{1b}[38;5;33mosc4-recolour-leg\u{1b}[0m\r\n")
        waitForAdmittedFrame(surface)
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("pre-OSC4 frame declined")
        }
        feed(surface.drive, "\u{1b}]4;33;rgb:ff/00/ff\u{07}")
        // The write rides the ingest thread, so the frame the assertion is
        // about draws only once the model shows it: an encode that wins the
        // race captures the state before the recolour and reuses it, which
        // is correct for what it saw and proves nothing about the epoch.
        // The wait sleeps rather than spinning the run loop: the recolour
        // lands in the model from the ingest thread with no main-thread
        // delivery to wait for, and a run-loop turn can let the surface's own
        // frame clock encode a frame that already carries the new epoch —
        // after which the encode below reuses correctly and the leg reads a
        // pass as a failure.
        let osc4Deadline = Date(timeIntervalSinceNow: 5)
        var isRecolourApplied = false
        while !isRecolourApplied, Date() < osc4Deadline {
            surface.drive.lockForRead()
            isRecolourApplied = surface.drive.borrowTerminal().map { $0.palette.indexed.33.red == 0xFFFF } ?? false
            surface.drive.unlockForRead()
            if !isRecolourApplied {
                usleep(2000)
            }
        }
        guard isRecolourApplied else {
            return failed("the OSC 4 write never reached the model")
        }
        waitForAdmittedFrame(surface)
        guard renderer.encodeFrame(for: surface, into: layer) else {
            return failed("post-OSC4 frame declined")
        }
        guard !renderer.didReuseLastFrame else {
            return failed("an OSC 4 recolour Loaded the target painted with the replaced colour")
        }
        // The no-op discipline, which is what keeps the epoch from wedging
        // every frame into a rebuild: applications re-assert their palette
        // constantly, and an unchanged write must not move the epoch. Reuse
        // must RESUME — asserted as convergence within a few frames rather
        // than at an exact one, because a full plan re-arms the baseline on
        // its successor and the live shell's prompt output lands between
        // frames on its own schedule, stretching the chain by a frame. A
        // severed no-op guard fails this whatever the count: every re-assert
        // moves the epoch, and every frame replans full forever.
        feed(surface.drive, "\u{1b}]4;33;rgb:ff/00/ff\u{07}")
        var reusedAfterRepeat = false
        for _ in 0..<6 {
            waitForAdmittedFrame(surface)
            guard renderer.encodeFrame(for: surface, into: layer) else {
                return failed("repeated-OSC4 frame declined")
            }
            if renderer.didReuseLastFrame {
                reusedAfterRepeat = true
                break
            }
        }
        surface.drive.lockForRead()
        let epochAfterRepeat = surface.drive.borrowTerminal().map { $0.paletteEpoch }
        surface.drive.unlockForRead()
        guard reusedAfterRepeat else {
            return failed(
                "re-asserting an unchanged palette colour broke grid reuse"
                    + " (epoch \(String(describing: epochAfterRepeat)),"
                    + " dirty \(renderer.lastFrameDirtyRows)/\(renderer.lastFramePlannedRows))"
            )
        }

        // The status-line leg. DECSSDT's cells are assembled by Core and ride
        // the options as a borrow of surface-owned scratch; the observable is
        // the renderer's own, because the plan's reuse refusal reads the
        // model directly and would pass whether or not the cells arrived.
        // The boundary route shares the fill through the session, whose host
        // tests cover the assembly itself.
        // Converged over a few frames rather than asserted on one: the live
        // shell's prompt can land a DECSET-2026 boundary capture at any
        // moment, and an encode that consumes one takes the boundary path,
        // where this live-fill observable never moves.
        feed(surface.drive, "\u{1b}[1$~")
        var sawStatusRow = false
        for _ in 0..<6 {
            waitForAdmittedFrame(surface)
            guard renderer.encodeFrame(for: surface, into: layer) else {
                return failed("the status-line frame declined")
            }
            if renderer.lastFrameHadStatusRow {
                sawStatusRow = true
                break
            }
        }
        guard sawStatusRow else {
            return failed("an indicator status line reached no frame options")
        }
        feed(surface.drive, "\u{1b}[0$~")
        var droppedStatusRow = false
        for _ in 0..<6 {
            waitForAdmittedFrame(surface)
            guard renderer.encodeFrame(for: surface, into: layer) else {
                return failed("the status-line teardown frame declined")
            }
            if !renderer.lastFrameHadStatusRow {
                droppedStatusRow = true
                break
            }
        }
        guard droppedStatusRow else {
            return failed("a retired status line kept riding the frame options")
        }

        // The resize leg: a frame that crosses a cell boundary republishes
        // the grid and tells the observer the dimensions the shell was just
        // told; the same frame again publishes nothing — the guard is what
        // keeps live-resize from spamming the session with SIGWINCH.
        surface.setFrameSize(NSSize(width: 640, height: 384))
        guard let grown = witness.gridResizes.last, grown.rows > 1, grown.columns > 1 else {
            return failed("a sized frame republished no grid: \(witness.gridResizes)")
        }
        let resizeCount = witness.gridResizes.count
        surface.setFrameSize(NSSize(width: 640, height: 384))
        guard witness.gridResizes.count == resizeCount else {
            return failed("an unchanged frame size republished the grid")
        }

        // The restyle leg. A padding change moves every pixel while writing
        // no cell, so the host's restyle must refit the grid under the new
        // insets — fewer columns across the same width — and the next frame
        // must rebuild rather than Load the target drawn at the old inset; a
        // window that reads its padding only at launch keeps its text hard
        // against the old inset until a cursor move repaints it.
        // The resize leg's SIGWINCH makes the shell redraw, and that redraw
        // can hold the frame after the admission check and before the
        // capture. The block fed here opens a hold at exactly that point on
        // every run, the capture inside it is refused, and the smoke closes
        // the block itself; the frame is then drawn once the coherence rule
        // releases it, which the rule does within the block's one-second
        // budget, so the retry's bound is a hang guard rather than a wait.
        waitForAdmittedFrame(surface)
        feed(surface.drive, "\u{1b}[?2026h")
        let drewInsideBlock = renderer.encodeFrame(for: surface, into: layer)
        feed(surface.drive, "\u{1b}[?2026l")
        guard drewInsideBlock || encodeAfterFontPreparation(renderer, for: surface, into: layer) else {
            return failed(
                "pre-restyle frame declined after its block closed: decline=\(renderer.lastFrameDecline.rawValue), held=\(surface.drive.isFrameHeld), saturated=\(surface.drive.isDrainSaturated), staleDrawable=\(renderer.staleDrawableRefusals)"
            )
        }
        let columnsBeforeRestyle = grown.columns
        var widened = renderer.style
        widened.paddingLeftPoints += 120
        widened.paddingRightPoints += 120
        renderer.style = widened
        surface.restyle()
        guard let refit = witness.gridResizes.last, refit.columns < columnsBeforeRestyle else {
            return failed(
                "a wider padding left the grid at \(witness.gridResizes.last.map { $0.columns } ?? -1) columns of \(columnsBeforeRestyle)"
            )
        }
        waitForAdmittedFrame(surface)
        guard encodeAfterFontPreparation(renderer, for: surface, into: layer) else {
            return failed(
                "restyled frame declined: decline=\(renderer.lastFrameDecline.rawValue), held=\(surface.drive.isFrameHeld), saturated=\(surface.drive.isDrainSaturated), staleDrawable=\(renderer.staleDrawableRefusals)"
            )
        }
        guard !renderer.didReuseLastFrame else {
            return failed("a frame after a padding change Loaded the target drawn at the old inset")
        }
        widened.paddingLeftPoints -= 120
        widened.paddingRightPoints -= 120
        renderer.style = widened
        surface.restyle()

        // The focus leg. The surface starts focused — a headless host draws
        // the cursor a lone terminal would — so the resign edge fires first,
        // and each edge must reach the observer exactly once.
        guard surface.resignFirstResponder(), surface.becomeFirstResponder() else {
            return failed("the responder edges refused")
        }
        guard witness.focusChanges == [false, true], surface.isSurfaceFocused else {
            return failed("focus edges reached the observer as \(witness.focusChanges)")
        }

        // The clock leg. Core's capture refuses to sample a clock — the tick
        // arrives from the session's read, pinned by the harness here so the
        // tick a frame really carried is assertable exactly, on both routes:
        // the live fill's options and the boundary capture the ingest thread
        // resolves for itself.
        setenv("UBIQUITTY_FAKE_TICKS", "1234", 1)
        waitForAdmittedFrame(surface)
        guard encodeAfterFontPreparation(renderer, for: surface, into: layer) else {
            return failed("pinned-tick frame declined: \(renderer.lastFrameDecline.rawValue)")
        }
        guard renderer.lastFrameBlinkTicks == 1234 else {
            return failed("the live route's options carried tick \(renderer.lastFrameBlinkTicks), not the pin")
        }
        surface.send("printf '\\033[?2026hclock-leg\\033[?2026l\\n'\n")
        // Polled on the boundary slot itself, not on screen updates: the
        // resize leg's SIGWINCH redraw lands updates of its own, and a poll
        // satisfied by one reads the slot before the boundary fills it.
        let clockDeadline = Date(timeIntervalSinceNow: 5)
        var clocked: Ubiquitty.Rendering.FrameCapture?
        while clocked == nil, Date() < clockDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            clocked = surface.drive.takeSyncFrame()
        }
        guard let clocked else {
            return failed("no boundary capture followed the pinned-tick feed")
        }
        guard clocked.blinkTicks() == 1234 else {
            return failed("the boundary capture carried tick \(clocked.blinkTicks()), not the pin")
        }
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)

        // The animation-clock leg, on the arm, disarm and retract edges —
        // all a headless test can see of a schedule whose effect is motion.
        // SGR 5 blink on screen must arm the repaint timer through the
        // production updateLayer path; a screen without it must leave the
        // timer down, which is what keeps a quiet terminal at zero frames.
        // The grid's blink hint is sticky by design (sticky-true is safe),
        // and the schedule consults the live-screen reading beside it, so
        // the timer stands down on a blinkless screen twice over: before any
        // blink is written, and again once the content is erased.
        // Each edge is polled to convergence with the frame path re-run per
        // iteration: the feed rides the ingest thread, and the assertion is
        // about the surface's timer reflecting the model, not delivery.
        // The shell from the legs above is still running, and its prompt lands
        // whenever its last command finishes. These edges are fed directly, so a
        // prompt arriving between a feed and its reading overwrites the cells the
        // reading is about — the blink text goes onto the row the prompt then
        // claims, and the live-screen reading correctly finds no blink cell.
        // Settled first: the screen is left quiet, so the only writer from here is
        // this test.
        var quietSince = witness.screenUpdates
        let settleDeadline = Date(timeIntervalSinceNow: 5)
        while Date() < settleDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.15))
            if witness.screenUpdates == quietSince {
                break
            }
            quietSince = witness.screenUpdates
        }
        feed(surface.drive, "\u{1b}[?25l")
        let disarmDeadline = Date(timeIntervalSinceNow: 5)
        while surface.isAnimationClockArmed, Date() < disarmDeadline {
            surface.updateLayer()
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard !surface.isAnimationClockArmed else {
            return failed("a hidden cursor on a blinkless screen left the animation clock armed")
        }
        feed(surface.drive, "\u{1b}[5mblinking\u{1b}[0m")
        let armDeadline = Date(timeIntervalSinceNow: 5)
        while !surface.isAnimationClockArmed, Date() < armDeadline {
            surface.updateLayer()
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard surface.isAnimationClockArmed else {
            let snapshot = surface.drive.readSnapshot()
            let verdict = surface.drive.nextAnimationDelay()
            return failed(
                "blink content armed no animation clock "
                    + "(blink hint \(snapshot.hasBlinkHint), "
                    + "blink cell on screen \(snapshot.hasBlinkCellOnScreen), "
                    + "cursor visible \(snapshot.isCursorVisible), "
                    + "verdict animating \(verdict.hasAnimatingContent), "
                    + "delay \(verdict.delaySeconds), "
                    + "frames drawn \(surface.drawnFrameCount))"
            )
        }
        // The retract edge: the hint stays armed, but erasing the content
        // must stand the timer down again — the consult of the live-screen
        // reading is what keeps a session that once blinked from paying a
        // frame per phase step for the life of the grid.
        feed(surface.drive, "\u{1b}[H\u{1b}[2J")
        let retractDeadline = Date(timeIntervalSinceNow: 5)
        while surface.isAnimationClockArmed, Date() < retractDeadline {
            surface.updateLayer()
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard !surface.isAnimationClockArmed else {
            let snapshot = surface.drive.readSnapshot()
            let verdict = surface.drive.nextAnimationDelay()
            return failed(
                "erasing the blink content left the animation clock armed "
                    + "(blink cell on screen \(snapshot.hasBlinkCellOnScreen), "
                    + "blink hint \(snapshot.hasBlinkHint), "
                    + "images animating \(snapshot.imagesAnimating), "
                    + "hilite awaiting \(snapshot.hiliteAwaiting), "
                    + "cursor visible \(snapshot.isCursorVisible), "
                    + "verdict animating \(verdict.hasAnimatingContent), "
                    + "link running \(surface.isDrivingFramesForTesting))"
            )
        }

        // The modifier leg. A flags-changed event answers neither the repeat
        // nor the character properties, and asking aborts the process, so the
        // leg either returns or dies inside the call — which is the outcome it
        // exists to catch. Measured: 134 without the guard, 0 with it.
        guard
            let modifierDown = NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 55
            ),
            let modifierUp = NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 55
            )
        else {
            return failed("no flags-changed event")
        }
        surface.flagsChanged(with: modifierDown)
        surface.flagsChanged(with: modifierUp)
        // A key event still reads its repeat flag, so the guard cannot be a
        // blanket refusal.
        guard
            let repeated = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: true,
                keyCode: 0
            )
        else {
            return failed("no key event")
        }
        guard surface.sendKey(repeated, eventType: .Press) else {
            return failed("a repeated key wrote nothing under a host that takes repeats")
        }

        // An idle terminal with a blinking cursor asks for a frame when the
        // blink next changes, not sixty times a second. The cursor's alpha
        // moves about twice a second, and a clock firing per frame to move it
        // is the whole cost of a quiet terminal.
        //
        // The surface has to be focused and in a window for this to be the
        // question: an unfocused cursor does not blink, so an offscreen
        // surface answers the same either way and asserts nothing.
        do {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 384),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(surface)
            surface.frame = window.contentView?.bounds ?? .zero
            window.makeFirstResponder(surface)
            defer { surface.removeFromSuperview() }
            // DECTCEM on: nothing in this scenario has shown a cursor, and a
            // hidden one does not blink — the condition under test would not
            // arise and the leg would pass whatever the clock does.
            feed(surface.drive, "\u{1b}[?25h")
            surface.serviceIngestEvents()

            let delay = surface.animationDelayForTesting()
            guard delay > 1.0 / 20.0 else {
                return failed(
                    "an idle blinking cursor scheduled a repaint in \(delay)s,"
                        + " which is a frame-rate loop rather than a blink cadence"
                )
            }
        }

        guard pasteLegs(device: device, library: library) else {
            return false
        }

        guard clipboardScopeLegs() else {
            return false
        }

        guard consentPromptLegs() else {
            return false
        }

        guard presenceBadgeLegs() else {
            return false
        }

        guard hintLegs() else {
            return false
        }

        return passed(
            "the surface's layer draws, frames drew, the reuse legs held, the clock moved,"
                + " the three notification dialects reached the host as resolved banners,"
                + " keys encoded, the paste action reached a hosted surface, the clipboard"
                + " scope badge reports what it is told, the consent prompt names the"
                + " action it is asking about, the presence badge appears only when"
                + " somebody else is on the session, a prompt fed before a capture's"
                + " first frame gets the lock a prompt fed after a frame gets, and a"
                + " swallowed drag teaches its reach-through modifier once per gesture"
                + " within Core's budget"
        )
    }

    /// The lock on a capture's first frame.
    ///
    /// The badge stands in the submitted frame's cell, which a capture has
    /// only once it has drawn a frame; the snapshot arm feeds a whole case
    /// and draws once, so every password golden is a prompt fed before the
    /// first frame. Such a prompt must get the lock a prompt fed after a
    /// frame gets: the same badge frame, a row high and two cells wide, ink
    /// in it, and the same picture byte for byte. A badge laid out before the
    /// frame has no cell, keeps an empty frame, and composites nothing.
    ///
    /// - Returns: Whether the one-frame capture matched the two-frame one.
    private static func firstFramePasswordBadgeLeg() -> Bool {
        let command = "$ sudo make install\r\n"
        let prompt = "\u{1b}[?7401hPassword: "
        let configuration = Ubiquitty.Preferences.values().pointee
        guard let reference = SurfaceSnapshot(rows: 5, columns: 40, contentScale: 2, configuration: configuration),
            let subject = SurfaceSnapshot(rows: 5, columns: 40, contentScale: 2, configuration: configuration)
        else {
            return failed("no capture for the first-frame lock")
        }
        reference.surface.setSurfaceFocused(true)
        subject.surface.setSurfaceFocused(true)

        // The reference: a frame before the prompt, then the prompt.
        reference.feed(std.string(command))
        guard reference.pixels() != nil else {
            return failed("the reference capture drew no frame before the prompt")
        }
        reference.feed(std.string(prompt))
        guard let referencePixels = reference.pixels() else {
            return failed("the reference capture drew no prompt frame")
        }
        let referenceBadge = reference.surface.passwordBadge.frame
        let cell = reference.renderer.drawnCellSize(for: reference.surface)
        guard reference.surface.isPasswordPromptShown, cell.width > 0, cell.height > 0,
            referenceBadge.height == cell.height, referenceBadge.width == cell.width * 2
        else {
            return failed("the reference lock is not a row high and two cells wide: \(referenceBadge) beside a \(cell) cell")
        }

        // The subject: the same bytes, the prompt among them, in one frame.
        subject.feed(std.string(command + prompt))
        guard let subjectPixels = subject.pixels() else {
            return failed("the one-frame capture drew nothing")
        }
        guard subject.surface.isPasswordPromptShown else {
            return failed("mode 7401 fed before the first frame showed no lock")
        }
        let subjectBadge = subject.surface.passwordBadge.frame
        guard subjectBadge == referenceBadge else {
            return failed("a prompt fed before the first frame placed the lock at \(subjectBadge), not \(referenceBadge)")
        }
        guard
            hasInk(
                subjectPixels,
                in: subjectBadge,
                widthInPixels: subject.texture.width,
                heightInPixels: subject.texture.height,
                contentScale: 2
            )
        else {
            return failed("the lock's cells hold no ink on the first frame")
        }
        guard subjectPixels == referencePixels else {
            return failed("a prompt fed before the first frame drew a different picture from one fed after a frame")
        }
        return true
    }

    /// Whether any pixel under `rect` differs from the frame's bottom-right
    /// pixel, the corner of a cell the capture's bytes never wrote, which
    /// carries the plain background.
    ///
    /// - Parameters:
    ///   - pixels: A capture's BGRA bytes, the top row first.
    ///   - rect: A view rectangle in points, y down.
    ///   - widthInPixels: The capture's width.
    ///   - heightInPixels: The capture's height.
    ///   - contentScale: The capture's pixels per point.
    /// - Returns: Whether the rectangle holds ink.
    private static func hasInk(_ pixels: Data, in rect: CGRect, widthInPixels: Int, heightInPixels: Int, contentScale: Double) -> Bool {
        let count = widthInPixels * heightInPixels * 4
        guard count > 0, pixels.count >= count else { return false }
        let background = pixels[pixels.startIndex + count - 4..<pixels.startIndex + count]
        let left = max(0, Int((rect.minX * contentScale).rounded(.down)))
        let right = min(widthInPixels, Int((rect.maxX * contentScale).rounded(.up)))
        let top = max(0, Int((rect.minY * contentScale).rounded(.down)))
        let bottom = min(heightInPixels, Int((rect.maxY * contentScale).rounded(.up)))
        guard left < right, top < bottom else { return false }
        for row in top..<bottom {
            for column in left..<right {
                let index = pixels.startIndex + (row * widthInPixels + column) * 4
                if pixels[index..<index + 4] != background { return true }
            }
        }
        return false
    }

    /// The teaching hint: Core decides, this arm forwards a changed answer.
    ///
    /// Three claims, each on the wire rather than on the rule. A swallowed
    /// drag under an application's mouse mode reaches the observer as Core's
    /// words, once per gesture and never past Core's budget. The clock is
    /// Core's: moving the pinned tick past the interval makes the next ask
    /// answer nothing, and the observer hears that withdrawal once. And the
    /// lock lesson follows the grab report, not a timer of this arm's.
    ///
    /// - Returns: Whether the legs held.
    @MainActor
    private static func hintLegs() -> Bool {
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no surface for the hint legs")
        }
        let witness = HintRecorder()
        surface.observer = witness
        // Mode 1002, not 1000: under 1000 motion is never encoded, so a drag
        // falls through to the local selection, no lesson is owed, and a leg
        // written against it passes while testing nothing. Button-event
        // tracking is the mode that swallows the gesture.
        feed(surface.drive, "\u{1b}[?1002h")
        guard surface.drive.withTerminal({ Ubiquitty.Mouse.tracksPointer($0) }) == true else {
            return failed("the application's mouse mode never reached the model")
        }
        let taught = [
            String(cString: Ubiquitty.Input.hintText(.selectWithShift, .mac))
        ]
        // Drags a swallowed gesture from (5,5) past the click wobble, then
        // further, then releases: one lesson on the way in, nothing more.
        func swallowOneGesture(on target: TerminalSurface, hasModifierKeys: Bool = true) {
            var press = Ubiquitty.Runtime.TerminalSession.PointerFact()
            press.kind = .press
            press.button = .left
            press.row = 5
            press.column = 5
            target.forward(press)
            var drag = press
            drag.kind = .motion
            drag.isDragging = true
            drag.column = 9
            drag.hasModifierKeys = hasModifierKeys
            target.forward(drag)
            var further = drag
            further.column = 20
            target.forward(further)
            var release = further
            release.kind = .release
            release.isDragging = false
            target.forward(release)
        }
        // The run pins the clock at tick 0; each gesture happens on a fresh
        // pin past the last lesson's interval, so a lesson fades between
        // gestures and the observer hears every raise and every fade. Four
        // gestures against a budget of three.
        let interval = Ubiquitty.Input.transientHintTicks
        var expected: [String] = []
        for gesture in 1...4 {
            setenv("UBIQUITTY_FAKE_TICKS", String(UInt32(gesture - 1) * (interval + 20)), 1)
            swallowOneGesture(on: surface)
            if gesture <= Int(Ubiquitty.Input.hintMaxShows) {
                guard let lesson = witness.changes.last, !lesson.isEmpty, taught.contains(lesson) else {
                    return failed("gesture \(gesture) taught \(witness.changes.last ?? "nothing")")
                }
                expected.append(lesson)
            }
            guard witness.changes == expected else {
                return failed("gesture \(gesture) left the observer hearing \(witness.changes), not \(expected)")
            }
            guard surface.drive.hintTicksUntilExpiry() == (gesture <= Int(Ubiquitty.Input.hintMaxShows) ? interval : 0) else {
                return failed("gesture \(gesture) left \(surface.drive.hintTicksUntilExpiry()) ticks on the clock")
            }
            // Past the interval the next ask answers nothing, and the
            // observer hears the withdrawal exactly once.
            setenv("UBIQUITTY_FAKE_TICKS", String(UInt32(gesture - 1) * (interval + 20) + interval), 1)
            surface.refreshHint()
            surface.refreshHint()
            if gesture <= Int(Ubiquitty.Input.hintMaxShows) {
                expected.append("")
            }
            guard witness.changes == expected else {
                return failed("after gesture \(gesture) faded the observer heard \(witness.changes), not \(expected)")
            }
        }
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)

        // The keyless seam, end to end: a drag whose fact carries no modifier
        // keys is taught nothing, through every hop between the fact and the
        // observer. The Core case covers the rule; this covers the wire.
        guard let keyless = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no surface for the keyless leg")
        }
        let keylessWitness = HintRecorder()
        keyless.observer = keylessWitness
        feed(keyless.drive, "\u{1b}[?1002h")
        swallowOneGesture(on: keyless, hasModifierKeys: false)
        guard keylessWitness.changes.isEmpty else {
            return failed("a reader with no modifier keys was taught '\(keylessWitness.changes[0])'")
        }

        // The lock's lesson, through the grab report rather than the lock:
        // taking the lock in a smoke would hide and dissociate the real
        // cursor of whoever is running it. The report is the arm's whole
        // part; the words, the budget and the withdrawal are Core's.
        guard let captured = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no surface for the lock leg")
        }
        let lockWitness = HintRecorder()
        captured.observer = lockWitness
        let release = String(cString: Ubiquitty.Input.hintText(.pointerLockRelease, .mac))
        captured.reportPointerLockGrab(.held)
        guard lockWitness.changes == [release] else {
            return failed("capturing the pointer told the observer \(lockWitness.changes), not the release lesson")
        }
        guard captured.drive.hintTicksUntilExpiry() == 0 else {
            return failed("the lock's lesson was given a clock; it must end with the grab")
        }
        captured.reportPointerLockGrab(.released)
        guard lockWitness.changes == [release, ""] else {
            return failed("releasing the pointer told the observer \(lockWitness.changes)")
        }

        // The break-out chord, through Core's clock. The arm reports keys and
        // books the wake-up Core names; the arming rule, the hold and the mode
        // clear are the ladder's and the session's. Pinned ticks stand in for
        // the wake-up, so the hold is asserted at its exact boundary.
        guard let trapped = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no surface for the chord leg")
        }
        feed(trapped.drive, "\u{1b}[?7403h")
        guard trapped.drive.readSnapshot().mouseRelativePointerLockActive else {
            return failed("the pointer-lock mode never reached the model")
        }
        guard trapped.drive.pointerLockVerdict(isSurfaceFocused: true) == .hold,
            trapped.drive.pointerLockVerdict(isSurfaceFocused: false) == .release
        else {
            return failed("the lock verdict did not follow the mode and the focus")
        }
        var chord = Ubiquitty.Input.PointerLockKeyState()
        chord.isControlHeld = true
        chord.isCommandHeld = true
        // Without a grab a ⌃⌘ is a shortcut, and the chord must not arm.
        trapped.drive.notePointerLockChord(chord)
        guard trapped.drive.pointerLockChordTicksUntilDeadline() == 0 else {
            return failed("the chord armed with no grab to release")
        }
        trapped.drive.notePointerLockGrab(.held)
        trapped.drive.notePointerLockChord(chord)
        let hold = Ubiquitty.Input.pointerLockBreakoutHoldTicks
        guard trapped.drive.pointerLockChordTicksUntilDeadline() == hold else {
            return failed("the chord's wake-up is \(trapped.drive.pointerLockChordTicksUntilDeadline()) ticks, not the hold of \(hold)")
        }
        setenv("UBIQUITTY_FAKE_TICKS", String(hold - 1), 1)
        guard trapped.drive.tickPointerLockChord(chord) == .keep else {
            return failed("a tick short of the hold broke out")
        }
        setenv("UBIQUITTY_FAKE_TICKS", String(hold), 1)
        guard trapped.drive.tickPointerLockChord(chord) == .breakOut else {
            return failed("the hold elapsed with the chord down and the grab was kept")
        }
        guard !trapped.drive.readSnapshot().mouseRelativePointerLockActive else {
            return failed("a break-out left the mode set, so a hung application could re-trap the pointer")
        }
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)

        // The accessory that shows it: text shows, the empty text withdraws.
        let bar = ChromeAccessoryBar(scope: .window, heightInPoints: ChromeAccessoryBar.titleRowHeightInPoints)
        let accessory = HintAccessory.install(in: bar)
        guard accessory.isHidden else {
            return failed("the hint accessory arrived showing")
        }
        accessory.show(release)
        guard !accessory.isHidden, accessory.stringValue == release else {
            return failed("a hint did not show its text")
        }
        accessory.show("")
        guard accessory.isHidden else {
            return failed("the empty text left the accessory showing")
        }
        return true
    }

    /// Records every change of hint text a surface reported.
    private final class HintRecorder: TerminalSurfaceObserver {
        var changes: [String] = []

        func terminalSurface(_: TerminalSurface, didChangeHint text: String) {
            changes.append(text)
        }
    }

    /// The presence badge: it appears when somebody else is on the session,
    /// stays away when nobody is, and offers a revoke only where an agent
    /// holds the grant it would take away.
    ///
    /// A badge that showed for a session the user is alone on would be noise on
    /// every window, and noise on every window is how a person stops reading the
    /// one that matters. The menu is the other half: each scope is an
    /// independent revoke, and one offered against a grant nobody holds tells
    /// the reader they did something when they did not.
    ///
    /// - Returns: Whether the legs held.
    @MainActor
    private static func presenceBadgeLegs() -> Bool {
        let bar = ChromeAccessoryBar(scope: .window, heightInPoints: ChromeAccessoryBar.titleRowHeightInPoints)
        let indicator = SessionPresenceIndicator.install(in: bar)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(bar)

        func attendee(
            clientID: UInt32,
            isHuman: Bool,
            isQUIC: Bool = false,
            isSelf: Bool = false,
            grantScope: UInt8 = 0,
            process: String = "",
            label: String = ""
        ) -> RuntimeDrive.Attendee {
            RuntimeDrive.Attendee(
                attachmentID: String(format: "%032llx", UInt64(clientID)),
                clientID: clientID,
                isHuman: isHuman,
                isQUIC: isQUIC,
                isSelf: isSelf,
                grantScope: grantScope,
                process: process,
                grantIdentity: isHuman ? "" : "token:agent-\(clientID)",
                label: label
            )
        }

        guard indicator.isHidden, indicator.otherAttendeeCount == 0 else {
            return failed("the presence badge is showing before any session reported a roster")
        }

        let me = attendee(clientID: 1, isHuman: true, isSelf: true)
        SessionPresenceIndicator
            .report([me, attendee(clientID: 2, isHuman: true), attendee(clientID: 3, isHuman: true)], for: window)
        guard indicator.otherAttendeeCount == 2, !indicator.isHidden, indicator.image != nil else {
            return failed(
                "the presence badge did not appear for two other attendees"
                    + " (count \(indicator.otherAttendeeCount), hidden \(indicator.isHidden))"
            )
        }
        guard indicator.agentCount == 0, !indicator.isEnabled else {
            return failed("a roster of people alone offered something to press")
        }
        guard titles(of: indicator.rosterMenu()).contains("No Agents Connected") else {
            return failed("a roster of people alone did not say there is nothing to revoke")
        }

        // An agent on a session-scoped grant: the badge counts it, and its
        // submenu offers the session grant and not the persisted one.
        let sessionAgent = attendee(
            clientID: 7,
            isHuman: false,
            grantScope: RuntimeDrive.Attendee.Grant.session.rawValue,
            process: "/usr/local/bin/ubq",
            label: "Test Agent"
        )
        SessionPresenceIndicator.report([me, sessionAgent], for: window)
        guard indicator.agentCount == 1, indicator.isEnabled, indicator.title.contains("1") else {
            return failed(
                "the badge did not become the agent pill"
                    + " (agents \(indicator.agentCount), title \(indicator.title))"
            )
        }
        let menu = indicator.rosterMenu()
        guard let agentRow = menu.items.first(where: { $0.title.contains("Test Agent") }), let scopes = agentRow.submenu else {
            return failed("the roster menu has no row for the attached agent")
        }
        let scopeTitles = titles(of: scopes)
        guard scopeTitles.contains("Disconnect Now"), scopeTitles.contains("Revoke Session Access") else {
            return failed("the agent's submenu is missing a revoke scope (\(scopeTitles))")
        }
        guard !scopeTitles.contains("Stop Always Allowing This Agent") else {
            return failed("a session-granted agent was offered a persisted grant to drop")
        }
        guard titles(of: menu).contains("Disconnect All Agents") else {
            return failed("the roster menu cannot disconnect every agent at once")
        }
        guard menu.items.first(where: { $0.title.hasPrefix("You") })?.isEnabled == false else {
            return failed("the reader's own row offered a revoke")
        }

        // Stable attachments and daemon grant keys are distinct from display facts.
        var sent: [(RuntimeDrive.RevokeAction, String, String)] = []
        indicator.revoke = { action, clientID, identity in sent.append((action, clientID, identity)) }
        scopes.performActionForItem(at: scopeTitles.firstIndex(of: "Disconnect Now") ?? 0)
        scopes.performActionForItem(at: scopeTitles.firstIndex(of: "Revoke Session Access") ?? 0)
        menu.performActionForItem(at: titles(of: menu).firstIndex(of: "Disconnect All Agents") ?? 0)
        guard sent.count == 3 else {
            return failed("the roster menu sent \(sent.count) revokes for three chosen items")
        }
        guard sent[0].0 == .disconnectNow, sent[0].1 == sessionAgent.attachmentID, sent[0].2.isEmpty else {
            return failed("Disconnect Now did not name the connection alone")
        }
        guard sent[1].0 == .clearSessionGrant, sent[1].1.isEmpty, sent[1].2 == "token:agent-7" else {
            return failed("the session revoke did not use the separately verified daemon grant key")
        }
        guard sent[2].0 == .disconnectAllAgents else {
            return failed("Disconnect All Agents sent something else")
        }

        // An agent the daemon remembers offers the persisted grant instead.
        let alwaysAgent = attendee(
            clientID: 8,
            isHuman: false,
            grantScope: RuntimeDrive.Attendee.Grant.always.rawValue,
            process: "/usr/local/bin/ubq"
        )
        SessionPresenceIndicator.report([me, alwaysAgent], for: window)
        let persisted = indicator.rosterMenu()
        guard let persistedRow = persisted.items.first(where: { $0.title.contains("ubq") }),
            let persistedScopes = persistedRow.submenu
        else {
            return failed("an agent with no label is not named by its verified executable")
        }
        let persistedTitles = titles(of: persistedScopes)
        guard persistedTitles.contains("Stop Always Allowing This Agent"), !persistedTitles.contains("Revoke Session Access") else {
            return failed("a persisted grant was not the scope offered (\(persistedTitles))")
        }

        // The carrier is the row's, and a network peer is never called local:
        // the reader deciding whether to revoke is reading this to tell a
        // window of their own from something on the network.
        let quicPerson = attendee(clientID: 21, isHuman: true, isQUIC: true)
        let quicAgent = attendee(
            clientID: 22,
            isHuman: false,
            isQUIC: true,
            grantScope: RuntimeDrive.Attendee.Grant.session.rawValue,
            process: "/usr/local/bin/ubq",
            label: "Remote Agent"
        )
        SessionPresenceIndicator.report([me, quicPerson, quicAgent], for: window)
        let carriers = titles(of: indicator.rosterMenu())
        guard carriers.contains("Another window (quic)") else {
            return failed("a person attached over QUIC was not marked as one (\(carriers))")
        }
        guard carriers.contains("Remote Agent (quic)") else {
            return failed("an agent attached over QUIC was not marked as one (\(carriers))")
        }
        guard !carriers.contains(where: { $0.hasSuffix("(local)") && $0 != "You (local)" }) else {
            return failed("a QUIC attendee was shown as local (\(carriers))")
        }

        // Alone again: the badge goes away rather than lingering at zero, which
        // would say somebody is watching a session nobody is on.
        SessionPresenceIndicator.report([me], for: window)
        guard indicator.isHidden, indicator.image == nil else {
            return failed("the presence badge stayed after the others left")
        }

        // Another window's roster is not this window's. Two sessions have two
        // answers, and showing one user the other's would be acted on.
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        SessionPresenceIndicator.report([me, attendee(clientID: 9, isHuman: true)], for: other)
        guard indicator.isHidden, indicator.otherAttendeeCount == 0 else {
            return failed("the presence badge took another window's roster")
        }
        return true
    }

    /// The titles a menu offers, in order.
    ///
    /// - Parameter menu: The menu to read.
    /// - Returns: One title per item, separators included as empty strings.
    @MainActor
    private static func titles(of menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    /// The consent prompt's words, which are the security-bearing part of it.
    ///
    /// Two claims, and both are about what the person reading the sheet is
    /// actually authorising. The question must name the ACTION — approving a
    /// terminate as though it were an attach hands over the session, and the
    /// only thing standing between those is this sentence. And the agent's
    /// self-chosen label must be attributed rather than stated, because an
    /// agent picks it: a prompt reading "Backup Helper is asking" would let
    /// the agent write its own credentials into the question.
    ///
    /// The buttons and the sheet are AppKit's and are not asserted here; the
    /// wording is this file's and nothing else checks it.
    ///
    /// - Returns: Whether the legs held.
    @MainActor
    private static func consentPromptLegs() -> Bool {
        let attach = TerminalSurface.consentQuestion(.attach, capabilityCode: 0)
        let terminate = TerminalSurface.consentQuestion(.terminate, capabilityCode: 0)
        let grant = TerminalSurface.consentQuestion(.grantCapability, capabilityCode: Ubiquitty.Capability.ClipboardRead.rawValue)
        guard attach != terminate, terminate != grant, attach != grant else {
            return failed(
                "the consent question reads the same for different actions —"
                    + " attach “\(attach)”, terminate “\(terminate)”, grant “\(grant)”"
            )
        }
        guard terminate.localizedCaseInsensitiveContains("close"),
            grant.contains("read your clipboard")
        else {
            return failed(
                "the consent question does not name what it asks:"
                    + " terminate “\(terminate)”, grant “\(grant)”"
            )
        }

        // The verified process is stated; the claimed label is quoted and
        // marked unverified beside it.
        let both = TerminalSurface.consentDetail(peerProcess: "/usr/bin/agent", agentLabel: "Backup Helper")
        guard both.contains("/usr/bin/agent"), both.contains("Backup Helper"),
            both.localizedCaseInsensitiveContains("not verified")
        else {
            return failed("the consent detail does not separate the verified name from the claimed one: “\(both)”")
        }

        // No label to attribute: the sentence must not leave an empty quotation
        // where a name would be, which reads as a nameless agent rather than
        // as one that offered nothing.
        let bare = TerminalSurface.consentDetail(peerProcess: "/usr/bin/agent", agentLabel: "")
        guard !bare.contains("“"), bare.contains("/usr/bin/agent") else {
            return failed("the consent detail quotes an absent label: “\(bare)”")
        }

        // Nothing verified either. A prompt naming no one must say so rather
        // than presenting an empty string as a process name.
        let unknown = TerminalSurface.consentDetail(peerProcess: "", agentLabel: "")
        guard unknown.localizedCaseInsensitiveContains("unidentified") else {
            return failed("the consent detail does not say when the peer is unidentified: “\(unknown)”")
        }
        return true
    }

    /// The clipboard-scope badge: what it shows, and whose session it shows it for.
    ///
    /// The badge is the only thing on screen that says a remote machine can read
    /// this Mac's clipboard, so two claims matter and neither is cosmetic. It
    /// must SHOW for the exposed state — a disclosure the user opted into is
    /// still one they are entitled to see — and it must not take another
    /// window's scope, because two sessions on two hosts have two answers and
    /// showing one window's user the other's would be worse than showing
    /// nothing.
    ///
    /// - Returns: Whether the legs held.
    @MainActor
    private static func clipboardScopeLegs() -> Bool {
        let bar = ChromeAccessoryBar(scope: .window, heightInPoints: ChromeAccessoryBar.titleRowHeightInPoints)
        let indicator = ClipboardScopeIndicator.install(in: bar)

        // A local session says nothing: one pasteboard, no ambiguity, and a
        // badge that is always there is a badge nobody reads.
        guard indicator.isHidden, indicator.scope == .local else {
            return failed("clipboard scope: a fresh badge is showing before any session reported one")
        }

        // A window is needed to address the report: the notification carries the
        // window so a badge takes its own session's scope and no other's.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(bar)

        ClipboardScopeIndicator.report(.client, for: window)
        guard indicator.scope == .client else {
            return failed("clipboard scope: the badge did not take the scope reported for its window")
        }
        guard !indicator.isHidden else {
            return failed(
                "clipboard scope: a remote machine can read this Mac's clipboard and the badge is hidden"
            )
        }
        guard indicator.accessibilityRole() == .popUpButton,
            indicator.accessibilityLabel()?.contains("this Mac’s clipboard") == true,
            indicator.toolTip?.contains("This Mac") == true,
            indicator.toolTip?.contains("images") == true
        else {
            return failed("clipboard scope: the selector does not expose its role, source, and image support")
        }

        // The host scope is the safe one and still shows, because "programs
        // there read their own" is a different fact from "no session at all".
        ClipboardScopeIndicator.report(.host, for: window)
        guard indicator.scope == .host, !indicator.isHidden else {
            return failed("clipboard scope: the host scope did not report")
        }

        // Another window's report is not this badge's business.
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        ClipboardScopeIndicator.report(.client, for: other)
        guard indicator.scope == .host else {
            return failed("clipboard scope: a badge took another window's scope, which reports the wrong session")
        }

        // And a local session hides it again, so a badge left over from a
        // closed remote window cannot claim an exposure that has ended.
        ClipboardScopeIndicator.report(.local, for: window)
        guard indicator.scope == .local, indicator.isHidden else {
            return failed("clipboard scope: the badge stayed up after the session stopped being remote")
        }
        return true
    }

    /// The paste action, against the window shape a remote attach builds.
    ///
    /// A hosted window holds no pane in the model, so the pane map answers
    /// nothing for it and only the first responder names its surface. The
    /// action reached for the pane map once, which left every remote window —
    /// the one shape an image push exists for — unable to paste at all, while
    /// a local window pasted fine and every build stayed green.
    ///
    /// - Parameters:
    ///   - device: The Metal device the window's renderer draws through.
    ///   - library: Its shader library.
    /// - Returns: Whether the legs held.
    @MainActor
    private static func pasteLegs(device: MTLDevice, library: MTLLibrary) -> Bool {
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return failed("paste: no surface")
        }
        guard
            let renderer = SurfaceRenderer(device: device, library: library, familyName: "Menlo", pointSize: 12)
        else {
            return failed("paste: no renderer")
        }
        surface.renderer = renderer
        // The hosted shape: no workspace surface, no pane — the window fills
        // with this surface directly, as spawnRemoteWindow builds it.
        let controller = TerminalWindowController(
            workspaceSurface: Ubiquitty.Session.Layout.invalidSurface,
            pane: nil,
            surface: surface,
            renderer: renderer,
            rows: 24,
            columns: 80
        )
        controller.remoteSurface = surface
        controller.window?.makeFirstResponder(surface)

        let recorder = TransmitRecorder()
        surface.observer = recorder

        // A hosted window answers nothing through the pane map. An action
        // keyed on it would find no surface and return having done nothing,
        // which is indistinguishable from an empty clipboard.
        guard controller.focusedSurface == nil else {
            return failed("paste: a hosted window answered the pane map, so this leg proves nothing")
        }
        guard controller.activeSurface === surface else {
            return failed("paste: the hosted surface is not the window's active one")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo hosted-paste", forType: .string)
        controller.pasteFromPasteboard(nil)
        guard recorder.text.contains("echo hosted-paste") else {
            return failed("paste: a hosted window transmitted \(recorder.text.debugDescription) for a text paste")
        }

        // Core owns the fence, and a program that asked for bracketed paste
        // must receive one: the bytes are the shell's protection against a
        // multi-line clipboard running as commands.
        recorder.transmitted = []
        feed(surface.drive, "\u{1b}[?2004h")
        _ = surface.drive.takeSyncFrameReady()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("one\ntwo", forType: .string)
        // The confirmation is a different rule with a different owner, and it
        // stands between this leg and the bytes: a clipboard of more than
        // `confirm_multiline_threshold` lines opens a sheet, and a sheet begun
        // on a window nothing is answering never calls back, so the paste
        // returns having transmitted nothing. Set here rather than left to the
        // machine, because the reader's own `[paste]` block would otherwise
        // decide whether this leg tests the fence or tests nothing.
        let standingDocument = String(Ubiquitty.Preferences.liveDocument().pointee)
        _ = Ubiquitty.Preferences.configure(
            std.string(standingDocument + "\n[paste]\nconfirm_multiline = false\n"),
            .Permissive
        )
        controller.pasteFromPasteboard(nil)
        _ = Ubiquitty.Preferences.configure(std.string(standingDocument), .Permissive)
        let fenced = recorder.text
        guard fenced.hasPrefix("\u{1b}[200~"), fenced.hasSuffix("\u{1b}[201~") else {
            return failed("paste: bracketed paste was on and the bytes carried no fence: \(fenced.debugDescription)")
        }
        guard fenced.contains("one\rtwo") else {
            return failed("paste: the newline was not normalised to CR: \(fenced.debugDescription)")
        }

        // An image with no host has nowhere to go, and no bytes can carry it.
        // A shell that typed something here would type the wrong thing.
        recorder.transmitted = []
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        controller.pasteFromPasteboard(nil)
        guard recorder.text.isEmpty else {
            return failed("paste: an image typed \(recorder.text.debugDescription) into a surface with no host")
        }
        guard !surface.isRemoteAttached else {
            return failed("paste: this leg needs a surface with no host, and it has one")
        }

        surface.observer = nil
        return true
    }

    /// Records what a surface transmits.
    private final class TransmitRecorder: NSObject, TerminalSurfaceObserver {
        var transmitted: [CChar] = []

        func terminalSurface(_: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
            transmitted.append(contentsOf: bytes.prefix(count))
        }

        /// What was transmitted, as text.
        var text: String {
            String(decoding: transmitted.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// How far the view may scroll back, read off the model under the lock:
    /// `Runtime::viewOffsetLimit`'s twin for a smoke that feeds without
    /// draining, so no snapshot is published to read it from.
    private static func scrollableRowCount(_ drive: RuntimeDrive) -> Int {
        drive.lockForRead()
        let count = drive.borrowTerminal().map { Int(Ubiquitty.Screen.scrollableRowCount($0)) } ?? 0
        drive.unlockForRead()
        return count
    }

    /// The history facts read off the model under the lock, the published
    /// snapshot's twin for a smoke that feeds without draining.
    private static func historyFacts(_ drive: RuntimeDrive) -> Ubiquitty.Screen.HistoryFacts {
        drive.lockForRead()
        let facts = drive.borrowTerminal().map { Ubiquitty.Screen.historyFacts($0) } ?? Ubiquitty.Screen.HistoryFacts()
        drive.unlockForRead()
        return facts
    }

    private static func feed(_ drive: RuntimeDrive, _ text: String) {
        let bytes = Array(text.utf8CString.dropLast())
        drive.feed(bytes.span)
    }

    /// Draws a frame after font preparation and presentation holds settle.
    ///
    /// The parser can hold presentation between a readiness check and capture.
    /// Another attempt requires that hold or a font-preparation deferral;
    /// allocation and encoding failures are not retried.
    ///
    /// - Parameters:
    ///   - renderer: The surface renderer with the adopted typography.
    ///   - surface: The surface to capture.
    ///   - layer: The layer to present into.
    /// - Returns: Whether the prepared frame drew before the deadline.
    private static func encodeAfterFontPreparation(
        _ renderer: SurfaceRenderer,
        for surface: TerminalSurface,
        into layer: CAMetalLayer
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while true {
            if renderer.encodeFrame(for: surface, into: layer) {
                return true
            }
            // The decline's own reason, not the hold read again: the ingest
            // thread releases a held frame on its timer, so a frame refused
            // for a hold can find none by the time it is asked about here.
            let decline = renderer.lastFrameDecline
            let isDeferred =
                decline == .withheld || decline == .blockOpenUnderLock || decline == .drainSaturated || decline == .redrawArriving
                || surface.frameRenderers.values.contains(where: { $0.didDeferForFontPreparation })
            guard isDeferred, Date() < deadline
            else {
                return false
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// Waits for the coherence rule to admit the pane's frame.
    ///
    /// A live shell's output is held for its read to go quiet, so a live
    /// present that follows it at once is refused until the rule announces
    /// the frame, as the frame link would wait for that announcement. Bounded
    /// by the rule's own deadline, with room for a loaded runner.
    private static func waitForAdmittedFrame(_ surface: TerminalSurface) {
        let deadline = Date(timeIntervalSinceNow: 1)
        while surface.drive.shouldWithholdFrame(nowTicks: TerminalSurface.monotonicTicksNow()), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// Waits for a launched shell to run a line it is sent.
    ///
    /// The probe is sent again on a timer rather than once, because a line
    /// that arrives before the shell claims its terminal is echoed by the
    /// line discipline and then discarded — sending once and waiting cannot
    /// tell that apart from a slow shell. The probe is spelled so that the
    /// echo of the line does not carry the string its output carries: the
    /// shell folds the adjacent quotes away, the screen keeps them.
    ///
    /// - Parameter surface: The surface whose session runs the shell.
    /// - Returns: Whether the probe's output reached the screen in time.
    private static func shellRunsWhatItIsSent(_ surface: TerminalSurface) -> Bool {
        let token = "shell-awake"
        let deadline = Date(timeIntervalSinceNow: 15)
        var nextProbe = Date.distantPast
        while Date() < deadline {
            if Date() >= nextProbe {
                surface.send("printf 'shell''-awake\\n'\n")
                nextProbe = Date(timeIntervalSinceNow: 0.5)
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if surface.gridTextForTesting().contains(token) {
                return true
            }
        }
        return false
    }

    /// The visible grid as one line, for a refusal that has to say what the
    /// session had on screen rather than only what it counted.
    ///
    /// - Parameter surface: The surface to read.
    /// - Returns: The rows carrying text, joined, or the words for a blank grid.
    private static func screenReport(_ surface: TerminalSurface) -> String {
        let screen = surface.gridTextForTesting()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return screen.isEmpty ? "nothing on screen" : "on screen: " + screen
    }

    private static func cursorColumn(_ drive: RuntimeDrive) -> Int {
        drive.withTerminal { terminal in
            guard let screen = terminal.screens.active else { return 0 }
            return Int(screen.pointee.cursorX)
        } ?? 0
    }

    /// The pipeline leg's oracle: the ingest thread's work must reach the
    /// main thread as observer calls, or the session is silent to its host.
    private final class DeliveryWitness: TerminalSurfaceObserver {
        var screenUpdates = 0
        var gridResizes: [(rows: Int, columns: Int)] = []
        var focusChanges: [Bool] = []
        var passwordPromptChanges: [Bool] = []
        var notifications: [Banner] = []

        func terminalSurfaceDidUpdateScreen(_ surface: TerminalSurface) {
            screenUpdates += 1
        }

        func terminalSurface(_ surface: TerminalSurface, didResizeGridTo rows: Int, columns: Int) {
            gridResizes.append((rows, columns))
        }

        func terminalSurface(_ surface: TerminalSurface, didChangeFocus isFocused: Bool) {
            focusChanges.append(isFocused)
        }

        func terminalSurface(_ surface: TerminalSurface, didChangePasswordPrompt isActive: Bool) {
            passwordPromptChanges.append(isActive)
        }

        /// Drains the banners the session queued, which is what the report
        /// asks of a host: the queue is the state, and a host that read one
        /// and returned would strand the rest until the next arrival.
        ///
        /// - Parameter surface: The surface whose session carries them.
        func terminalSurfaceDidPostNotification(_ surface: TerminalSurface) {
            // The surface reports from the main actor, where its drive lives;
            // the witness is not isolated, so the drain says so and hands the
            // banners out rather than touching the witness from inside.
            let drained = MainActor.assumeIsolated { () -> [Banner] in
                var banners: [Banner] = []
                while let notification = surface.drive.takeNotification() {
                    banners.append(Banner(title: notification.title, body: notification.body))
                }
                return banners
            }
            notifications.append(contentsOf: drained)
        }
    }

    /// One banner a host was asked to post, as the leg compares them.
    private struct Banner: Equatable {
        let title: String
        let body: String
    }

    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("surface-smoke: \(reason)\n".utf8))
        return false
    }

    /// Reports what the run covered, and answers true.
    ///
    /// A silent success is indistinguishable from a mode that never ran: the
    /// exit code is the same whether the smoke asserted everything or the flag
    /// went unparsed and the process fell through. Every other headless mode
    /// here names its verdict, and a reader comparing two runs has nothing to
    /// compare without one.
    ///
    /// - Parameter covered: What the run asserted.
    /// - Returns: True, so a caller can `return passed(…)`.
    private static func passed(_ covered: String) -> Bool {
        FileHandle.standardOutput.write(Data("surface-smoke: PASS — \(covered)\n".utf8))
        return true
    }
}

#endif
