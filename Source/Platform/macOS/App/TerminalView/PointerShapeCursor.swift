// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// PointerShapeCursor.swift — an OSC 22 portable pointer shape as a native cursor.
//
// The single mapping both shells read: the ObjC terminal view through the
// raw-value shim, the Swift surface through the typed one. A frontend holding
// its own switch is how "progress" comes to mean the busy pointer on one arm
// and the plain arrow on the other, which nobody would notice until a program
// asked for it.
//
// Several CSS/X11 names have no public AppKit cursor on the 13.0 baseline;
// those resolve to the nearest stock cursor. The private selectors are reached
// by name and guarded by -respondsToSelector:, with a public fallback each, so
// the mapping degrades rather than traps when one of them goes.
//

import AppKit
import UbiquittyCore

/// The native cursor for an application-requested pointer shape.
@objc(UBPointerShapeCursor)
@MainActor
public final class PointerShapeCursor: NSObject {
    /// The closest native cursor for a portable shape.
    ///
    /// - Parameter shape: The shape Core resolved from the OSC 22 stack.
    /// - Returns: The cursor to install.
    // swift-only: the ObjC caller crosses through the raw-value shim below; a C++ enum parameter has no printer representation
    public static func cursor(for shape: Ubiquitty.PAL.MousePointerShape) -> NSCursor {
        switch shape {
        case .default: return .arrow
        case .pointer: return .pointingHand
        case .text: return .iBeam
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .crosshair: return .crosshair
        case .cell: return .crosshair // spreadsheet-style cell select
        case .move: return .openHand // no dedicated move cursor pre-15
        case .grab: return .openHand
        case .grabbing: return .closedHand
        case .noDrop, .notAllowed: return .operationNotAllowed
        case .alias: return .dragLink
        case .copy: return .dragCopy
        // Private selector, public fallback if it ever goes.
        case .help: return systemCursor(named: "_helpCursor") ?? .arrow
        // CSS separates the two — `progress` is busy-but-interactive, `wait` is
        // busy-and-blocked — and macOS gives an application only the first: the
        // blocking spinner is the window server's, not ours to set. So both take
        // the busy-but-clickable pointer, which is the closest thing that exists
        // rather than the arrow, and `wait` is knowingly the generous reading.
        case .progress, .wait: return systemCursor(named: "busyButClickableCursor") ?? .arrow
        case .zoomIn, .zoomOut: return .crosshair // no public zoom cursor on the baseline
        case .colResize: return .resizeLeftRight // ew / col — horizontal drag
        case .rowResize: return .resizeUpDown // ns / row — vertical drag
        // AppKit ships no public diagonal resize cursor, so a window corner
        // would look identical to an edge; the public fallback is the vertical
        // one, which is at least a resize.
        case .nwseResize: return systemCursor(named: "_windowResizeNorthWestSouthEastCursor") ?? .resizeUpDown
        case .neswResize: return systemCursor(named: "_windowResizeNorthEastSouthWestCursor") ?? .resizeUpDown
        case .northResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .top, directions: .outward) }
            return .resizeUp
        case .northeastResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .topRight, directions: .outward) }
            return systemCursor(named: "_windowResizeNorthEastCursor") ?? .resizeUpDown
        case .eastResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .right, directions: .outward) }
            return .resizeRight
        case .southeastResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .bottomRight, directions: .outward) }
            return systemCursor(named: "_windowResizeSouthEastCursor") ?? .resizeUpDown
        case .southResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .bottom, directions: .outward) }
            return .resizeDown
        case .southwestResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .bottomLeft, directions: .outward) }
            return systemCursor(named: "_windowResizeSouthWestCursor") ?? .resizeUpDown
        case .westResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .left, directions: .outward) }
            return .resizeLeft
        case .northwestResize:
            if #available(macOS 15.0, *) { return .frameResize(position: .topLeft, directions: .outward) }
            return systemCursor(named: "_windowResizeNorthWestCursor") ?? .resizeUpDown
        }
    }

    /// The closest native cursor for a shape given by its raw value.
    ///
    /// A C++ enum cannot cross an `@objc` signature, and duplicating it in
    /// Swift would put the mapping in two places — which is what moving it here
    /// just undid. The raw value crosses instead; an unrecognised one is the
    /// default shape, which is the answer an unknown OSC 22 name already gets.
    /// Checked against the last case by hand, because the enum is closed and
    /// the importer traps on a value outside it rather than answering nil; the
    /// exhaustive switch above is what fails the build when Core adds a case,
    /// and this bound moves with it.
    ///
    /// - Parameter rawValue: The `Ubiquitty::MousePointerShape` value.
    /// - Returns: The cursor to install.
    @objc(cursorForPointerShapeRawValue:)
    public static func cursor(forPointerShapeRawValue rawValue: Int) -> NSCursor {
        guard let raw = UInt8(exactly: rawValue), raw <= Ubiquitty.PAL.MousePointerShape.northwestResize.rawValue,
            let shape = Ubiquitty.PAL.MousePointerShape(rawValue: raw)
        else { return cursor(for: .default) }
        return cursor(for: shape)
    }

    /// A cursor AppKit does not declare, reached by selector name.
    ///
    /// - Parameter selectorName: The undeclared class method's name.
    /// - Returns: The cursor, or nil when this system does not supply it.
    private static func systemCursor(named selectorName: String) -> NSCursor? {
        let selector = NSSelectorFromString(selectorName)
        let cursorClass: AnyObject = NSCursor.self
        guard cursorClass.responds(to: selector) else { return nil }
        return cursorClass.perform(selector)?.takeUnretainedValue() as? NSCursor
    }
}
