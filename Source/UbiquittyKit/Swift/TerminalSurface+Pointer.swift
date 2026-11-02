// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// This half of the surface is AppKit's. The events it answers — mouse
// buttons, a scroll wheel with momentum, NSEvent modifier flags, the
// AppKit text-input client — have no counterpart on a touch screen, so the
// UIKit shell answers its own and neither carries the other's model.
//
// Guarded rather than moved: it extends the shared surface, and keeping it
// beside what it extends is what stops the two halves drifting apart.

#if canImport(AppKit)

// TerminalSurface+Pointer.swift — pointer events become mouse reports.
//
// The surface forwards every event and lets Core refuse the ones no tracking
// mode asked for, which is the contract `Mouse::encodeReport` states: the modes
// set on the Terminal decide whether an event reports at all. A frontend that
// gates first has to spell the disjunction of five DECSET modes itself, and the
// one left out is 1001 — it reports like 1000 with a highlight handshake on top,
// so a reader who thinks of it as a highlight feature drops it from the list.
//
// The report is encoded under the model lock. It reads the Terminal's live mode
// state and its cell-pixel basis, both of which the ingest thread rewrites.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// Maps AppKit's button number to the portable identity.
    ///
    /// - Parameter number: What AppKit reported for an "other" button.
    /// - Returns: The portable button; `Other` for anything past the four xterm
    ///   encodes, which the encoder then declines rather than reporting as a
    ///   button the application would read as left-click.
    internal static func otherButton(_ number: Int) -> Ubiquitty.Input.PointerButton {
        switch number {
        case 2: .middle
        case 3: .button8
        case 4: .button9
        case 5: .button10
        case 6: .button11
        default: .other
        }
    }

    /// The report cell under an event's pointer, or nil without a measured
    /// cell — the basis the report encoder and the hilite gesture share, so
    /// a press and its end report cannot quantise to different cells.
    ///
    /// - Parameter event: The AppKit event.
    /// - Returns: The zero-based cell.
    internal func reportCell(for event: NSEvent) -> (row: Int32, column: Int32)? {
        reportCell(atViewPoint: convert(event.locationInWindow, from: nil))
    }
}

#endif
