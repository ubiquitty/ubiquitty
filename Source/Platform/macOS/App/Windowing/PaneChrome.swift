// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// PaneChrome.swift — one pane's frame: a title bar over the pane's own view.
//
// A split pane wears a bar carrying its title, a close button, and an expand
// button that swaps to a contract glyph while this pane is the zoomed one. Both
// shells build panes, so both wear this: a bar written twice is a bar that comes
// to differ in its height, its gutters, or which of the two buttons yields its
// slot, and a reader switching shells would see their splits change shape.
//
// The layout is done in `setFrameSize` rather than by autoresizing, because the
// bar's height is exact: an autoresized bar rounds with the container and the
// buttons drift off the vertical centre by a fraction that shows.
//
// A split pane's OSC 9;4 report is drawn here too, in a band that never moves
// the pane's view: along the bar's bottom edge, inside the height the bar has
// whether a report runs or not, and with the bar off, over the top edge of the
// view, which keeps its whole frame. The band is the view's sibling rather than
// a layer in its subtree, because a comet animating inside a `CAMetalLayer`'s
// tree re-snaps the grid's rows as it loops.
//

import AppKit
package import UbiquittyRenderKit

/// One pane's title bar and the view it frames.
///
/// Owns the bar, its two buttons, the centred title and the pane's progress
/// band, and lays them out against its own bounds.
@MainActor
@objc(UBPaneChrome)
public final class PaneChrome: NSView {
    /// The bar's height in points, and the metric every gutter below is measured
    /// against. A pane shorter than this gets a bar clipped to what it has
    /// rather than a bar taller than the pane.
    @objc
    public static let titleBarHeight: CGFloat = 28.0

    /// The tallest a button may be, and the shortest gutter around it.
    private static let maxButtonSize: CGFloat = 16.0
    private static let edgeInset: CGFloat = 4.0
    private static let buttonGap: CGFloat = 4.0
    private static let gutterAfterButtons: CGFloat = 6.0
    private static let labelHeight: CGFloat = 16.0

    @objc
    public private(set) var paneID: Int32 = 0

    /// The pane's own view, framed below the bar.
    ///
    /// Nil again once the view leaves for another superview. A re-mirrored
    /// tree frames each pane in a bar of its own, and the bar left behind
    /// must not size the view to the split it used to stand in: a zoomed
    /// pane laid out again by its old bar keeps its split grid, so its
    /// program is never told the zoomed one.
    @objc
    public var contentView: NSView? {
        get { framedView }
        set {
            framedView?.removeFromSuperview()
            framedView = newValue
            if let newValue {
                addSubview(newValue, positioned: .below, relativeTo: titleBar)
            }
            layoutChrome()
        }
    }

    private var framedView: NSView?

