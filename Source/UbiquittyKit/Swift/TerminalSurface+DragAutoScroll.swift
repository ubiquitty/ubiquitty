// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+DragAutoScroll.swift — a selection drag held past an edge
// keeps selecting.
//
// The rows it wants are off screen, so the view has to walk toward them while
// the button is down. AppKit delivers no events for a pointer that has stopped
// moving, so a timer is what turns "held outside" into repeated work — that
// part is the platform's shape and lives here.
//
// How far each tick moves is not: `Input::dragAutoScrollStep` answers that, and
// the Metal arm asks it the same question. What is left here is the timer, the
// held point, and re-offering the drag at that point so the selection follows
// the rows arriving under it.

internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit

extension TerminalSurface {
    /// Notes where a held drag is, arming or stopping the walk.
    ///
    /// Called on every drag event, including the ones inside the grid: a drag
    /// that comes back over the grid must stop walking, and this is the event
    /// that says so.
    ///
    /// - Parameter point: The drag's location, in view coordinates.
    internal func noteDragAutoScroll(atViewPoint point: CGPoint) {
        dragAutoScrollPoint = point
        guard let row = signedRow(atViewPoint: point) else {
            stopDragAutoScroll()
            return
        }
        guard Ubiquitty.Input.dragAutoScrollStep(Int32(row), Int32(publishedGrid.rows)).isOutsideGrid else {
            stopDragAutoScroll()
            return
        }
        guard dragAutoScrollTimer == nil else { return }
        // Tracking mode too, or the timer stops for the whole gesture: a drag
        // is exactly when the run loop is in event tracking.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dragAutoScrollTick()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        RunLoop.current.add(timer, forMode: .default)
        dragAutoScrollTimer = timer
    }

    /// Ends the walk. Idempotent, and called from the release path whether or
    /// not one was running.
    internal func stopDragAutoScroll() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
    }

    /// One step of the walk.
    private func dragAutoScrollTick() {
        guard let row = signedRow(atViewPoint: dragAutoScrollPoint) else {
            stopDragAutoScroll()
            return
        }
        let step = Ubiquitty.Input.dragAutoScrollStep(Int32(row), Int32(publishedGrid.rows))
        guard step.isOutsideGrid else {
            stopDragAutoScroll()
            return
        }
        let before = viewOffset
        offsetView(byLines: Int(step.lines))
        // The rows under the held point are new ones, so the gesture is offered
        // the same point again and Core extends the selection onto them. The
        // fact's own row is the clamped one, which is what a selection wants:
        // the edge row is the furthest the user can have meant.
        if let fact = makePointerFact(
            atViewPoint: dragAutoScrollPoint,
            kind: .motion,
            button: .left,
            isDragging: true
        ) {
            _ = forward(fact)
        }
        // A buffer extreme: the selection has just been taken to the edge, and
        // walking further would spin a timer against a view that cannot move.
        if viewOffset == before {
            stopDragAutoScroll()
        }
    }
}
#endif
