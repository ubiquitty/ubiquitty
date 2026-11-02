// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+PointerFacts.swift — a point on the surface becomes a fact
// Core routes.
//
// The toolkit halves differ in how an event arrives and in nothing else: a
// mouse press, a trackpad swipe and a finger drag all resolve to a cell, a
// pixel and a set of held modifiers, and every decision after that — report to
// the program, extend a selection, move the view, fold the wheel into cursor
// keys — is the session's ladder. So the translation from a view point to a
// fact lives here once, and AppKit and UIKit each supply only what their own
// events carry.
//
// The surface uses a top-left origin on both toolkits (`isFlipped` is true on
// AppKit), so a view point needs no vertical mirror to cross between them.

import CoreGraphics
internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#endif

extension TerminalSurface {
    /// Clamps a report to the visible part of a translated host picture.
    /// - Parameter point: The original view point, before overscroll conversion.
    /// - Returns: The nearest visible point, or nil for an empty viewport.
    private func visibleReportPoint(_ point: CGPoint) -> CGPoint? {
        guard let clip = renderer?.contentClip(for: self) else { return point }
        guard !clip.isEmpty else { return nil }
        return CGPoint(x: min(max(point.x, clip.minX), clip.maxX.nextDown), y: min(max(point.y, clip.minY), clip.maxY.nextDown))
    }

    /// The report cell under a view point.
    ///
    /// The one point-to-cell mapping — `Rendering.cellRect` is its inverse.
    /// Two spellings of this arithmetic select one cell and report its
    /// neighbour, so a press and the release that ends it must both come
    /// through here.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The zero-based cell, or nil before a cell has been measured.
    internal func reportCell(atViewPoint point: CGPoint) -> (row: Int32, column: Int32)? {
        guard let visiblePoint = visibleReportPoint(point) else { return nil }
        let point = CGPoint(x: visiblePoint.x, y: visiblePoint.y - verticalOverscroll)
        guard let renderer else { return nil }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return nil }
        let insets = renderer.gridInsets(for: self)
        // A non-owner's drawable may hold more or fewer cells than the host's
        // picture. Only that picture can supply content or receive a report.
        guard let picture = renderer.presentedGeometry(for: self) else { return nil }
        guard picture.columns > 0, picture.rows > 0 else { return nil }
        let position = Ubiquitty.Rendering.pointToCell(
            Ubiquitty.FloatPoint(x: Float(point.x), y: Float(point.y)),
            Ubiquitty.FloatPoint(x: Float(insets.left), y: Float(insets.top)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            Ubiquitty.GridSize(columns: picture.columns, rows: picture.rows),
            .Clamped
        )
        // On a row the frame laid out as proportional runs the column is the
        // letter under the point, which Core answers from the layout it drew.
        let column = renderer.letterColumn(for: self, row: position.row, xInCells: Double((point.x - insets.left) / cell.width))
        return (position.row, column ?? position.column)
    }

    /// The strict hit and clamped report for a scenario comparing a host grid
    /// with this surface's independently sized drawable.
    /// - Parameter point: A point in the surface's coordinates.
    /// - Returns: The two mappings, without sending input or changing selection.
    package func gridHitForTesting(atViewPoint point: CGPoint) -> (strict: (row: Int, column: Int)?, report: (row: Int32, column: Int32)?) {
        (strictCell(atViewPoint: point), reportCell(atViewPoint: point))
    }

    /// The cell under a view point, or nil when the point is off the grid.
    ///
    /// ``reportCell(atViewPoint:)`` clamps, which is right for a report — an
    /// application is told about a cell that exists — and wrong for a question
    /// about what the pointer is over: a click in the padding below the last
    /// row would otherwise answer with that row's content, and a menu built
    /// from it offers to copy something nobody pointed at.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The zero-based cell, or nil off the grid.
    internal func strictCell(atViewPoint point: CGPoint) -> (row: Int, column: Int)? {
        if let clip = renderer?.contentClip(for: self), !clip.contains(point) { return nil }
        let point = CGPoint(x: point.x, y: point.y - verticalOverscroll)
        guard let renderer else { return nil }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return nil }
        let insets = renderer.gridInsets(for: self)
        guard let picture = renderer.presentedGeometry(for: self) else { return nil }
        guard picture.columns > 0, picture.rows > 0 else { return nil }
        // pointToCell's clamp policy applies only to rows; columns always
        // clamp for reporting. Reject horizontal padding before that mapping.
        guard point.x >= insets.left,
            point.x < insets.left + CGFloat(picture.columns) * cell.width
        else { return nil }
        let position = Ubiquitty.Rendering.pointToCell(
            Ubiquitty.FloatPoint(x: Float(point.x), y: Float(point.y)),
            Ubiquitty.FloatPoint(x: Float(insets.left), y: Float(insets.top)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            Ubiquitty.GridSize(columns: picture.columns, rows: picture.rows),
            .Unclamped
        )
        guard position.row >= 0, position.row < picture.rows,
            position.column >= 0, position.column < picture.columns
        else {
            return nil
        }
        let column = renderer.letterColumn(for: self, row: position.row, xInCells: Double((point.x - insets.left) / cell.width))
        return (Int(position.row), Int(column ?? position.column))
    }

