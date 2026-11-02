// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore

/// Receives user-driven scrollback positions from a terminal's native scroll bar.
@objc(UBTerminalScrollerDelegate)
@MainActor
public protocol TerminalScrollerDelegate: AnyObject {
    /// Moves the viewport to an offset above the live tail.
    func terminalScroller(_ scroller: TerminalScroller, didScrollToOffsetLines lines: Int)
}

/// Projects terminal history onto an AppKit-managed scroll bar.
///
/// Core owns the viewport and wheel handling; AppKit owns scroller drawing,
/// tracking, and fading. An empty document mirrors the terminal's scroll extent.
@objc(UBTerminalScroller)
@MainActor
public final class TerminalScroller: NSView {
    @objc
    public weak var scrollerDelegate: TerminalScrollerDelegate?

    /// Receives the native content displacement in top-left viewport coordinates.
    public var onOverscrollChange: (@MainActor (CGFloat) -> Void)? {
        didSet { refreshConfiguration() }
    }

    /// Restricts elastic scrollback to the primary terminal screen.
    public var isPrimaryScreen = true {
        didSet {
            if isPrimaryScreen != oldValue { refreshConfiguration() }
        }
    }

    /// Applies the scroll preference to this viewport, including a bounce in progress.
    public func refreshConfiguration() {
        let enabled =
            isPrimaryScreen && onOverscrollChange != nil
            && Ubiquitty.Preferences.Effective.scrollBounce(Ubiquitty.Preferences.values().pointee)
        let elasticity: NSScrollView.Elasticity = enabled ? .allowed : .none
        guard scrollView.verticalScrollElasticity != elasticity else { return }
        scrollView.verticalScrollElasticity = elasticity
        if !enabled {
            let clip = scrollView.contentView
            let maximum = max(0, document.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, clip.bounds.minY))))
            scrollView.reflectScrolledClipView(clip)
            publishOverscroll()
        }
        applyGeometry()
    }

    private var isBounceEnabled: Bool { scrollView.verticalScrollElasticity == .allowed }

    /// Selects a knob tint against the terminal background.
    @objc
    public var knobStyle: NSScroller.KnobStyle {
        get { scrollView.scrollerKnobStyle }
        set { scrollView.scrollerKnobStyle = newValue }
    }

    @MainActor
    private final class ScrollHost: NSScrollView {
        var onWheel: (@MainActor (NSEvent) -> Void)?
        var onReflect: (@MainActor () -> Void)?
        var onScrollerAction: (@MainActor (NSScroller) -> Void)?
        var onTile: (@MainActor () -> Void)?
        var suppressNativeReflection = false

        override func tile() {
            super.tile()
            onTile?()
        }

        @objc
        func scrollerDidAct(_ sender: NSScroller) {
            onScrollerAction?(sender)
        }

        override func reflectScrolledClipView(_ clipView: NSClipView) {
            if !suppressNativeReflection { super.reflectScrolledClipView(clipView) }
            // Core's history, rather than the empty clip view, defines the knob.
            onReflect?()
        }

        override func scrollWheel(with event: NSEvent) {
            onWheel?(event)
        }

        func noteScrollWheel(_ event: NSEvent) {
            super.scrollWheel(with: event)
        }
    }

    private final class HistoryExtent: NSView {
        override var isFlipped: Bool { true }
    }

    private final class ViewportClip: NSClipView {
        var interruptedOrigin: (@MainActor () -> CGFloat?)?

        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var bounds = super.constrainBoundsRect(proposedBounds)
            // Queued native animation frames must not undo an input-driven viewport reset.
            if let origin = interruptedOrigin?() { bounds.origin.y = origin }
            return bounds
        }
    }

    private let scrollView = ScrollHost()
    private let document = HistoryExtent()
    private var scrollbackLines = 0
    private var viewOffsetLines = 0
    private var viewportRowCount = 0
    private var forceHidden = false
    private var bottomInset: CGFloat = 0
    private var isApplyingModel = false
    private var isHandlingWheel = false
    private var parkedPush: (lines: Int, offset: Int, rows: Int, reveal: Bool)?
    private var overscrollOffset: CGFloat = 0
    private var ignoresCancelledGesture = false
    private var isHandlingScrollerAction = false

    /// Ends elastic motion and rejects the remaining events of the interrupted gesture.
    public func cancelScrollGesture() {
        ignoresCancelledGesture = true
        let elasticity = scrollView.verticalScrollElasticity
        scrollView.verticalScrollElasticity = .none
        synchronizeClipOrigin()
        scrollView.verticalScrollElasticity = elasticity
        publishOverscroll()
    }

    /// Determines whether an event belongs to a fresh gesture after an interruption.
    ///
    /// - Parameter event: The incoming wheel event.
    /// - Returns: Whether the event may move the viewport.
    public func acceptsScrollWheel(_ event: NSEvent) -> Bool {
        if !event.phase.intersection([.mayBegin, .began]).isEmpty
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        {
            ignoresCancelledGesture = false
        }
        return !ignoresCancelledGesture
    }

    private func synchronizeClipOrigin() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: modelClipOrigin))
        scrollView.reflectScrolledClipView(clip)
    }

    private var modelClipOrigin: CGFloat {
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        return scrollbackLines > 0 ? maximum * CGFloat(scrollbackLines - viewOffsetLines) / CGFloat(scrollbackLines) : 0
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.scrollerInsets = NSEdgeInsetsZero
        let clip = ViewportClip()
        clip.drawsBackground = false
        clip.interruptedOrigin = { [weak self] in
            guard let self, self.ignoresCancelledGesture else { return nil }
            return self.modelClipOrigin
        }
        scrollView.contentView = clip
        scrollView.documentView = document
        scrollView.verticalScroller?.target = scrollView
        scrollView.verticalScroller?.action = #selector(ScrollHost.scrollerDidAct(_:))
        scrollView.onWheel = { [weak self] event in self?.scrollWheel(with: event) }
        scrollView.onReflect = { [weak self] in
            self?.applyKnobPosition()
            self?.publishOverscroll()
        }
        scrollView.onScrollerAction = { [weak self] scroller in self?.scrollerDidAct(scroller) }
        scrollView.onTile = { [weak self] in self?.layoutScroller() }
        addSubview(scrollView)
        isHidden = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferredScrollerStyleDidChange(_:)),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Adopts the terminal's history and viewport without feeding the change back to Core.
    @objc(updateWithScrollbackLines:viewOffsetLines:viewportRows:reveal:)
    public func update(scrollbackLines lines: Int, viewOffsetLines offset: Int, viewportRows rows: Int, reveal: Bool) {
        refreshConfiguration()
        if RunLoop.current.currentMode == .eventTracking, !inLiveResize {
            if parkedPush == nil {
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated { self?.applyParkedPush() }
                }
            }
            parkedPush = (lines, offset, rows, reveal)
            return
        }
        parkedPush = nil
        let historyChanged = scrollbackLines != max(0, lines)
        let rowsChanged = viewportRowCount != max(0, rows)
        let offsetChanged = viewOffsetLines != max(0, min(offset, max(0, lines)))
        scrollbackLines = max(0, lines)
        viewportRowCount = max(0, rows)
        viewOffsetLines = max(0, min(offset, scrollbackLines))
        if historyChanged || rowsChanged {
            applyGeometry()
        } else {
            if offsetChanged, !isHandlingWheel { synchronizeClipOrigin() }
            applyKnobPosition()
        }
        publishOverscroll()
        if reveal, !isHidden, !isHandlingWheel { scrollView.flashScrollers() }
    }

    /// Applies the terminal application's scrollbar visibility override.
    @objc
    public func setScrollbarVisible(_ visible: Bool) {
        guard forceHidden == visible else { return }
        forceHidden = !visible
        applyGeometry()
        if !isHidden { scrollView.flashScrollers() }
    }

    /// The clearance between the scroll bar and a rounded window's bottom edge.
    public var bottomInsetPoints: CGFloat { bottomInset }

    @objc
    public func setBottomInsetPoints(_ points: CGFloat) {
        let clamped = max(0, points)
        guard clamped != bottomInset else { return }
        bottomInset = clamped
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        applyGeometry()
    }

    private func applyGeometry() {
        guard !isApplyingModel else { return }
        isApplyingModel = true
        scrollView.suppressNativeReflection = true
        defer {
            isApplyingModel = false
            scrollView.suppressNativeReflection = false
        }
        isHidden = forceHidden || (scrollbackLines == 0 && !isBounceEnabled) || viewportRowCount == 0
        scrollView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY + bottomInset,
            width: bounds.width,
            height: max(0, bounds.height - bottomInset)
        )
        scrollView.tile()
        let viewport = scrollView.contentView.bounds.size
        let lineHeight = viewportRowCount > 0 ? viewport.height / CGFloat(viewportRowCount) : 0
        document.setFrameSize(NSSize(width: viewport.width, height: viewport.height + CGFloat(scrollbackLines) * lineHeight))
        scrollView.tile()
        synchronizeClipOrigin()
        applyKnobPosition()
        layoutScroller()
        publishOverscroll()
    }

    private func publishOverscroll() {
        let maximum = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        let origin = scrollView.contentView.bounds.minY
        let offset: CGFloat
        if isBounceEnabled, !isHidden, !isApplyingModel, viewOffsetLines == scrollbackLines, origin < 0 {
            offset = -origin
        } else if isBounceEnabled, !isHidden, !isApplyingModel, viewOffsetLines == 0, origin > maximum {
            offset = maximum - origin
        } else {
            offset = 0
        }
        guard offset != overscrollOffset else { return }
        overscrollOffset = offset
        onOverscrollChange?(offset)
    }

    private func layoutScroller() {
        guard let scroller = scrollView.verticalScroller, scroller.isEnabled else { return }
        let slot = scroller.rect(for: .knobSlot)
        guard slot.height > 0 else { return }
        let topInset = scroller.isFlipped ? slot.minY - scroller.bounds.minY : scroller.bounds.maxY - slot.maxY
        let slotBottomInset = scroller.isFlipped ? scroller.bounds.maxY - slot.maxY : slot.minY - scroller.bounds.minY
        let rightMargin = max(0, bounds.maxX - convert(scroller.rect(for: .knob), from: scroller).maxX)
        let bottomOutset = slotBottomInset - (bottomInset > 0 ? 0 : rightMargin)
        // The slot's internal padding must not add to the terminal's corner clearance.
        let topOutset = max(0, topInset - 1)
        var frame = scroller.frame
        frame.origin.y = scrollView.bounds.minY - (scrollView.isFlipped ? topOutset : bottomOutset)
        frame.size.height = scrollView.bounds.height + topOutset + bottomOutset
        scroller.frame = frame
    }

    private func applyKnobPosition() {
        guard !isHandlingScrollerAction else { return }
        guard let scroller = scrollView.verticalScroller else { return }
        scroller.isEnabled = !isHidden && scrollbackLines > 0
        let origin = scrollView.contentView.bounds.minY
        let maximum = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        // AppKit compresses the knob against the edge during elastic scrolling.
        if isBounceEnabled, !isApplyingModel,
            viewOffsetLines == scrollbackLines && origin < 0 || viewOffsetLines == 0 && origin > maximum
        {
            return
        }
        let total = CGFloat(scrollbackLines) + CGFloat(viewportRowCount)
        scroller.knobProportion = total > 0 ? CGFloat(viewportRowCount) / total : 1
        scroller.doubleValue = scrollbackLines > 0 ? Double(scrollbackLines - viewOffsetLines) / Double(scrollbackLines) : 0
    }

    @objc
    private func scrollerDidAct(_ sender: NSScroller) {
        guard !isHidden, scrollbackLines > 0 else { return }
        ignoresCancelledGesture = false
        // Only a control action moves Core's viewport.
        let pageLines = Int(Ubiquitty.Keys.pageLinesForRows(viewportRowCount))
        let offset: Int
        switch sender.hitPart {
        case .decrementPage:
            offset = viewOffsetLines + pageLines
        case .incrementPage:
            offset = viewOffsetLines - pageLines
        case .decrementLine:
            offset = viewOffsetLines + 1
        case .incrementLine:
            offset = viewOffsetLines - 1
        default:
            offset = scrollbackLines - Int((sender.doubleValue * Double(scrollbackLines)).rounded())
        }
        let clamped = max(0, min(offset, scrollbackLines))
        viewOffsetLines = clamped
        // Native tracking owns the knob and its grab offset until the action returns.
        // A viewport move changes neither the document extent nor the track geometry.
        isHandlingScrollerAction = true
        defer { isHandlingScrollerAction = false }
        synchronizeClipOrigin()
        scrollerDelegate?.terminalScroller(self, didScrollToOffsetLines: clamped)
    }

    private func applyParkedPush() {
        if let push = parkedPush {
            parkedPush = nil
            update(scrollbackLines: push.lines, viewOffsetLines: push.offset, viewportRows: push.rows, reveal: push.reveal)
        }
    }

    @objc
    private func preferredScrollerStyleDidChange(_ notification: Notification) {
        needsLayout = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let scroller = scrollView.verticalScroller, let hit = super.hitTest(point),
            hit === scroller || hit.isDescendant(of: scroller)
        else { return nil }
        return hit
    }

    public override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    /// Delivers a complete native gesture without flashing at each whole-row update.
    @objc
    public func updateForScrollWheel(_ event: NSEvent, updateViewport: () -> Void) {
        refreshConfiguration()
        isHandlingWheel = true
        defer { isHandlingWheel = false }
        if isHidden {
            updateViewport()
            return
        }
        let startsGesture = !event.phase.intersection([.mayBegin, .began]).isEmpty
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        let wasOverscrolling = isBounceEnabled && overscrollOffset != 0
        // AppKit owns the clip origin throughout a gesture, including its settling motion.
        if !wasOverscrolling, startsGesture || isDiscreteWheel {
            let lineHeight = viewportRowCount > 0 ? scrollView.contentView.bounds.height / CGFloat(viewportRowCount) : 0
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(scrollbackLines - viewOffsetLines) * lineHeight))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollView.noteScrollWheel(event)
        if wasOverscrolling {
            let clip = scrollView.contentView
            let maximum = max(0, document.bounds.height - clip.bounds.height)
            let origin = min(maximum, max(0, clip.bounds.minY))
            // A reversing gesture first consumes the stretch. Only the distance
            // back inside the document can advance terminal rows.
            if maximum > 0 {
                let offset = Int((CGFloat(scrollbackLines) * (1 - origin / maximum)).rounded())
                if offset != viewOffsetLines {
                    viewOffsetLines = offset
                    scrollerDelegate?.terminalScroller(self, didScrollToOffsetLines: offset)
                }
            }
        } else {
            updateViewport()
        }
        if isBounceEnabled, !wasOverscrolling, scrollbackLines > 0 {
            let clip = scrollView.contentView
            let maximum = max(0, document.bounds.height - clip.bounds.height)
            let origin = clip.bounds.minY
            // Core's wheel tuning can reach an edge before AppKit's pixel scroll.
            // Align only inside the extent; AppKit retains all elastic motion.
            if viewOffsetLines == scrollbackLines, origin > 0 {
                clip.scroll(to: NSPoint(x: 0, y: 0))
                scrollView.reflectScrolledClipView(clip)
            } else if viewOffsetLines == 0, origin < maximum {
                clip.scroll(to: NSPoint(x: 0, y: maximum))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        applyKnobPosition()
        publishOverscroll()
    }
}
