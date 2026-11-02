// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// This half of the surface is AppKit's: cursor rects have no counterpart on a
// touch screen, so the UIKit shell carries none of it.
//
// TerminalSurface+PointerCursor.swift — the pointer shape over the grid, and
// the one place that writes it.
//
// Cursor rects are the authority. AppKit re-applies a view's rect on every
// move, so a cursor set directly and not carried by the rect survives until the
// pointer twitches; every input that changes the answer rebuilds the rect and
// applies it once, and frame presentation never writes cursor state at all.
// The rect is rebuilt from `invalidateCursorRects(for:)` on every edge rather
// than only when the geometry moves: the shape answers to what Core published
// and to what the keyboard is holding, neither of which the rect's own bounds
// know anything about. The tracking area beside it reports the moves; this
// decides what they mean.

#if canImport(AppKit)

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// The facts this shell knows about the pointer that the model does not.
    ///
    /// Every rung of Core's ladder that is a frontend's to answer is gathered
    /// here: the lock, the hovered link, the armed window drag, the armed
    /// block select, whether a drag would reach through an application that is
    /// tracking the mouse, whether the pointer stands in a row's trailing void,
    /// and whether a selection drag is running. The ranking between them is
    /// Core's alone.
    private var pointerContext: Ubiquitty.Input.PointerContext {
        var context = Ubiquitty.Input.PointerContext()
        context.isPointerLocked = isPointerLocked
        context.isOverLink = isShowingLinkAffordance
        // One state for both answers below, because they are one question
        // asked twice. A drag in flight was opened with its chord and stays
        // local for as long as it runs, whatever is held now — Core keeps an
        // open gesture local by the same reasoning — so it answers for the
        // chord that opened it rather than for the keyboard.
        let reporting = pointerReportingState(
            modifiers: NSEvent.modifierFlags,
            isBlockSelectionInFlight: isRectangularDragInFlight
        )
        // Ranked above the block-select crosshair by Core: in a window the
        // reader can only move by its body, the move wins.
        context.isWindowDragArmed = isWindowDragArmed
        context.isRectangularSelectArmed = Ubiquitty.Input.localDragIsRectangular(reporting)
        context.isOverTextVoid = isPointerOverTextVoid
        // Reported, not acted on: a drag already running outranks the void's
        // arrow, and the ranking between every fact here is Core's.
        context.isSelectionDragInFlight = isSelectionDragInFlight
        // Whether that block would be made at all over a tracking application
        // is `Input::allowsLocalDragSelect` — the same predicate the press
        // itself is routed by, so the crosshair cannot promise a selection the
        // press would not make.
        context.selectionBypassesMouseReporting = Ubiquitty.Input.allowsLocalDragSelect(reporting)
        return context
    }

    /// The shape Core ranks for this surface, off the published snapshot.
    private var resolvedPointerShape: Ubiquitty.PAL.MousePointerShape {
        Ubiquitty.Input.pointerShape(drive.readSnapshot(), pointerContext)
    }

    /// The cursor this surface shows under the pointer.
    ///
    /// The ranking is Core's, not this shell's: `Input::pointerShape` ranks a
    /// hovered link above an application's shape, an application's shape above
    /// a tracking program, and a tracking program above the I-beam, off the same
    /// snapshot the rest of the chrome reads. The mapping from shape to cursor
    /// is the component both shells call.
    package var pointerCursor: NSCursor {
        PointerShapeCursor.cursor(for: resolvedPointerShape)
    }

    /// Adopts what the last drain published about the pointer.
    ///
    /// Applied on the edge only: rebuilding the rect and setting the cursor per
    /// drain would fight AppKit's own machinery, and the shape is unchanged on
    /// all but a handful of drains in a session's life.
    internal func updatePointerCursorFromSnapshot() {
        let snapshot = drive.readSnapshot()
        appPointerShape = snapshot.isAppPointerShapeSet ? snapshot.appRequestedPointerShape : nil
        let shape = Ubiquitty.Input.pointerShape(snapshot, pointerContext)
        guard shape != installedPointerShape else { return }
        applyPointerCursor()
    }

    /// Rebuilds the cursor rect and shows the cursor it now carries.
    ///
    /// The rect is this surface's and is rebuilt regardless; the immediate set
    /// is global, so only the surface under the pointer in the key window
    /// performs it — a background tab's own output must not take the pointer
    /// from the window the reader is in.
    internal func applyPointerCursor() {
        installedPointerShape = resolvedPointerShape
        window?.invalidateCursorRects(for: self)
        guard let window, window.isKeyWindow,
            bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { return }
        pointerCursor.set()
    }

    /// Claims the whole visible surface for the resolved cursor.
    override public func resetCursorRects() {
        addCursorRect(visibleRect, cursor: pointerCursor)
    }
}

#endif