    override public func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        if subview === framedView {
            framedView = nil
        }
    }

    /// Whether the bar is drawn at all. With it off the pane's view fills the
    /// container.
    @objc
    public var showsTitleBar: Bool = true {
        didSet {
            titleBar.isHidden = !showsTitleBar
            layoutChrome()
        }
    }

    /// Whether the expand button is offered. A tmux pane has no local zoom, and
    /// a button that cannot act yields its slot so the title gutter stays tight.
    @objc
    public var showsExpandButton: Bool = true {
        didSet {
            expandButton.isHidden = !showsExpandButton
            layoutChrome()
        }
    }

    private final class TitleBar: NSView {
        override func cursorUpdate(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    private let titleBar = TitleBar(frame: .zero)

    /// Identifies the draggable title area without consuming its buttons.
    package func isTransferHandle(at point: NSPoint) -> Bool {
        guard showsTitleBar, titleBar.frame.contains(point) else { return false }
        return !closeButton.bounds.contains(closeButton.convert(point, from: self))
            && !expandButton.bounds.contains(expandButton.convert(point, from: self))
            && (presenceIndicator.isHidden || !presenceIndicator.bounds.contains(presenceIndicator.convert(point, from: self)))
    }
    private let closeButton: NSButton
    private let expandButton: NSButton
    private let titleLabel = NSTextField(labelWithString: "")

    /// The pane's status, or its progress, at the bar's trailing end: the
    /// mark a tab's accessory shows for a tab, for this pane.
    public let statusMark = TabStatusMark(frame: .zero)

    /// The clients attached to this pane's session, independent of keyboard focus.
    package let presenceIndicator = SessionPresenceIndicator(frame: .zero)

    /// Updates the pane's roster without changing the terminal's frame.
    package func updatePresence(
        _ attendees: [RuntimeDrive.Attendee],
        screenAccesses: [RuntimeDrive.ScreenAccess] = [],
        hasUnread: Bool = false
    ) {
        presenceIndicator.apply(attendees, screenAccesses: screenAccesses, hasUnread: hasUnread)
        presenceIndicator.isHidden = !presenceIndicator.hasVisibleActivity
        layoutChrome()
    }

    /// The band the pane's OSC 9;4 report is drawn in while the window is
    /// split.
    ///
    /// Above the bar and the pane's view in z-order, so it shows over either.
    private let progressBand = ProgressBar(frame: .zero)

    /// Builds a pane's chrome.
    ///
    /// - Parameters:
    ///   - paneID: The pane this frames; carried on both buttons as their tag so
    ///     one action method can tell which pane was clicked.
    ///   - target: The object both buttons message.
    ///   - closeAction: The selector the close button sends.
    ///   - expandAction: The selector the expand button sends.
    @objc
    public init(paneID: Int32, target: AnyObject?, closeAction: Selector, expandAction: Selector) {
        closeButton = PaneChrome.chromeButton(
            symbol: "xmark",
            fallback: "✕",
            tooltip: "Close pane",
            target: target,
            action: closeAction,
            tag: paneID
        )
        expandButton = PaneChrome.chromeButton(
            symbol: "arrow.down.left.and.arrow.up.right",
            fallback: "⤢",
            tooltip: "Expand pane",
            target: target,
            action: expandAction,
            tag: paneID
        )
        super.init(frame: .zero)
        self.paneID = paneID
        autoresizesSubviews = false // setFrameSize lays everything out

        titleBar.wantsLayer = true
        titleBar.setAccessibilityIdentifier("pane.titleBar")
        addSubview(titleBar)

        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center
        titleLabel.setAccessibilityIdentifier("pane.title")
        titleBar.addSubview(closeButton)
        titleBar.addSubview(expandButton)
        titleBar.addSubview(titleLabel)
        titleBar.addSubview(statusMark)
        presenceIndicator.isHidden = true
        presenceIndicator.setAccessibilityIdentifier("pane.presence")
        titleBar.addSubview(presenceIndicator)

        // Flush square ends and no groove: the band spans the pane's whole
        // width, and a pill with a hairline track reads as a control.
        progressBand.capRadius = 0
        progressBand.borderWidth = 0
        progressBand.trackColor = .clear
        progressBand.isHidden = true
        addSubview(progressBand, positioned: .above, relativeTo: titleBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneChrome is built in code")
    }

    /// What the bar's last restyle was made from.
    ///
    /// Every field the restyle reads is a member: one left out is a change that
    /// cannot reach the bar, because the memo answers first and the restyle
    /// never runs.
    private struct AppliedChrome: Equatable {
        var title: NSAttributedString?
        var background: NSColor
        var tint: NSColor
        var isExpanded: Bool
    }

    /// The inputs the bar currently stands on, or nil before the first restyle.
    private var appliedChrome: AppliedChrome?

    /// The width the title's text may take, between the buttons and their
    /// mirror and inside the field's own margins: what a label is fitted to.
    /// Laid out from the bar's width, never the text's.
    package var titleRoom: CGFloat { titleLabel.alignmentRect(forFrame: titleLabel.frame).width }

    /// Told when a layout gives the title another width, so its label can be
    /// fitted to it again.
    package var titleRoomDidChange: (() -> Void)?

    /// The expand and contract glyphs, resolved once.
    ///
    /// `NSImage(systemSymbolName:)` goes to the asset catalog on every call, and
    /// the bar asks for the same two glyphs for the life of the process.
    private static let expandGlyph = PaneChrome.templateSymbol("arrow.down.left.and.arrow.up.right")
    private static let contractGlyph = PaneChrome.templateSymbol("arrow.up.right.and.arrow.down.left")

    /// Loads one symbol as a template image, so a tint can colour it.
    ///
    /// - Parameter name: The SF Symbol's name.
    /// - Returns: The image, or nil when the running system has no such symbol.
    private static func templateSymbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    /// Shows one OSC 9;4 report on the pane's band, or takes the band away.
    ///
    /// - Parameters:
    ///   - state: A `Ubiquitty::OSC::ProgressState`, as stored on the wire;
    ///     `ProgressNone` hides the band.
    ///   - value: The percent, 0 to 100, for the determinate states.
    ///   - tint: The colour the report's role resolves to.
    @objc
    public func showProgress(state: UInt8, value: UInt8, tint: NSColor) {
        progressBand.tintColor = tint
        progressBand.setState(state, value: value)
    }

    /// Restyles the bar in place, without rebuilding it.
    ///
    /// Returns without touching the bar when nothing it draws has moved. Pane
    /// output drives the restyle, so this runs on every drain, and re-applying
    /// an unchanged bar spends an attributed-string rebuild, an AppKit text
    /// relayout and a geometry pass putting back what is already on screen. The
    /// memo covers the whole parameter list, so the bar cannot be left standing
    /// on a title the model has moved past.
    ///
    /// - Parameters:
    ///   - title: The pane's title, baked by the shared tab-title styling.
    ///   - background: The bar's fill.
    ///   - tint: The ink for the buttons.
    ///   - isExpanded: Whether this pane is the zoomed one, which swaps the
    ///     expand glyph for a contract glyph and tints it as the system accent.
    @objc
    public func apply(title: NSAttributedString?, background: NSColor, tint: NSColor, isExpanded: Bool) {
        let requested = AppliedChrome(title: title, background: background, tint: tint, isExpanded: isExpanded)
        if appliedChrome == requested {
            return
        }
        appliedChrome = requested
        // The title is centred here rather than in the shared bake: a tab label
        // reads left-aligned, and changing that there would move the tab strip.
        var shown = title ?? NSAttributedString()
        if shown.length > 0 {
            let styled = NSMutableParagraphStyle()
            styled.alignment = .center
            styled.lineBreakMode = .byTruncatingMiddle
            let mutable = NSMutableAttributedString(attributedString: shown)
            mutable.addAttribute(.paragraphStyle, value: styled, range: NSRange(location: 0, length: mutable.length))
            shown = mutable
        }
        titleLabel.attributedStringValue = shown
        // PaneHostView supplies the window's glass; a second material here
        // would tint an already blurred backdrop instead of sharing it.
        titleBar.layer?.backgroundColor = background.cgColor
        closeButton.contentTintColor = tint

        if let image = isExpanded ? PaneChrome.contractGlyph : PaneChrome.expandGlyph {
            expandButton.image = image
        }
        expandButton.contentTintColor = isExpanded ? .systemBlue : tint
        expandButton.toolTip = isExpanded ? "Contract pane" : "Expand pane"
        layoutChrome()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChrome()
    }

    private func layoutChrome() {
        let width = bounds.width
        let height = bounds.height
        // Clipped to the pane rather than allowed to exceed it: a pane dragged
        // shorter than the bar keeps a bar it can hold.
        let barHeight = showsTitleBar ? min(PaneChrome.titleBarHeight, height) : 0.0

        // Non-flipped coordinates: the bar pins to the top, the pane below it.
        titleBar.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: max(0.0, height - barHeight))

        // Along the bar's bottom edge when the bar can hold it, and otherwise
        // over the view's top edge; the view's frame is the same either way.
        let bandHeight = min(ProgressBar.bandHeightInPoints, height)
        let bandY = barHeight >= bandHeight ? height - barHeight : height - bandHeight
        progressBand.frame = NSRect(x: 0, y: bandY, width: width, height: bandHeight)

        let buttonSize = min(PaneChrome.maxButtonSize, max(0.0, barHeight - 2.0))
        let buttonY = (barHeight - buttonSize) * 0.5

        var x = PaneChrome.edgeInset
        closeButton.frame = NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize)
        x += buttonSize + PaneChrome.buttonGap
        if expandButton.isHidden {
            expandButton.frame = .zero
        } else {
            expandButton.frame = NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize)
            x += buttonSize + PaneChrome.gutterAfterButtons
        }

        // The same inset on both sides, so a centred title clears the buttons
        // instead of sitting centred over them.
        let markSize = statusMark.intrinsicContentSize
        let markX = width - PaneChrome.edgeInset - PaneChrome.gutterAfterButtons - markSize.width
        var trailingInset = width - markX
        if !presenceIndicator.isHidden {
            let size = presenceIndicator.fittingSize
            presenceIndicator.frame = NSRect(
                x: markX - PaneChrome.buttonGap - size.width,
                y: ((barHeight - size.height) * 0.5).rounded(),
                width: size.width,
                height: size.height
            )
            trailingInset = width - presenceIndicator.frame.minX + PaneChrome.gutterAfterButtons
        }
        let inset = max(x + PaneChrome.edgeInset, trailingInset)
        let labelY = (barHeight - PaneChrome.labelHeight) * 0.5
        let previousRoom = titleLabel.frame.width
        titleLabel.frame = NSRect(
            x: inset,
            y: labelY,
            width: max(0.0, width - 2.0 * inset),
            height: PaneChrome.labelHeight
        )
        if abs(titleLabel.frame.width - previousRoom) > 0.5, let titleRoomDidChange {
            DispatchQueue.main.async { titleRoomDidChange() }
        }
        // In the trailing gutter the buttons' mirror leaves, so the centred
        // title stays centred whatever the mark shows.
        statusMark.frame = NSRect(
            x: markX,
            y: ((barHeight - markSize.height) * 0.5).rounded(),
            width: markSize.width,
            height: markSize.height
        )
    }

    private static func chromeButton(
        symbol: String,
        fallback: String,
        tooltip: String,
        target: AnyObject?,
        action: Selector,
        tag: Int32
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.isTemplate = true
            button.image = image
        } else {
            // A system without the symbol still gets a button that reads as one.
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(
                string: fallback,
                attributes: [.font: NSFont.systemFont(ofSize: 11.0)]
            )
        }
        button.toolTip = tooltip
        button.target = target
        button.action = action
        button.tag = Int(tag)
        button.setAccessibilityIdentifier(symbol == "xmark" ? "pane.close" : "pane.expand")
        return button
    }
}
