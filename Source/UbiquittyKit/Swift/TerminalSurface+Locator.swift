// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Locator.swift — the DEC locator's arm edge.
//
// DECELR (CSI Ps ; Ps ' z) arms a pointer-reporting route parallel to the
// xterm mouse modes, and the route is Core's: every pointer fact this surface
// builds carries the cell, the device pixel and the held buttons in DEC's bit
// order, and the ladder's first rung records the locator's position, answers
// the transitions DECSLE selected in the unit DECELR chose, reports a DECEFR
// rectangle leave, and disarms a one-shot locator after its report. A press
// or release the locator reported is consumed, so no selection or context
// menu follows it.
//
// What only a frontend can say is where a pointer that has not moved is.
// xterm always knows where its locator is, so on the off-to-on arm edge this
// surface publishes the stationary pointer's position, and a DECRQLP arriving
// before the next move answers it instead of an undefined position. The published bit is
// read once per delivery, never per pointer event, and only a pointer over
// this surface is published: a position outside it is not a truthful answer.

import CoreGraphics
internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#endif

extension TerminalSurface {
    /// Mirrors the published DECELR bit, and on its off-to-on edge tells the
    /// locator where the pointer already is.
    ///
    /// Called on every delivery. Idempotent while the bit stands: the edge is
    /// the only moment the surface acts on it, because every pointer event
    /// after that reaches the locator through the ladder.
    internal func reconcileLocatorArm() {
        let isArmed = drive.readSnapshot().locatorActive
        let isArmEdge = isArmed && !isLocatorArmed
        isLocatorArmed = isArmed
        guard isArmEdge, let point = locatorPointerViewPoint else {
            return
        }
        seedLocator(atViewPoint: point)
    }

    /// Tells the locator a stationary pointer stands at a view point.
    ///
    /// Core runs the locator's rung alone, so the seed is never taken for a
    /// move by any-event tracking or the selection. It is normally silent —
    /// DECELR has just cancelled any filter rectangle — but a DECEFR in the
    /// same drain can have armed one the pointer already stands outside, and
    /// that report is sent rather than dropped.
    ///
    /// - Parameter point: The pointer, in view coordinates; a point outside
    ///   the surface publishes nothing.
    internal func seedLocator(atViewPoint point: CGPoint) {
        guard bounds.contains(point), let fact = makePointerFact(atViewPoint: point, kind: .motion, button: .none) else {
            return
        }
        drive.seedLocator(fact)
    }

    /// Where the pointer stands, in view coordinates, or nil when this surface
    /// cannot say.
    ///
    /// AppKit asks the window server, which answers for a pointer that has
    /// not moved since before the window existed. A touch surface has no
    /// pointer standing anywhere between touches, so it publishes nothing and
    /// the locator's first position is the first event's.
    private var locatorPointerViewPoint: CGPoint? {
        if let locatorPointerOverrideForTesting {
            return locatorPointerOverrideForTesting
        }
        #if canImport(AppKit)
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        #else
        return nil
        #endif
    }
}
