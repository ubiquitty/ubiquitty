// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Accessibility.swift — the surface as one assistive-reader
// text area. The visible grid renders as pixels, so accessibility gets a
// parallel projection: flat text plus per-row UTF-16 ranges, derived by
// Core's one projection rule (`Accessibility::projectVisibleText`) — every
// screen-read in the product must produce the same characters — and cached
// here until the next screen delivery marks it stale.
//
// The projection is shared; the protocol serving it is each shell's own.
// AppKit answers the NSAccessibility text-area selectors, caret and
// selection included. UIKit publishes the text as the element's value —
// which is also what lets a UI test assert on what the terminal actually
// shows, rather than on chrome around it.

import Foundation
internal import UbiquittyCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension TerminalSurface {
    /// The projection cache, rebuilt lazily under the model lock.
    ///
    /// - Returns: The flat visible text, NSString-indexed by the row ranges.
    internal func accessibilityRebuiltText() -> NSString {
        if !isAccessibilityTextDirty, let cached = accessibilityCachedText {
            return cached
        }
        var text: NSString = ""
        var ranges: [NSRange] = []
        // The projection is kept whole beside its NSString: the caret and
        // selection mapping are Core's, and they index the projection itself
        // rather than a converted copy.
        accessibilityCachedProjection = drive.withTerminal { terminal in
            let projection = Ubiquitty.Accessibility.projectVisibleText(terminal, Int32(viewOffset))
            text = NSString(utf8String: String(projection.text)) ?? ""
            for range in projection.lineRanges {
                ranges.append(NSRange(location: Int(range.location), length: Int(range.length)))
            }
            return projection
        }
        accessibilityCachedText = text
        accessibilityLineRanges = ranges
        isAccessibilityTextDirty = false
        return text
    }
}

#if canImport(AppKit)

extension TerminalSurface {
    /// The visible caret as an index into the projection, or nil when the
    /// cursor is off-screen — scrolled back — or unavailable. The clamp rule
    /// is Core's (`caretInProjection`); this brackets the lock and converts.
    internal func accessibilityInsertionIndex() -> Int? {
        _ = accessibilityRebuiltText()
        guard let projection = accessibilityCachedProjection else {
            return nil
        }
        guard
            let caret = drive.withTerminal({
                Ubiquitty.Accessibility.caretInProjection(projection, $0, viewOffset)
            }), caret.isValid
        else {
            return nil
        }
        return Int(caret.location)
    }

    /// The selection as a range in the projection, or nil when there is none
    /// or it lies wholly off-screen. The row mapping and the clamps are
    /// Core's (`selectionInProjection`); this brackets the lock and converts.
    internal func accessibilitySelectionRange() -> NSRange? {
        _ = accessibilityRebuiltText()
        guard let projection = accessibilityCachedProjection else {
            return nil
        }
        let history =
            drive.withTerminal {
                Int(Ubiquitty.Screen.scrollableRowCount($0))
            } ?? 0
        let range = Ubiquitty.Selection.selectionInProjection(
            projection,
            selectionModel.session.pointee.state,
            history,
            viewOffset
        )
        guard range.isValid else {
            return nil
        }
        return NSRange(location: Int(range.location), length: Int(range.length))
    }

    /// Marks the projection stale and coalesces the VoiceOver value-changed
    /// post through Core's throttle; this side supplies the clock and the
    /// timer.

    // MARK: - NSAccessibility

    override public func isAccessibilityElement() -> Bool {
        true
    }

    override public func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override public func accessibilityRoleDescription() -> String? {
        NSAccessibility.Role.textArea.description(with: nil)
    }

    override public func accessibilityLabel() -> String? {
        "Terminal"
    }

    override public func accessibilityValue() -> Any? {
        accessibilityRebuiltText()
    }

    override public func accessibilityNumberOfCharacters() -> Int {
        accessibilityRebuiltText().length
    }

    override public func accessibilitySelectedText() -> String? {
        guard let range = accessibilitySelectionRange() else {
            return ""
        }
        let text = accessibilityRebuiltText()
        guard NSMaxRange(range) <= text.length else {
            return ""
        }
        return text.substring(with: range)
    }

    override public func accessibilitySelectedTextRange() -> NSRange {
        if let range = accessibilitySelectionRange() {
            return range
        }
        // No selection: the insertion point as an empty range, so VoiceOver
        // has a caret to announce.
        guard let caret = accessibilityInsertionIndex() else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: caret, length: 0)
    }

    override public func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityRebuiltText().length)
    }

    override public func accessibilityInsertionPointLineNumber() -> Int {
        guard let caret = accessibilityInsertionIndex() else {
            return 0
        }
        return accessibilityLine(for: caret)
    }

    override public func accessibilityLine(for index: Int) -> Int {
        _ = accessibilityRebuiltText()
        for (line, range) in accessibilityLineRanges.enumerated() where index <= NSMaxRange(range) {
            return line
        }
        return accessibilityLineRanges.isEmpty ? 0 : accessibilityLineRanges.count - 1
    }

    override public func accessibilityRange(forLine line: Int) -> NSRange {
        _ = accessibilityRebuiltText()
        guard line >= 0, line < accessibilityLineRanges.count else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityLineRanges[line]
    }

    override public func accessibilityString(for range: NSRange) -> String? {
        let text = accessibilityRebuiltText()
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else {
            return ""
        }
        return text.substring(with: range)
    }

    override public func accessibilityRange(for index: Int) -> NSRange {
        let text = accessibilityRebuiltText()
        guard index >= 0, index < text.length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: index, length: 1)
    }
}

#else

extension TerminalSurface {
    /// The visible text as the element's value.
    ///
    /// UIKit has no text-area protocol for a custom view to adopt the way
    /// AppKit does, so the projection is served whole through the one
    /// attribute every reader queries. The setter forwards: the stored value
    /// UIKit keeps for ordinary views has no meaning for a surface whose
    /// value is derived.
    override public var accessibilityValue: String? {
        get { accessibilityRebuiltText() as String }
        set { super.accessibilityValue = newValue }
    }
}

#endif
