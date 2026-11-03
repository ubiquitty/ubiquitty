// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// DrawEntrySmoke.swift — the oracle for the seam between a shell's display
// cycle and the surface's draw.
//
// Every other surface oracle calls the draw itself, so all of them pass on a
// surface the toolkit never asks to draw. The name of that entry point is the
// one thing each shell spells differently, which is exactly where a shell can
// be left unwired: connected, parsing, holding a correct grid, showing black.
//
// Both shells run this. A frontend that answers no display cycle fails here.

import Metal
import QuartzCore
// The terminal the theme legs read back through: naming its type is what
// makes the drive borrow resolvable here.
internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The smoke's entry, which each shell's launch path dispatches.
public final class DrawEntrySmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether the shell's display cycle reached the surface.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            DrawEntrySmoke.run()
        }
    }
}

/// The scenario: mark a windowed surface for display, and see whether the
/// shell comes back for a frame.
@MainActor
enum DrawEntrySmoke {
    /// How long the shell is given to run a display cycle.
    private static let deadlineInSeconds = 2.0

    /// - Returns: Whether every stage reported success.
    static func run() -> Bool {
        guard let device = SystemMetalDevice.resolve() else {
            return failed("no Metal device")
        }
        // The library the shipping surface uses. Its bundle lookup resolves
        // against this module, so a frontend that embeds the module without
        // its metallib fails here rather than in a black window.
        guard let library = MetalPipelines.moduleShaderLibrary(for: device) else {
            return failed("no module shader library")
        }
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return failed("no surface session")
        }
        guard
            let renderer = SurfaceRenderer(
                device: device,
                library: library,
                familyName: defaultFamilyName,
                pointSize: 12
            )
        else {
            return failed("no surface renderer")
        }
        surface.renderer = renderer

        guard verifyPresentedGrid(device: device, library: library) else { return false }

        #if canImport(AppKit)
        guard let clipboardSurface = TerminalSurface(rows: 2, columns: 20) else {
            return failed("no clipboard surface")
        }
        clipboardSurface.renderer = renderer
        let clipboardBytes = Array("clipboard size\r\n\u{1b}[48;2;51;51;51mgray".utf8CString.dropLast())
        clipboardSurface.drive.feed(clipboardBytes.span)
        clipboardSurface.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for scale in [1.0, 2.0] {
            renderer.prepare(forDeviceScale: scale)
            for size in [12.0, 18.0] {
                renderer.adopt(pointSize: size)
                guard clipboardSurface.copySelection(style: .everything, to: pasteboard),
                    let data = pasteboard.data(forType: .rtf),
                    let copied = NSAttributedString(rtf: data, documentAttributes: nil),
                    copied.string.contains("clipboard size"),
                    let font = copied.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                    font.pointSize == size,
                    copied.attribute(.backgroundColor, at: 0, effectiveRange: nil) is NSColor
                else {
                    return failed("rich copy lost font size \(size) at scale \(scale)")
                }
                let grayRange = (copied.string as NSString).range(of: "gray")
                guard grayRange.location != NSNotFound,
                    let color = copied.attribute(.backgroundColor, at: grayRange.location, effectiveRange: nil) as? NSColor,
                    let rgb = color.usingColorSpace(.sRGB),
                    abs(rgb.redComponent - 0.2) < 0.001,
                    abs(rgb.greenComponent - 0.2) < 0.001,
                    abs(rgb.blueComponent - 0.2) < 0.001
                else {
                    return failed("rich copy changed the cell's sRGB background")
                }
            }
        }
        renderer.adopt(pointSize: 12)
        #endif

        // Installed straight from the factory, holding no second reference —
        // which is what an embedder writes. A surface that does not keep its
        // renderer reads nil on the next line, and every frame after it draws
        // nothing at all.
        surface.renderer = TerminalSurface.makeRenderer(
            fontFamily: defaultFamilyName,
            pointSize: 12
        )
        guard surface.renderer != nil else {
            return failed("the surface did not keep the renderer the factory handed it")
        }

        // The surface holds its renderer strongly, so a renderer that held the
        // surface back would leak the pair — and a leaked surface keeps a
        // session, a grid and an atlas alive behind it. Probed rather than
        // reasoned about: a capture added later is exactly the kind of cycle
        // no reading of the current code can rule out.
        weak var releasedSurface: TerminalSurface?
        weak var releasedRenderer: AnyObject?
        let didCreateSurface = autoreleasepool {
            guard let scratch = TerminalSurface(rows: 4, columns: 10) else { return false }
            scratch.renderer = TerminalSurface.makeRenderer(
                fontFamily: defaultFamilyName,
                pointSize: 12
            )
            releasedSurface = scratch
            releasedRenderer = scratch.renderer as AnyObject?
            return true
        }
        guard didCreateSurface else {
            return failed("could not create a surface for renderer teardown")
        }
        guard releasedSurface == nil else {
            return failed("a surface outlived its last reference — something it holds holds it back")
        }
        guard releasedRenderer == nil else {
            return failed("a renderer outlived the only surface holding it")
        }

        #if canImport(AppKit)
        weak var releasedDragDrop: TerminalDragDrop?
        let didCreateDragSurface = autoreleasepool {
            guard let scratch = TerminalSurface(rows: 4, columns: 10) else { return false }
            releasedSurface = scratch
            releasedDragDrop = scratch.dragDrop
            return true
        }
        guard didCreateDragSurface else {
            return failed("could not create a surface for drag-and-drop teardown")
        }
        guard releasedSurface == nil, releasedDragDrop == nil else {
            return failed("a surface or its drag controller outlived its last owner")
        }
        #endif

        // Themes, on the surface a shell actually shows. A frontend offering a
        // picker needs both halves: a list to offer, and an apply that moves
        // the colours the renderer reads. Asserted through the public API a
        // picker calls, not through Core, because the two are joined by a name
        // lookup and a byte table that a shell cannot see go wrong.
        let names = TerminalSurface.themeNames
        guard !names.isEmpty else {
            return failed("Core offers no themes, so a picker has nothing to show")
        }
        var themedBackgrounds: [UInt16] = []
        for themeIndex in 0..<names.count {
            guard surface.applyTheme(at: themeIndex) else {
                return failed("applying theme \(themeIndex) (\(names[themeIndex])) was refused")
            }
            let background = surface.drive.withTerminal { terminal in
                terminal.palette.defaultBackground.red
            }
            guard let background else {
                return failed("the surface lent no terminal after a theme apply")
            }
            themedBackgrounds.append(background)
        }
        // Not every theme differs from every other in one channel, but they
        // cannot all be identical: a palette written at the wrong width, or one
        // never written at all, is the case where they are.
        guard Set(themedBackgrounds).count > 1 else {
            return failed("every theme left the same background — the apply reached no palette")
        }
        // An index Core does not have is refused rather than applied as
        // something else.
        guard !surface.applyTheme(at: names.count) else {
            return failed("a theme index past the end was accepted")
        }

