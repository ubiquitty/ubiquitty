// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// HintAccessory.swift — the words that teach a gesture nobody can see, shown in
// the title row's trailing bar.
//
// Two of this terminal's gestures are invisible until someone says they exist:
// the pointer lock an application takes, and the modifier that reaches through
// an application which swallowed the drag. Core decides when either is worth
// teaching, what it says, and how long it stands; this view is the window's
// place to put the words, and it holds no clock of its own — the surface asks
// Core again when Core says a lesson fades, and hands this an empty string.
//
// The title row rather than the grid, because the grid belongs to the program.
// A shell with no chrome to spare draws Core's in-grid toast instead — same
// text, same lifetime, different surface — and a window that has a title row
// should not paint over the program's output to say something about the window.
//
// It sits furthest from the trailing edge, behind the lock, the clipboard badge
// and the roster. Those state conditions that persist and are worth a fixed
// place; a hint is a sentence that arrives and leaves, and it must not push
// them around as it comes and goes. Being a sentence, it is also the one thing
// in the row that may be cut short: in a narrow window it truncates at the
// window buttons rather than being drawn over them.
//
// A line whose owner hands it a dismissal — the configuration diagnostic, a
// fact about a file the reader may not mean to fix yet — takes a click or an
// accessibility press to dismiss; a teaching line takes neither, because its
// lifetime is Core's.

@preconcurrency import AppKit

/// The teaching line in a window's accessory bar.
@objc(UBHintAccessory)
public final class HintAccessory: NSTextField {
    /// Behind every badge: a hint is transient, and the badges are not.
    @objc
    public static let priority = 40

    private weak var bar: ChromeAccessoryBar?

    /// What a press does to the line shown now; nil when it is not dismissible.
    private var dismissal: (() -> Void)?

    /// Puts a hint line into a bar, hidden until Core has words for it.
    ///
    /// - Parameter bar: The window's accessory bar.
    /// - Returns: The installed line.
    @objc
    @discardableResult
    public static func install(in bar: ChromeAccessoryBar) -> HintAccessory {
        let hint = HintAccessory(labelWithString: "")
        hint.bar = bar
        hint.isHidden = true
        hint.font = .systemFont(ofSize: ChromeTypography.scaled(11))
        // Secondary, like the badges beside it: this is a courtesy, not an
        // alert, and a hint that competes with the title trains people to
        // stop reading the title.
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.usesSingleLineMode = true
        hint.maximumNumberOfLines = 1
        hint.cell?.truncatesLastVisibleLine = true
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setAccessibilityRole(.staticText)
        bar.add(hint, priority: priority, isCompressible: true)
        return hint
    }

    /// Shows Core's words, or withdraws the line when there are none.
    ///
    /// - Parameter text: What to show, empty for nothing.
    @objc(showText:)
    public func show(_ text: String) {
        show(text, onDismiss: nil)
    }

    /// Shows words a press may dismiss, or withdraws the line.
    ///
    /// - Parameters:
    ///   - text: What to show, empty for nothing.
    ///   - onDismiss: What a click or an accessibility press does; nil for a
    ///     line that is not the reader's to dismiss.
    public func show(_ text: String, onDismiss: (() -> Void)?) {
        dismissal = text.isEmpty ? nil : onDismiss
        toolTip = dismissal == nil ? nil : "Click to dismiss"
        setAccessibilityRole(dismissal == nil ? .staticText : .button)
        guard !text.isEmpty else {
            guard !isHidden else { return }
            stringValue = ""
            setAccessibilityLabel(nil)
            bar?.setShown(self, false)
            return
        }
        stringValue = text
        setAccessibilityLabel(text)
        sizeToFit()
        bar?.setShown(self, true)
        bar?.relayout()
    }

    override public var mouseDownCanMoveWindow: Bool { dismissal == nil } // bool-ok: AppKit override

    override public func mouseDown(with event: NSEvent) {
        guard let dismissal else {
            super.mouseDown(with: event)
            return
        }
        dismissal()
    }

    override public func accessibilityPerformPress() -> Bool {
        guard let dismissal else { return false }
        dismissal()
        return true
    }
}