    /// The centre of a cell, in view coordinates.
    ///
    /// The inverse of ``reportCell(atViewPoint:)``, and the centre rather than
    /// the origin so a caller converting back cannot land on a boundary and
    /// round into the neighbour.
    ///
    /// - Parameters:
    ///   - row: A zero-based visible row.
    ///   - column: A zero-based column.
    /// - Returns: The point, or nil before a cell has been measured.
    package func viewPoint(forRow row: Int, column: Int) -> CGPoint? {
        guard let renderer else { return nil }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return nil }
        let insets = renderer.gridInsets(for: self)
        return CGPoint(
            x: insets.left + (CGFloat(column) + 0.5) * cell.width,
            y: insets.top + (CGFloat(row) + 0.5) * cell.height + verticalOverscroll
        )
    }

    /// The row under a view point, not clamped to the grid.
    ///
    /// Negative above the first row, at or beyond the row count below the
    /// last. ``reportCell(atViewPoint:)`` clamps, which is right for a report —
    /// an application is told about a cell that exists — and wrong for a drag,
    /// because a clamped row cannot tell "resting on the last row" from
    /// "dragged out of the window", and those ask for opposite things.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The signed row, or nil before a cell has been measured.
    internal func signedRow(atViewPoint point: CGPoint) -> Int? {
        let point = CGPoint(x: point.x, y: point.y - verticalOverscroll)
        guard let renderer else { return nil }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.height > 0 else { return nil }
        let insets = renderer.gridInsets(for: self)
        guard let picture = renderer.presentedGeometry(for: self) else { return nil }
        let position = Ubiquitty.Rendering.pointToCell(
            Ubiquitty.FloatPoint(x: Float(point.x), y: Float(point.y)),
            Ubiquitty.FloatPoint(x: Float(insets.left), y: Float(insets.top)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            Ubiquitty.GridSize(columns: picture.columns, rows: picture.rows),
            .Unclamped
        )
        return Int(position.row)
    }

    /// The device pixel under a view point, 1-based from the reported origin.
    ///
    /// Read only under SGR-pixels (DECSET 1016) and ignored otherwise.
    ///
    /// The current mode chooses the origin before a new frame is drawn. A
    /// fullscreen frame can have zero insets, so a reset uses the grid's fit.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The pixel coordinates.
    internal func reportPixel(atViewPoint point: CGPoint) -> (x: Int, y: Int) {
        guard let visiblePoint = visibleReportPoint(point) else { return (1, 1) }
        let point = CGPoint(x: visiblePoint.x, y: visiblePoint.y - verticalOverscroll)
        guard let renderer, let picture = renderer.presentedGeometry(for: self) else { return (1, 1) }
        let isFullscreenContentActive = drive.readSnapshot().modes.isFullscreenContentActive
        let insets =
            picture.isFullscreenContentActive && !isFullscreenContentActive
            ? renderer.gridFitInsets(for: self) : picture.insets
        let scale = picture.deviceScale
        let pixel = Ubiquitty.Rendering.reportedDevicePixel(
            Ubiquitty.FloatPoint(x: Float(point.x), y: Float(point.y)),
            Ubiquitty.FloatPoint(x: Float(insets.left), y: Float(insets.top)),
            Float(scale),
            isFullscreenContentActive ? .Drawable : .Grid
        )
        return (Int(pixel.x), Int(pixel.y))
    }

    /// Where a view point sits along its row, in cells from the grid's left
    /// edge and unrounded.
    ///
    /// A boundary is all a monospace row needs, and inside a proportional run
    /// several letters' ink begins in one cell, so Core needs the position
    /// itself to say which letter the reader aimed at. Cells rather than pixels because
    /// the grid's pitch is the one length both sides know; Core turns it into
    /// a caret, so this shell holds no rule of its own about where letters
    /// sit. A point in the inset either side of the grid clamps onto the grid,
    /// which puts it on the row's first or last caret.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The position in cells, or nil before a cell has been measured.
    private func caretXInCells(atViewPoint point: CGPoint) -> Double? {
        guard let renderer else { return nil }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return nil }
        let insets = renderer.gridInsets(for: self)
        let x = Double((point.x - insets.left) / cell.width)
        // On a row the frame laid out as proportional runs the position is the
        // letter under the point plus the fraction of it crossed, from Core's
        // layout, so the caret the ladder rounds to is a letter boundary.
        guard let picture = renderer.presentedGeometry(for: self) else { return nil }
        if picture.rows > 0, picture.columns > 0 {
            let position = Ubiquitty.Rendering.pointToCell(
                Ubiquitty.FloatPoint(x: Float(point.x), y: Float(point.y - verticalOverscroll)),
                Ubiquitty.FloatPoint(x: Float(insets.left), y: Float(insets.top)),
                Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
                Ubiquitty.GridSize(columns: picture.columns, rows: picture.rows),
                .Clamped
            )
            if let onLetters = renderer.letterXInCells(for: self, row: position.row, xInCells: x) {
                return onLetters
            }
        }
        return min(max(x, 0), Double(max(0, picture.columns)))
    }

    /// Where down the grid a view point is, in rows, unrounded.
    ///
    /// The signed position preserves a drag beyond the grid so Core can
    /// select through the edge row. Rich text also uses the fractional part
    /// to hit-test lines within a block.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The signed position from the grid's top, or nil before a
    ///   cell has been measured.
    private func caretYInRows(atViewPoint point: CGPoint) -> Double? {
        guard let renderer else { return nil }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.height > 0 else { return nil }
        let insets = renderer.gridInsets(for: self)
        return Double((point.y - verticalOverscroll - insets.top) / cell.height)
    }

    /// Fills the fields every pointer fact carries, whatever produced it.
    ///
    /// - Parameters:
    ///   - point: Where the pointer is, in view coordinates.
    ///   - kind: Press, release or motion.
    ///   - button: Which button, in Core's identity.
    ///   - clickCount: How many clicks this press continues; 1 for a single.
    ///   - isDragging: Whether a button is down and the motion extends a gesture.
    ///   - modifiers: The held modifiers.
    /// - Returns: The fact, or nil before a cell has been measured.
    internal func makePointerFact(
        atViewPoint point: CGPoint,
        kind: Ubiquitty.Runtime.TerminalSession.PointerFact.Kind,
        button: Ubiquitty.Input.PointerButton,
        clickCount: Int = 1,
        isDragging: Bool = false,
        modifiers: SurfaceModifiers = SurfaceModifiers()
    ) -> Ubiquitty.Runtime.TerminalSession.PointerFact? {
        guard let cell = reportCell(atViewPoint: point) else { return nil }
        let pixel = reportPixel(atViewPoint: point)
        var fact = Ubiquitty.Runtime.TerminalSession.PointerFact()
        fact.kind = kind
        fact.button = button
        fact.row = Int(cell.row)
        fact.column = Int(cell.column)
        fact.pixelX = pixel.x
        fact.pixelY = pixel.y
        fact.hasShift = modifiers.hasShift
        fact.hasAlternate = modifiers.hasAlternate
        fact.hasControl = modifiers.hasControl
        fact.hasCommand = modifiers.hasCommand
        fact.heldButtonBits = heldButtonBits
        fact.clickCount = clickCount
        fact.viewOffset = viewOffset
        fact.isDragging = isDragging
        // Where along the row the pointer is, unrounded. The caret a plain
        // press or drag stands on, and the letter a word press grows from
        // inside a proportional run, are Core's to resolve from it, under the
        // model lock the ladder holds: resolved here first, a drag's event
        // would lose its caret whenever the renderer held the lock, and fall
        // to whole cells for that one motion.
        fact.xInCells = caretXInCells(atViewPoint: point) ?? .nan
        fact.yInRows = caretYInRows(atViewPoint: point) ?? .nan
        return fact
    }

    /// The buttons held right now, as DECLRP's Pb bitmap in DEC's bit order.
    ///
    /// AppKit's global mask already includes a press and excludes its own
    /// release; a touch surface has no held-button set to report.
    private var heldButtonBits: Int {
        #if canImport(AppKit)
        let held = NSEvent.pressedMouseButtons
        var bits = 0
        if held & (1 << 0) != 0 { bits |= Int(Ubiquitty.Mouse.Locator.buttonBit(0)) }
        if held & (1 << 1) != 0 { bits |= Int(Ubiquitty.Mouse.Locator.buttonBit(2)) }
        if held & (1 << 2) != 0 { bits |= Int(Ubiquitty.Mouse.Locator.buttonBit(1)) }
        return bits
        #else
        return 0
        #endif
    }

    /// Runs one pointer fact through Core's ladder and applies what comes back.
    ///
    /// - Parameter fact: The fact to route.
    /// - Returns: Whether Core consumed the event. False leaves it to the
    ///   toolkit's own handling.
    @discardableResult
    internal func forward(_ fact: Ubiquitty.Runtime.TerminalSession.PointerFact) -> Bool {
        if fact.kind == .press || fact.kind == .release {
            noteUserActivity()
        }
        let outcome = drive.pointerFact(fact, selection: selectionModel.session)
        // Whether a press opened a selection is Core's answer rather than this
        // shell's guess: a press an application receives opens none, and the
        // affordances reading this latch — the pointer's shape over the void,
        // the link hover's re-resolve — must not act as though a drag were
        // running. Presses only; the walk past an edge re-offers a motion.
        if fact.kind == .press {
            isSelectionDragInFlight = outcome.didOpenSelectionGesture
        }
        if outcome.needsDisplay {
            needsDisplay = true
            frameClock.noteAnimationActivity()
        }
        if outcome.didChangeSelection {
            noteAccessibilityContentChanged()
            observer?.terminalSurfaceSelectionDidChange(self)
        }
        refreshHint()
        return outcome.wasConsumed
    }

    /// Asks Core what hint should be showing and tells the observer when the
    /// answer changed.
    ///
    /// The whole of this arm's hint logic. Core keeps the words, the budget
    /// and the clock; the surface forwards a changed answer and books the one
    /// wake-up Core names, so a lesson fades without a frame of its own.
    /// Called after any pointer fact, after any grab report, on every screen
    /// update, and when that wake-up fires.
    /// Asks Core what to teach and relays a changed answer, for a caller
    /// driving the facts it reads.
    package func refreshHintForTesting() {
        refreshHint()
    }

    internal func refreshHint() {
        let text = drive.hintTextShowing()
        if text != shownHintText {
            shownHintText = text
            observer?.terminalSurface(self, didChangeHint: text)
        }
        let ticks = drive.hintTicksUntilExpiry()
        guard ticks != 0, !isHintRecheckScheduled else { return }
        isHintRecheckScheduled = true
        // One tick past the expiry, so the re-ask lands on its far side.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ticks + 1) / 60.0) { [weak self] in
            guard let self else { return }
            self.isHintRecheckScheduled = false
            self.refreshHint()
        }
    }

    /// Runs one scroll gesture through Core's wheel ladder and applies what
    /// comes back.
    ///
    /// The route — report to the program, fold into cursor keys, or move the
    /// local view — is the session's, so a toolkit supplies the deltas and
    /// learns only how far the view moved.
    ///
    /// - Parameters:
    ///   - point: Where the pointer is, in view coordinates.
    ///   - deltaX: The horizontal delta, in the toolkit's units.
    ///   - deltaY: The vertical delta; positive brings older history in.
    ///   - isPrecise: Whether the deltas are continuous rather than notched.
    ///   - isDirectTouch: Whether a finger is dragging the screen.
    ///   - modifiers: The held modifiers.
    /// - Returns: Whether the gesture was consumed.
    @discardableResult
    internal func forwardScroll(
        atViewPoint point: CGPoint,
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        isDirectTouch: Bool = false,
        modifiers: SurfaceModifiers = SurfaceModifiers()
    ) -> Bool {
        var fact = Ubiquitty.Runtime.TerminalSession.ScrollFact()
        fact.deltaX = deltaX
        fact.deltaY = deltaY
        fact.isPrecise = isPrecise
        fact.isDirectTouch = isDirectTouch
        if let cell = reportCell(atViewPoint: point) {
            fact.row = Int(cell.row)
            fact.column = Int(cell.column)
        }
        let pixel = reportPixel(atViewPoint: point)
        fact.pixelX = pixel.x
        fact.pixelY = pixel.y
        fact.hasShift = modifiers.hasShift
        fact.hasAlternate = modifiers.hasAlternate
        fact.hasControl = modifiers.hasControl

        let outcome = drive.scrollFact(fact, tuning: wheelTuning)
        if outcome.linesToOffsetView != 0 {
            offsetView(byLines: Int(outcome.linesToOffsetView))
        }
        return outcome.wasConsumed
    }
}

/// The modifiers a pointer fact carries, as facts rather than a platform mask.
///
/// Separate from either toolkit's flag set because the terminal's question is
/// which of three keys was down, and a mask answers a different one — it also
/// carries keys no report has a bit for.
internal struct SurfaceModifiers {
    var hasShift = false
    var hasAlternate = false
    var hasControl = false
    var hasCommand = false

    /// - Parameters:
    ///   - hasShift: Whether Shift was down.
    ///   - hasAlternate: Whether Alt/Option was down.
    ///   - hasControl: Whether Control was down.
    ///   - hasCommand: Whether Command (Super) was down.
    init(hasShift: Bool = false, hasAlternate: Bool = false, hasControl: Bool = false, hasCommand: Bool = false) {
        self.hasShift = hasShift
        self.hasAlternate = hasAlternate
        self.hasControl = hasControl
        self.hasCommand = hasCommand
    }
}