        guard cursorVisibilityLeg(device: device, library: library) else {
            return false
        }

        // Font preparation must leave the target untouched until the complete frame is ready.
        guard let preparedSurface = TerminalSurface(rows: 6, columns: 60),
            let preparedRenderer = SurfaceRenderer(device: device, library: library, familyName: "Monaspace Neon", pointSize: 13)
        else { return failed("font preparation fixture unavailable") }
        preparedSurface.renderer = preparedRenderer
        feed(preparedSurface.drive, "\u{1b}[?25l中文 漢字 한글 ∑ ⌘ → á ë\r\nt\u{1b}[1mm\u{1b}[0mux t\u{1b}[31mm\u{1b}[0mux === !=")
        let preparationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 800,
            height: 240,
            mipmapped: false
        )
        preparationDescriptor.usage = [.renderTarget, .shaderRead]
        preparationDescriptor.storageMode = .shared
        guard let referenceTexture = device.makeTexture(descriptor: preparationDescriptor),
            let preparedTexture = device.makeTexture(descriptor: preparationDescriptor),
            preparedRenderer.render(preparedSurface, into: referenceTexture, contentScale: 2)
        else { return failed("font preparation reference frame unavailable") }
        let untouchedPixels = [UInt8](repeating: 0x5A, count: 800 * 240 * 4)
        untouchedPixels.withUnsafeBytes { bytes in
            preparedTexture.replace(
                region: MTLRegionMake2D(0, 0, 800, 240),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 800 * 4
            )
        }
        preparedRenderer.forcesFontPreparationForTesting = true
        _ = preparedSurface.drive.withTerminal { preparedSurface.drive.invalidateRetainedFrame($0) }
        guard !preparedRenderer.render(preparedSurface, into: preparedTexture, contentScale: 2) else {
            return failed("cold font preparation did not defer the frame")
        }
        var deferredPixels = untouchedPixels
        preparedTexture.getBytes(
            &deferredPixels,
            bytesPerRow: 800 * 4,
            from: MTLRegionMake2D(0, 0, 800, 240),
            mipmapLevel: 0
        )
        guard deferredPixels == untouchedPixels else {
            return failed("font preparation presented a partial frame")
        }
        guard spinUntil({ preparedRenderer.render(preparedSurface, into: preparedTexture, contentScale: 2) }) else {
            return failed("font preparation did not publish a complete frame")
        }
        var referencePixels = [UInt8](repeating: 0, count: 800 * 240 * 4)
        var preparedPixels = referencePixels
        let preparationRegion = MTLRegionMake2D(0, 0, 800, 240)
        referenceTexture.getBytes(&referencePixels, bytesPerRow: 800 * 4, from: preparationRegion, mipmapLevel: 0)
        preparedTexture.getBytes(&preparedPixels, bytesPerRow: 800 * 4, from: preparationRegion, mipmapLevel: 0)
        guard preparedPixels == referencePixels else {
            return failed("font preparation changed fallback, combining marks, or mixed-style healing pixels")
        }

        preparedRenderer.forcesFontPreparationForTesting = false
        preparedRenderer.style.paddingLeftPoints = 8
        preparedRenderer.style.paddingTopPoints = 8
        for background in ["#eeeeee", "#111111", "#eeeeee"] {
            feed(preparedSurface.drive, "\u{1b}]11;\(background)\u{7}\u{1b}[2J\u{1b}[Htheme")
            // The erase arms Core's erase hold, which withholds frames until
            // the stream has been quiet for its settle window, so the first
            // frame after the theme change is the one drawn once it settles.
            guard spinUntil({ preparedRenderer.render(preparedSurface, into: preparedTexture, contentScale: 2) }) else {
                return failed("theme-change reference frame unavailable")
            }
            var expectedPadding = [UInt8](repeating: 0, count: 4)
            preparedTexture.getBytes(&expectedPadding, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            for index in 0..<4 {
                feed(preparedSurface.drive, "\u{1b}[?2026h\u{1b}[Hframe \(index)\u{1b}[?2026l")
                guard preparedRenderer.render(preparedSurface, into: preparedTexture, contentScale: 2) else {
                    return failed("theme-change boundary frame unavailable")
                }
                var actualPadding = [UInt8](repeating: 0, count: 4)
                preparedTexture.getBytes(&actualPadding, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
                guard actualPadding == expectedPadding else {
                    return failed("boundary frame restored padding from an earlier theme")
                }
            }
        }

        // A surface outside a window is not asked to draw by either shell, so
        // the scenario is meaningless without one.
        guard let window = present(surface) else {
            return noWindow()
        }
        guard surface.window != nil else {
            return failed("surface did not enter a window")
        }

        let before = surface.drawnFrameCount
        surface.needsDisplay = true
        let drew = spinUntil { surface.drawnFrameCount > before }
        guard drew else {
            return failed("marking the surface for display never reached its draw entry point")
        }

        // A second frame, after content: the first can be satisfied by a
        // shell that draws once on entering a window and never again.
        let afterFirst = surface.drawnFrameCount
        surface.needsDisplay = true
        guard spinUntil({ surface.drawnFrameCount > afterFirst }) else {
            return failed("the shell drew once and answered no later display cycle")
        }

        #if canImport(AppKit)
        let link = surface.ensureFrameLink()
        link.start(framesPerSecond: window.screen?.maximumFramesPerSecond ?? 60)
        surface.needsDisplay = true
        let attemptsBeforeToolkitPass = surface.encodeAttemptCount
        surface.updateLayer()
        guard surface.encodeAttemptCount == attemptsBeforeToolkitPass else {
            return failed("AppKit consumed repaint demand while the Metal link owned drawables")
        }
        surface.metalLayer.presentsWithTransaction = true
        link.synchronizePresentationMode()
        guard link.isRunning, !link.ownsDrawableDelivery else {
            return failed("transactional resize retained Metal display-link drawable ownership")
        }
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard surface.encodeAttemptCount > attemptsBeforeToolkitPass else {
            return failed("a resize step could not draw while the frame clock was active")
        }
        surface.metalLayer.presentsWithTransaction = false
        link.synchronizePresentationMode()
        guard link.ownsDrawableDelivery else {
            return failed("resize settlement did not restore Metal display-link delivery")
        }
        link.stop()
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard surface.encodeAttemptCount > attemptsBeforeToolkitPass else {
            return failed("on-demand drawing did not resume after releasing the Metal link")
        }
        surface.serviceIngestEvents()
        surface.drawSurfaceFrame()
        let attemptsBeforePendingOutput = surface.encodeAttemptCount
        feed(surface.drive, "output before its queued main-thread notification\r\n")
        // No run-loop turn delivers the ingest notification before this tick.
        surface.driveOneFrame()
        guard surface.encodeAttemptCount > attemptsBeforePendingOutput else {
            return failed("a display tick skipped output whose ingest notification was still queued")
        }
        #endif

        // A pass the layer can hand no drawable for draws nothing, and AppKit
        // has already spent the dirty flag on it. Unless that pass asks again,
        // the model change that wanted the frame goes with the flag, and a
        // surface that has never presented stays blank for as long as it lives
        // — over a live session, whose keystrokes run and whose title tracks
        // the shell. A new tab reaches it whenever its first pass beats the
        // layer to a drawable.
        //
        // A layer carrying no device vends none, which is that condition on
        // demand. Read as "is the surface still being asked", not as the flag
        // itself: each failed pass re-arms and the next consumes it, so the
        // flag is true or false depending on when it is sampled, while the
        // count only rises where the asking continues.
        guard let shellRenderer = surface.renderer as? SurfaceRenderer else {
            return failed("the surface's renderer is not the shell's")
        }
        let keptDevice = surface.metalLayer.device
        surface.metalLayer.device = nil
        // Bytes the frame must carry. A pass whose capture reproduces the glass
        // presents nothing and asks for no drawable, by design; only a frame
        // owed for new content reaches the layer, so only one can show whether
        // a pass denied a drawable asks again.
        feed(surface.drive, "a line the glass has not shown\r\n")
        surface.deliver([.screenDirty])
        let stalled = surface.drawnFrameCount
        let encodesBefore = surface.encodeAttemptCount
        // Counted on the passes that REACH the renderer, not on every pass the
        // link asks for. A pass withheld for an open synchronized-output block,
        // or skipped because nothing owed a frame, turns back before the
        // drawable is ever asked for — it presented nothing because it tried
        // nothing, and asking it to retry would be asking it to undo its own
        // hold. `drawnFrameCount` counts those too, and reading the retry off
        // it judges passes that were never in a position to retry.
        let keptAsking = spinUntil { surface.encodeAttemptCount > encodesBefore + 1 }
        let presentedWhileDenied = shellRenderer.presentedFrameCount
        surface.metalLayer.device = keptDevice
        guard keptAsking else {
            return failed(
                "a surface whose layer hands out no drawable stopped asking for frames "
                    + "after \(surface.encodeAttemptCount - encodesBefore) that reached the renderer "
                    + "(\(surface.drawnFrameCount - stalled) pass(es) in all, "
                    + "\(surface.withheldForSyncOutputCount) withheld, "
                    + "\(surface.skippedAsUnowedCount) unowed): a pane that never "
                    + "presented would stay blank over a live session"
            )
        }
        // A pass that presented nothing either asks for another frame or
        // declines for a stated reason. Neither is the blank pane: the request
        // that wanted the frame is spent, and nothing is left to spend it again.
        guard surface.repaintRetriesAsked + surface.repaintRetriesRefused > 0 else {
            return failed(
                "a pass that presented nothing neither asked for another frame nor declined to "
                    + "(drew \(surface.drawnFrameCount - stalled) pass(es), presented "
                    + "\(shellRenderer.presentedFrameCount - presentedWhileDenied) of them, "
                    + "asked \(surface.repaintRetriesAsked), refused \(surface.repaintRetriesRefused), "
                    + "window \(surface.window == nil ? "absent" : "present"), "
                    + "skipped-as-glass \(shellRenderer.skippedAsReproducingGlassCount), "
                    + "reached-renderer \(surface.encodeAttemptCount - encodesBefore))"
            )
        }
        // The frames those passes built were never shown, so a pass holding a
        // drawable again must present one rather than read its own build as
        // what the glass already holds: a pane whose first drawable came late
        // would otherwise stay blank for as long as it lives.
        //
        // Driven here rather than waited for. A window presented this way never
        // reads as occlusion-visible, so the surface's own retry declines by
        // design and the toolkit runs no display cycle for it — the repaint
        // vocabulary reaches nothing, and a wait on the mark would pass
        // vacuously on a mark nobody consumed. The mark is still set first,
        // because that is what owes the pass a frame.
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard shellRenderer.presentedFrameCount > presentedWhileDenied else {
            return failed(
                "no frame was presented once the layer could draw again "
                    + "(last pass: \(shellRenderer.phaseLogReuseTerms)), as if the glass already showed it"
            )
        }

        #if canImport(AppKit)
        // A host asking the surface's own layer for a drawable while the
        // display link delivers them. Core Animation raises from that call,
        // and the exception unwinding out of a host's main-actor task leaves
        // the concurrency runtime faulting at its next isolation check. The
        // layer answers nil instead, and vends drawables again once the link
        // stops.
        guard !surface.metalLayer.presentsWithTransaction else {
            return failed("the layer presents with a transaction, so no display link can deliver its drawables")
        }
        guard startsAndStopsUnderWaitingAcquire(surface) else { return false }
        surface.ensureFrameLink().start(framesPerSecond: 60)
        guard surface.frameLink?.ownsDrawableDelivery == true else {
            return failed("the display link did not take over the layer's drawables")
        }
        guard surface.metalLayer.nextDrawable() == nil else {
            return failed("the layer vended a drawable its display link delivers")
        }
        surface.frameLink?.stop()
        guard surface.metalLayer.nextDrawable() != nil else {
            return failed("the layer vended no drawable once its display link stopped")
        }
        #endif

        surface.setSurfaceFocused(false)
        surface.drawSurfaceFrame()
        #if canImport(AppKit)
        // The local PTY carrier belongs to macOS; iOS receives remote output.
        let beforeBoundary = shellRenderer.presentedFrameCount
        let animation =
            "printf '\\033[?2026h\\033_Ga=T,f=32,s=1,v=1,i=42,q=2;/////w==\\033\\\\\\033[5;3Hsettled stars\\033[20;3H\\033[?2026l\\033[?2026h\\033[2;30Hunfinished stars'; sleep 5"
        guard surface.drive.launchShellCommand(animation), surface.drive.startIngest() else {
            return failed("the synchronized-frame probe could not open its PTY")
        }
        guard spinUntil({ surface.drive.readSnapshot().syncHoldActive }) else {
            surface.drive.stopIngest()
            return failed("the synchronized-frame probe never received its open block")
        }
        surface.drive.stopIngest()
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard shellRenderer.presentedFrameCount > beforeBoundary else {
            return failed("a completed synchronized frame was withheld by the next open block while unfocused")
        }
        guard surface.lastFrameImageQuadCount == 1 else {
            return failed("the queued synchronized frame omitted its inline image")
        }
        let afterBoundary = shellRenderer.presentedFrameCount
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard shellRenderer.presentedFrameCount == afterBoundary else {
            return failed("an unfinished synchronized frame reached presentation")
        }
        guard surface.cursorPresentationDeadline == nil else {
            return failed("a withheld synchronized frame kept an expired cursor retry armed")
        }
        feed(surface.drive, "\u{1B}[20;3H\u{1B}[?2026l")
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard shellRenderer.presentedFrameCount > afterBoundary else {
            return failed("closing the synchronized block did not release its frame")
        }
        #endif

        let beforeUnpublishedBlock = shellRenderer.presentedFrameCount
        _ = surface.drive.withTerminal { terminal in
            "\u{1B}[?2026h\u{1B}[3;40Hunpublished stars"
                .withCString {
                    Ubiquitty.processBytes(terminal, std.string_view($0))
                }
        }
        guard !surface.drive.readSnapshot().syncHoldActive else {
            return failed("the unpublished-block probe unexpectedly published a snapshot")
        }
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard shellRenderer.presentedFrameCount == beforeUnpublishedBlock else {
            return failed("the live capture trusted a stale synchronization snapshot")
        }
        feed(surface.drive, "\u{1B}[20;3H\u{1B}[?2026l")
        surface.needsDisplay = true
        surface.drawSurfaceFrame()

        // A blink-dark cursor has no presentation hold to settle.
        surface.setSurfaceFocused(true)
        surface.cursorPresentationBypassUntil = CACurrentMediaTime() + 1
        feed(surface.drive, "\u{1B}[?25h\u{1B}[2 q\u{1B}[20;3H")
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        surface.cursorPresentationBypassUntil = 0
        // The hold is entered by a frame drawing the cursor away from where
        // the frame before it drew it, and a pass whose drawable the layer
        // declined draws nothing: the simulator under load declines them.
        // The move is repeated on a fresh column until a pass took it, and
        // a hold that never comes over the bound is the failure.
        var didEnterHold = false
        var heldColumn = 21
        for attempt in 0..<8 where !didEnterHold {
            heldColumn = 21 + attempt
            feed(surface.drive, "\u{1B}[20;\(heldColumn)H")
            surface.needsDisplay = true
            surface.drawSurfaceFrame()
            didEnterHold = surface.cursorPresentationDeadline != nil
        }
        guard didEnterHold else {
            return failed("a host cursor move did not enter its presentation hold")
        }
        let beforeCursorSettled = shellRenderer.presentedFrameCount
        guard
            spinUntil({
                surface.drawSurfaceFrame()
                return surface.cursorPresentationDeadline == nil
                    && shellRenderer.presentedFrameCount > beforeCursorSettled
            })
        else {
            return failed("a quiet cursor move did not repaint when its presentation hold expired")
        }
        surface.noteUserActivity()
        // One column on from the held cell: the bypass a keystroke earns
        // covers a move of two cells or fewer on the same row.
        feed(surface.drive, "\u{1B}[20;\(heldColumn + 1)H")
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard surface.cursorPresentationDeadline == nil else {
            return failed("user input did not bypass the cursor presentation hold")
        }

        // Drawing is not the same as being displayable. The layer presents
        // its drawable across its own bounds at its own contentsScale, so a
        // drawable sized in device pixels against a scale of 1 is composed at
        // the screen's scale and shown at a third of it — every frame drawn,
        // nothing legible. The scale reaches the layer through a different
        // callback on each shell, which is exactly where one of them can have
        // none.
        let scale = windowScale(window)
        guard surface.metalLayer.contentsScale == scale else {
            return failed(
                "the layer draws at contentsScale \(surface.metalLayer.contentsScale), "
                    + "against a window at \(scale)"
            )
        }
        let expected = CGSize(
            width: surface.bounds.width * scale,
            height: surface.bounds.height * scale
        )
        guard surface.metalLayer.drawableSize == expected else {
            return failed(
                "the drawable is \(surface.metalLayer.drawableSize), "
                    + "against bounds \(surface.bounds.size) at scale \(scale)"
            )
        }

        let selectionLineCount = Int(surface.drive.readSnapshot().rows) + 50
        feed(surface.drive, "\u{1B}c" + String(repeating: "selection-marker\r\n", count: selectionLineCount))
        surface.setViewOffset(absolute: 0)
        _ = surface.drive.withTerminal { terminal in
            _ = Ubiquitty.Selection.beginGesture(
                &surface.selectionModel.session.pointee,
                terminal,
                5,
                2,
                2,
                0,
                Ubiquitty.Selection.GestureStyle()
            )
            _ = Ubiquitty.Selection.endGesture(&surface.selectionModel.session.pointee)
        }
        let selectedBeforeScroll = surface.selectedText
        guard selectedBeforeScroll != nil else {
            return failed("the scroll-selection probe selected no text")
        }
        surface.setViewOffset(absolute: 3)
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard surface.selectionModel.spanScratch.first?.visibleRow == 8,
            surface.selectedText == selectedBeforeScroll
        else {
            return failed("scrolling moved the selection away from its text")
        }
        surface.clearSelection()
        surface.setViewOffset(absolute: 0)
        #if canImport(AppKit)
        let originalSize = surface.frame.size
        let fittedTop = renderer.gridFitInsets(for: surface).top
        surface.isLiveResizeBottomFixed = true
        for delta: CGFloat in [3, 19, -7, 35, 2, -21, 0] {
            surface.setFrameSize(CGSize(width: originalSize.width, height: originalSize.height + delta))
            guard renderer.gridInsets(for: surface).top == fittedTop else {
                return failed("a top-edge resize moved the grid off its top inset")
            }
        }
        surface.setFrameSize(CGSize(width: originalSize.width, height: originalSize.height - 3))
        surface.viewDidEndLiveResize()
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        guard let registeredOrigin = surface.registeredSyncGeometryOrigin,
            let drawnOrigin = surface.lastFrameOriginForTesting,
            abs(registeredOrigin.y - CGFloat(drawnOrigin.y)) < 0.01
        else {
            return failed("settled resize left boundary captures at a different grid origin")
        }
        surface.setFrameSize(originalSize)
        #endif
        surface.frameClock.pauseToOnDemand()
        feed(surface.drive, "\u{1B}[?2026h\u{1B}[1;1Hh\u{1B}[?2026l")
        feed(surface.drive, "\u{1B}[1;1H ")
        surface.needsDisplay = true
        surface.drawSurfaceFrame()
        let boundaryAttempts = surface.encodeAttemptCount
        guard spinUntil({ surface.encodeAttemptCount > boundaryAttempts }) else {
            return failed("on-demand presentation left the live tail behind a captured frame")
        }
        dismiss(window)
        return passed()
    }

    /// Checks hit testing against the same immutable grid the real frame draws,
    /// while the drawable's requested dimensions remain independent.
    /// - Parameters:
    ///   - device: The device used by the live surface renderer.
    ///   - library: The shipping shader library.
    /// - Returns: Whether the frame and pointer agree for both grid mismatches.
    private static func verifyPresentedGrid(device: any MTLDevice, library: any MTLLibrary) -> Bool {
        guard let mirror = TerminalSurface(rows: 8, columns: 80),
            let painter = SurfaceRenderer(device: device, library: library, familyName: defaultFamilyName, pointSize: 12)
        else { return failed("no independent-grid surface") }
        mirror.renderer = painter
        // Selecting Pan must not change local DECCOLM or ordinary hit testing.
        painter.style.nonOwnerPresentation = .pan
        guard painter.contentClip(for: mirror) == nil else { return failed("a local surface acquired remote Pan authority") }
        mirror.frame = CGRect(x: 0, y: 0, width: 400, height: 160)
        mirror.metalLayer.contentsScale = 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mirror.metalLayer.pixelFormat,
            width: 400,
            height: 160,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return failed("no independent-grid target") }

        // The same divergent state as a non-owning client: a 132-column
        // picture, while its own window requests fewer. The actual renderer
        // compresses DECCOLM; hit testing must use that very advance. DECCOLM
        // is ignored until mode 40 allows it, so the fixture allows it first.
        feed(mirror.drive, "\u{1B}[?40h\u{1B}[?3h\u{1B}[1;100HX")
        let picture = mirror.drive.readSnapshot()
        guard picture.columns == 132, picture.isColumnCountHeld, mirror.publishedGrid.columns < 132 else {
            return failed("DECCOLM did not establish a picture wider than the drawable")
        }
        guard painter.render(mirror, into: texture, contentScale: 1),
            let point = mirror.viewPoint(forRow: 0, column: 99),
            let cell = mirror.strictCell(atViewPoint: point),
            let report = mirror.reportCell(atViewPoint: point),
            cell.column == 99, report.column == 99,
            point.x >= 0, point.x < mirror.bounds.width,
            abs(painter.drawnCellSize(for: mirror).width - Double(painter.lastFrameCellWidthInAtlasPixels)) < 0.01
        else { return failed("wide picture frame and pointer used different grids") }

        // Clip changes can leave the origin and every cell unchanged. They
        // still require a complete capture before retained pixels are cleared.
        guard let frameRenderer = mirror.frameRenderers.values.first else {
            return failed("the independent-grid render has no retained owner")
        }
        frameRenderer.prepareViewportClip(CGRect(x: 8, y: 8, width: 384, height: 144))
        guard frameRenderer.wantsFullRebuild else { return failed("a changed clip trusted old retained pixels") }
        guard painter.render(mirror, into: texture, contentScale: 1), !painter.didReuseLastFrame else {
            return failed("clip invalidation did not reach the actual capture and full draw")
        }
        frameRenderer.prepareViewportClip(nil)
        guard !frameRenderer.wantsFullRebuild else { return failed("an unchanged clip forced another full rebuild") }

        let drawnCell = painter.drawnCellSize(for: mirror)
        let drawnInsets = painter.gridInsets(for: mirror)
        let drawnPixel = mirror.reportPixel(atViewPoint: point)
        let panBeforeQuery = CGPoint(x: 17, y: 11)
        mirror.remotePanOffsetInPoints = panBeforeQuery
        guard painter.renderDetached(mirror, into: texture, contentScale: 2),
            painter.drawnCellSize(for: mirror) == drawnCell,
            painter.presentedGeometry(for: mirror)?.deviceScale == 1,
            mirror.remotePanOffsetInPoints == panBeforeQuery
        else { return failed("a detached thumbnail advanced query geometry") }
        feed(mirror.drive, "\u{1B}[?3l")
        mirror.metalLayer.contentsScale = 2
        guard mirror.drive.readSnapshot().columns == 80,
            painter.drawnCellSize(for: mirror) == drawnCell,
            painter.gridInsets(for: mirror).left == drawnInsets.left,
            painter.gridInsets(for: mirror).top == drawnInsets.top,
            painter.contentClip(for: mirror) == nil,
            mirror.strictCell(atViewPoint: point)?.column == 99,
            mirror.reportCell(atViewPoint: point)?.column == 99,
            mirror.reportPixel(atViewPoint: point).x == drawnPixel.x,
            mirror.remotePanOffsetInPoints == panBeforeQuery
        else { return failed("queries adopted a pending grid or mutated presentation state") }
        feed(mirror.drive, "\u{1B}[?2026h")
        guard !painter.render(mirror, into: texture, contentScale: 2),
            painter.drawnCellSize(for: mirror) == drawnCell,
            mirror.reportCell(atViewPoint: point)?.column == 99,
            mirror.remotePanOffsetInPoints == panBeforeQuery
        else { return failed("a withheld frame advanced query geometry") }
        feed(mirror.drive, "\u{1B}[?2026l")
        mirror.metalLayer.contentsScale = 1
        guard painter.renderStill(mirror, into: texture, contentScale: 1),
            painter.presentedGeometry(for: mirror)?.columns == 80,
            mirror.remotePanOffsetInPoints == .zero
        else { return failed("a submitted frame did not commit its query geometry") }

        // The inverse mismatch leaves blank space, not selectable fake cells.
        feed(mirror.drive, "\u{1B}[?3l")
        mirror.frame = CGRect(x: 0, y: 0, width: 1200, height: 300)
        // UIKit defers layout until its next display cycle. Publish this
        // drawable's normal resize before the application claims 80 columns.
        mirror.resizeGridToBounds()
        feed(mirror.drive, "\u{1B}[?3h\u{1B}[?3l\u{1B}[?40l")
        let narrower = mirror.drive.readSnapshot()
        guard mirror.publishedGrid.columns > narrower.columns else {
            return failed("letterbox fixture has requested \(mirror.publishedGrid) and picture \(narrower.columns)×\(narrower.rows)")
        }
        let wideDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mirror.metalLayer.pixelFormat,
            width: 1200,
            height: 300,
            mipmapped: false
        )
        wideDescriptor.usage = [.renderTarget, .shaderRead]
        guard let wideTexture = device.makeTexture(descriptor: wideDescriptor),
            painter.renderStill(mirror, into: wideTexture, contentScale: 1)
        else { return failed("the narrower picture was not drawn") }
        guard let outside = mirror.viewPoint(forRow: 0, column: Int(narrower.columns)) else {
            return failed("letterbox fixture has no cell geometry")
        }
        let strict = mirror.strictCell(atViewPoint: outside)
        let reported = mirror.reportCell(atViewPoint: outside)
        guard strict == nil, let edge = reported,
            edge.row == 0, edge.column == narrower.columns - 1
        else {
            return failed(
                "letterbox picture \(narrower.columns)×\(narrower.rows) at \(outside): strict=\(String(describing: strict)), report=\(String(describing: reported))"
            )
        }
        let beforeGrid = CGPoint(x: painter.gridInsets(for: mirror).left - 1, y: outside.y)
        guard mirror.strictCell(atViewPoint: beforeGrid) == nil,
            mirror.reportCell(atViewPoint: beforeGrid)?.column == 0
        else { return failed("left padding is selectable or reports a nonexistent column") }
        return true
    }

    /// Checks admitted redraw frames without depending on drawable delivery or wall-clock delays.
    ///
    /// - Parameters:
    ///   - device: The device used by the live surface renderer.
    ///   - library: The shipping shader library.
    /// - Returns: Whether cursor presentation preserves the expected position and opacity.
    private static func cursorVisibilityLeg(device: any MTLDevice, library: any MTLLibrary) -> Bool {
        let savedTicks = getenv("UBIQUITTY_FAKE_TICKS").map { String(cString: $0) }
        let savedAnimation = Ubiquitty.Cursor.Blink.animation()
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)
        Ubiquitty.Cursor.Blink.setAnimation(.Fade)
        defer {
            if let savedTicks {
                setenv("UBIQUITTY_FAKE_TICKS", savedTicks, 1)
            } else {
                unsetenv("UBIQUITTY_FAKE_TICKS")
            }
            Ubiquitty.Cursor.Blink.setAnimation(savedAnimation)
        }
        guard let cursorSurface = TerminalSurface(rows: 6, columns: 30),
            let cursorRenderer = SurfaceRenderer(device: device, library: library, familyName: defaultFamilyName, pointSize: 12)
        else { return failed("cursor visibility fixture unavailable") }
        cursorSurface.renderer = cursorRenderer
        guard let cursorWindow = present(cursorSurface) else { return noWindow() }
        defer { dismiss(cursorWindow) }
        cursorSurface.setSurfaceFocused(true)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 800, height: 480, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return failed("cursor visibility target unavailable")
        }
        // A remote or forced frame has already passed output admission. Mutating
        // this isolated model reaches that renderer seam without opening a PTY
        // redraw bracket that would withhold the hidden frame under test.
        func inject(_ text: String) {
            _ = cursorSurface.drive.withTerminal { terminal in
                text.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
            }
        }
        inject(String(repeating: "history\r\n", count: 200) + "\u{1b}[2 q\u{1b}[?25h\u{1b}[3;4H")
        _ = cursorSurface.drive.withTerminal { terminal in
            terminal.cursorBlinkPref = true
            terminal.cursorHoldFrames = 40
            terminal.cursorBlinkPeriodMilliseconds = 1000
            terminal.lastActivityTick = 0
            terminal.cursorMotionModePref = .Off
        }
        var frameNumber = 0
        func draw(at time: Double, programShowsCursor: Bool, row: Int, alpha: Float, named name: String) -> Bool {
            frameNumber += 1
            let target = programShowsCursor ? "\u{1b}[3;4H" : "\u{1b}[5;20H"
            inject("\u{1b}[1;1H\(frameNumber)" + target)
            guard cursorSurface.drive.withTerminal({ $0.modes.isCursorVisible }) == programShowsCursor else {
                return failed("\(name): the renderer changed DECTCEM state")
            }
            cursorRenderer.cursorPresentationTimeForTesting = time
            guard cursorRenderer.render(cursorSurface, into: texture, contentScale: 1),
                let cursor = cursorRenderer.drawnCursorForTesting(for: cursorSurface)
            else { return failed("\(name): cursor frame was not rendered") }
            guard cursorSurface.drive.withTerminal({ $0.modes.isCursorVisible }) == programShowsCursor else {
                return failed("\(name): presentation changed the terminal's cursor visibility")
            }
            guard cursor.row == row, row < 0 || cursor.column == 3 else {
                return failed("\(name): cursor at \(cursor.column),\(cursor.row), expected row \(row)")
            }
            if row >= 0, abs(cursor.mixAlpha - alpha) > 0.001 {
                return failed("\(name): cursor opacity \(cursor.mixAlpha), expected \(alpha)")
            }
            return true
        }
        guard draw(at: 1, programShowsCursor: true, row: 2, alpha: 1, named: "initial visible cursor") else { return false }
        for index in 0..<8 {
            let time = 1.01 + Double(index) * 0.02
            inject("\u{1b}[?25l")
            guard draw(at: time, programShowsCursor: false, row: 2, alpha: 1, named: "brief redraw hide \(index)") else { return false }
            inject("\u{1b}[?25h")
            guard draw(at: time + 0.01, programShowsCursor: true, row: 2, alpha: 1, named: "brief redraw show \(index)") else {
                return false
            }
        }

        inject("\u{1b}[1 q")
        setenv("UBIQUITTY_FAKE_TICKS", "40", 1)
        guard draw(at: 2, programShowsCursor: true, row: 2, alpha: 0.75, named: "normal fade begins") else { return false }
        inject("\u{1b}[?25l")
        for (index, phase) in [(42, Float(0.5)), (44, Float(0.25)), (46, Float(0)), (62, Float(0.25))].enumerated() {
            setenv("UBIQUITTY_FAKE_TICKS", String(phase.0), 1)
            guard
                draw(
                    at: 2.01 + Double(index) * 0.01,
                    programShowsCursor: false,
                    row: 2,
                    alpha: phase.1,
                    named: "held cursor follows fade \(phase.0)"
                )
            else { return false }
        }
        inject("\u{1b}[?25h")
        setenv("UBIQUITTY_FAKE_TICKS", "64", 1)
        guard draw(at: 2.049, programShowsCursor: true, row: 2, alpha: 0.5, named: "show preserves current fade") else { return false }

        inject("\u{1b}[2 q")
        guard draw(at: 3, programShowsCursor: true, row: 2, alpha: 1, named: "steady cursor restored") else { return false }
        inject("\u{1b}[?25l")
        guard draw(at: 3.01, programShowsCursor: false, row: 2, alpha: 1, named: "persistent hide starts"),
            draw(at: 3.059, programShowsCursor: false, row: 2, alpha: 1, named: "hide before deadline"),
            draw(at: 3.061, programShowsCursor: false, row: -1, alpha: 0, named: "hide after deadline"),
            draw(at: 3.08, programShowsCursor: false, row: -1, alpha: 0, named: "persistent hide stays hidden")
        else { return false }
        inject("\u{1b}[?25h")
        guard draw(at: 4, programShowsCursor: true, row: 2, alpha: 1, named: "visible after persistent hide") else { return false }
        inject("\u{1b}[?25l")
        guard draw(at: 4.01, programShowsCursor: false, row: 2, alpha: 1, named: "hide before scrollback") else { return false }
        let history = cursorSurface.drive.withTerminal { Int(Ubiquitty.Screen.scrollableRowCount($0)) } ?? 0
        guard history > 0 else { return failed("cursor suppression fixture retained no history") }
        cursorSurface.setViewOffset(absolute: history, limit: history)
        guard draw(at: 4.02, programShowsCursor: false, row: -1, alpha: 0, named: "scrollback suppresses held cursor") else { return false }
        cursorSurface.setViewOffset(absolute: 0, limit: history)
        guard draw(at: 4.03, programShowsCursor: false, row: -1, alpha: 0, named: "return does not resurrect suppressed cursor") else {
            return false
        }
        inject("\u{1b}[?25h")
        return draw(at: 4.04, programShowsCursor: true, row: 2, alpha: 1, named: "explicit show after suppression")
    }

    #if canImport(AppKit)
    /// How long an acquire takes once it has found the pool dry; the layer's
    /// own timeout is a second, and a drawable from a pool with one free comes
    /// within a display frame.
    private static let drainedPoolWaitInSeconds = 0.5

    /// The longest the display link may take to start or to stop, or the
    /// layer to answer whether an acquire waits, while an acquire on another
    /// thread waits out the layer's one-second timeout.
    private static let linkEdgeLimitInSeconds = 0.25

    /// Starts and stops the surface's display link while a thread's
    /// `nextDrawable()` on the surface's layer waits for a drawable.
    ///
    /// No link attaches while an acquire waits, since attaching would not stop
    /// it: the view's display link ticks in its place. The layer's lock covers
    /// whether an acquire waits, never the wait, a second or without end, so
    /// neither the start nor the stop waits on it.
    ///
    /// - Parameter surface: A surface in a window, its link stopped, that has
    ///   presented a frame.
    /// - Returns: Whether, under an acquire that waited out the pool's
    ///   timeout, the start and the stop each returned well inside the wait,
    ///   with the view's display link installed in place of one that delivers
    ///   the layer's drawables.
    private static func startsAndStopsUnderWaitingAcquire(_ surface: TerminalSurface) -> Bool {
        let layer = surface.surfaceLayer
        // An acquire waits only on a pool run dry. Each acquire that comes back
        // at once holds its drawable here, and the next is asked, until one
        // finds the pool dry and waits out the timeout. Only that one is
        // judged: a lock held across a wait that short would pass unseen.
        var heldAcquires: [AcquireOnThread] = []
        for _ in 0...layer.maximumDrawableCount + 1 {
            let acquire = AcquireOnThread(asking: layer)
            // Polled without turning the run loop: a display pass would ask the
            // drained pool from this thread and wait out its timeout.
            let pollDeadline = Date().addingTimeInterval(deadlineInSeconds)
            var isAcquireWaiting = false
            var longestReadSeconds: TimeInterval = 0
            while !isAcquireWaiting, !acquire.hasReturned, Date() < pollDeadline {
                let read = Date()
                isAcquireWaiting = layer.hasWaitingAcquireForTesting
                longestReadSeconds = max(longestReadSeconds, Date().timeIntervalSince(read))
                if !isAcquireWaiting {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            var startSeconds: TimeInterval = 0
            var stopSeconds: TimeInterval = 0
            var isViewLinkInPlace = false
            var waitedThroughout = false
            if isAcquireWaiting {
                let started = Date()
                surface.ensureFrameLink().start(framesPerSecond: 60)
                startSeconds = Date().timeIntervalSince(started)
                isViewLinkInPlace = surface.frameLink?.isRunning == true && surface.frameLink?.ownsDrawableDelivery == false
                let stopped = Date()
                surface.frameLink?.stop()
                stopSeconds = Date().timeIntervalSince(stopped)
                waitedThroughout = !acquire.hasReturned
            }
            guard acquire.waitForReturn(seconds: deadlineInSeconds) else {
                return failed("an acquire on another thread was still waiting for a drawable after \(deadlineInSeconds) s")
            }
            guard longestReadSeconds < linkEdgeLimitInSeconds else {
                return failed(
                    "reading whether an acquire waited took \(longestReadSeconds) s: the layer's lock covered "
                        + "an acquire's wait for a drawable"
                )
            }
            guard acquire.waitSeconds >= drainedPoolWaitInSeconds else {
                heldAcquires.append(acquire)
                continue
            }
            guard isAcquireWaiting else {
                return failed("an acquire on another thread waited \(acquire.waitSeconds) s, and the layer never saw it wait")
            }
            guard startSeconds < linkEdgeLimitInSeconds, stopSeconds < linkEdgeLimitInSeconds else {
                return failed(
                    "the display link took \(startSeconds) s to start and \(stopSeconds) s to stop while an "
                        + "acquire on another thread waited for a drawable"
                )
            }
            guard waitedThroughout else {
                return failed("the acquire on another thread returned before the display link started and stopped")
            }
            guard isViewLinkInPlace else {
                return failed("a display link took the layer's drawables under a waiting acquire, or none was installed in its place")
            }
            return true
        }
        return failed(
            "no acquire on another thread waited for a drawable with \(heldAcquires.count) of the layer's "
                + "\(layer.maximumDrawableCount) held"
        )
    }
    #endif

    /// Runs the main runloop until the condition holds or the deadline passes.
    ///
    /// - Returns: Whether the condition held.
    /// Feeds bytes to the terminal as the stream would, same thread, no shell.
    private static func feed(_ drive: RuntimeDrive, _ text: String) {
        var bytes = Array(text.utf8CString)
        bytes.removeLast() // the terminating NUL is not part of the stream
        bytes.withUnsafeBufferPointer { drive.feed($0) }
    }

    private static func spinUntil(_ isSatisfied: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(deadlineInSeconds)
        while !isSatisfied(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return isSatisfied()
    }

    /// A family both shells carry.
    private static let defaultFamilyName = "Menlo"

    // The window each shell presents. Guarded because the toolkits genuinely
    // differ here; the scenario above does not.
    #if canImport(AppKit)
    private static func present(_ surface: TerminalSurface) -> NSWindow? {
        // The runloop observers that commit a display cycle come with the
        // application object, which the smoke runs before main sets up.
        NSApplication.shared.setActivationPolicy(.accessory)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        surface.frame = frame
        // The smoke checks the draw entry, not the occlusion policy: it runs
        // on a real screen with no application to bring its window forward, so
        // the window server can report the window covered while the smoke is
        // asking whether a mark reaches a frame at all. And not the pacing
        // either: a pane that earns the panel's rate hands its drawables to
        // the link on the first delivery, and a pass the smoke calls by hand
        // then defers to a tick it never receives.
        surface.isFullyOccludedForTesting = false
        surface.isFrameLinkHeldOffForTesting = true
        window.contentView?.addSubview(surface)
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 60))
        }
        window.orderFront(nil)
        return window
    }

    private static func dismiss(_ window: NSWindow) {
        window.orderOut(nil)
    }

    /// - Returns: The window's backing scale.
    private static func windowScale(_ window: NSWindow) -> CGFloat {
        window.backingScaleFactor
    }
    #else
    private static func present(_ surface: TerminalSurface) -> UIWindow? {
        // A window belongs to a scene. One built without it is attached to no
        // screen, and nothing in it is ever asked to draw.
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            return nil
        }
        let window = UIWindow(windowScene: scene)
        surface.frame = window.bounds
        window.addSubview(surface)
        window.makeKeyAndVisible()
        return window
    }

    private static func dismiss(_ window: UIWindow) {
        window.isHidden = true
    }

    /// - Returns: The window's backing scale.
    private static func windowScale(_ window: UIWindow) -> CGFloat {
        window.screen.scale
    }

    #endif

    /// - Returns: Always false; the shell offered nowhere to present.
    private static func noWindow() -> Bool {
        failed("no window to present in")
    }

    /// - Returns: Always false, so a leg can `return failed(...)`.
    private static func failed(_ reason: String) -> Bool {
        FileHandle.standardError.write(Data("draw-entry smoke: FAILED — \(reason)\n".utf8))
        return false
    }

    /// - Returns: Always true.
    private static func passed() -> Bool {
        FileHandle.standardError.write(
            Data(
                "draw-entry smoke: ok — themes apply, the surface kept its renderer, and the shell answered two display cycles at its own scale\n"
                    .utf8
            )
        )
        return true
    }
}

