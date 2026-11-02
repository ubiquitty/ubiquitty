// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Composition.swift — the composition both shells share.
//
// An input method asks a frontend the same three things on either Apple shell:
// what is being composed, what it commits, and where the candidate window
// belongs. Only the protocol that asks differs — AppKit's NSTextInputClient,
// UIKit's UITextInput — so the answers live here once and each conformance is
// the adapter that spells them.
//
// The terminal does not draw the composition. The input method draws its own
// candidate window, positioned by ``compositionAnchorRect()``, and nothing
// reaches the host until it commits: a program receiving the intermediate text
// would see every candidate the user cycled past.

internal import UbiquittyCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension TerminalSurface {
    /// Whether a composition is in flight.
    ///
    /// Outranks the terminal's claim on a key for as long as it lasts: an input
    /// method mid-composition owns every key until it commits or cancels,
    /// including the ones that would otherwise encode.
    package var isComposing: Bool {
        !markedText.isEmpty
    }

    /// The composition in flight, empty when none is.
    package var composedText: String {
        markedText
    }

    /// Replaces the composition in flight.
    ///
    /// - Parameters:
    ///   - text: The composition as the input method now spells it.
    ///   - selection: The caret or selection the input method placed inside
    ///     it, in UTF-16 units; nil puts the caret at its end.
    package func composeText(_ text: String, selecting selection: NSRange? = nil) {
        markedText = text
        markedSelection = selection ?? NSRange(location: text.utf16.count, length: 0)
        textInputGeneration &+= 1
        needsDisplay = true
    }

    /// Abandons the composition without sending it.
    ///
    /// Leaves the generation alone: a cancelled composition produced no text,
    /// and the key router reads that count to tell a consumed key from an
    /// ignored one.
    package func cancelComposition() {
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    /// Commits composed text to the host.
    ///
    /// The one path a composed string takes, and also where a plain character
    /// arrives when the input method passed it through untouched. It transmits
    /// as user input rather than writing to the drive directly, so a commit
    /// snaps to the tail and counts as activity exactly as a keystroke does.
    ///
    /// The generation moves even for empty text, because committing nothing is
    /// still the input method answering for the key.
    ///
    /// - Parameter text: The committed text.
    package func commitComposedText(_ text: String) {
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        textInputGeneration &+= 1
        transmitAsUserInput(text)
    }

    /// Where the candidate window belongs: the cursor cell, in this surface's
    /// own coordinates.
    ///
    /// - Returns: The cursor cell, or `.zero` when no cell size is known.
    package func compositionAnchorRect() -> CGRect {
        guard let cell = renderer?.drawnCellSize(for: self), cell.width > 0, cell.height > 0 else {
            return .zero
        }
        // The active screen's own cursor rather than the resolved one: the
        // resolver reports invisible on the blink-off phase, and the candidate
        // window would jump to the origin every half second.
        let position: (column: Int, row: Int) =
            drive.withTerminal { terminal in
                guard let screen = terminal.screens.active else { return (column: 0, row: 0) }
                // Held inside the grid: a cursor parked past the last column
                // waiting to wrap still composes into the last cell.
                let column = min(Int(screen.pointee.cursorX), Int(terminal.columns) - 1)
                let row = min(Int(screen.pointee.cursorY), Int(terminal.rows) - 1)
                return (column: max(0, column), row: max(0, row))
            } ?? (column: 0, row: 0)
        // Core's cellRect — the inverse of the pointer's pointToCell — so the
        // candidate window and the report path cannot disagree about where a
        // cell sits inside the letterbox. The surface is top-left on both
        // toolkits, so the one rectangle serves both.
        let insets = renderer?.gridInsets(for: self) ?? PlatformEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let box = Ubiquitty.Rendering.cellRect(
            Ubiquitty.CellPosition(row: Int32(position.row), column: Int32(position.column)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            Ubiquitty.Rendering.EdgeInsets(
                left: Float(insets.left),
                right: Float(insets.right),
                top: Float(insets.top),
                bottom: Float(insets.bottom)
            ),
            0
        )
        return CGRect(
            x: Double(box.origin.x),
            y: Double(box.origin.y) + verticalOverscroll,
            width: Double(box.size.width),
            height: Double(box.size.height)
        )
    }
}
