// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The selection a surface holds: what is selected, its text, and clearing it.
//
// Shared. Core owns the rules that extend a selection and the text a
// selection projects, so both shells report the same thing. What differs is
// how one is begun and where copied text goes — a drag and a pasteboard —
// and those live in the file beside this one.

// TerminalSurface+Selection.swift — text selection on a surface, by Core's rules.
//
// The whole of selection policy — gesture sequencing, word and line growth,
// wide-glyph bounds, the copy walk, the highlight spans — lives in Core's
// Terminal-bound facade (`Selection::beginGesture` and friends), so this file
// is the AppKit half only: mouse routing, the pasteboard, and the standard
// responder actions. A surface selects like NSTextView — the user drags, the
// host implements nothing.

internal import UbiquittyCore
internal import UbiquittyRenderKit

/// One surface's selection state, held where Core can address it.
///
/// Behind an allocated pointer rather than a stored property for the reason
/// the glyph cache is: Core reads the session across a call, so its address
/// has to be stable, which Swift promises for allocated memory and not for a
/// property.
@MainActor

extension TerminalSurface {
    /// The selected text, or nil when nothing is selected.
    ///
    /// Resolved the way the highlight draws — wide glyphs whole, soft-wrapped
    /// rows joined — so what the user copies is what the user sees.
    public var selectedText: String? {
        guard Ubiquitty.Selection.hasSelection(selectionModel.session.pointee) else {
            return nil
        }
        let text = drive.selectedText(selectionModel.session)
        return text.isEmpty ? nil : text
    }

    /// Whether the surface currently has a selection.
    public var hasSelection: Bool {
        Ubiquitty.Selection.hasSelection(selectionModel.session.pointee)
    }

    /// Clears the selection, if any.
    public func clearSelection() {
        if Ubiquitty.Selection.clearSelection(&selectionModel.session.pointee) {
            selectionDidChange()
        }
    }

    /// The standard Select All action.
    ///
    /// - Parameter sender: Ignored.
    override public func selectAll(_ sender: Any?) {
        drive.selectAllText(selectionModel.session)
        selectionDidChange()
    }

    /// A keystroke or paste drops the selection, the way every frontend does.
    internal func clearSelectionForUserInput() {
        clearSelection()
    }

    internal func selectionDidChange() {
        needsDisplay = true
        // VoiceOver's selected-text answers read the selection through the
        // projection, and the throttled post tells it the answer moved.
        noteAccessibilityContentChanged()
        observer?.terminalSurfaceSelectionDidChange(self)
    }
}