#if canImport(AppKit)
/// A `nextDrawable()` call on a thread of its own, as a host's render thread
/// makes one.
///
/// What the call answered is written on the thread before it leaves
/// `returned`, and read only once a wait on `returned` has succeeded.
private final class AcquireOnThread: @unchecked Sendable {
    /// Touched on the thread for `nextDrawable()` alone, which a layer answers
    /// on any thread.
    private let layer: CAMetalLayer
    private let returned = DispatchGroup()
    /// The drawable the call was handed, kept out of the pool while this
    /// object lives.
    private var drawable: (any CAMetalDrawable)?
    private var elapsedSeconds: TimeInterval = 0

    /// Starts the thread, which asks `layer` for a drawable once and holds
    /// the one it is handed for as long as this object lives.
    ///
    /// - Parameter layer: The layer to ask.
    init(asking layer: CAMetalLayer) {
        self.layer = layer
        returned.enter()
        Thread { [self] in
            let asked = Date()
            drawable = self.layer.nextDrawable()
            elapsedSeconds = Date().timeIntervalSince(asked)
            returned.leave()
        }
        .start()
    }

    /// Whether the call has returned.
    var hasReturned: Bool { returned.wait(timeout: .now()) == .success }

    /// How long the call took; read once it has returned.
    var waitSeconds: TimeInterval {
        returned.wait()
        return elapsedSeconds
    }

    /// Waits for the call to return.
    ///
    /// - Parameter seconds: The longest to wait.
    /// - Returns: Whether the call returned in that time.
    func waitForReturn(seconds: Double) -> Bool {
        returned.wait(timeout: .now() + seconds) == .success
    }
}
#endif
