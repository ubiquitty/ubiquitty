// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// LinkPreviewBubble.swift — the bottom-left plate that says what a click would
// actually open.
//
// A link's visible text and its target are two different strings, and an OSC 8
// link can make them say anything: the text can read `https://your-bank` while
// the target is somewhere else entirely. So a reader is shown the TARGET
// before they commit, and shown it in the window's own chrome — the system
// small font, the system window and separator colours — because a plate drawn
// in terminal ink is one a program can draw a convincing copy of a row above.
//
// Transparent to hit-testing, itself and every descendant: it sits over the
// cells at the bottom-left of a window a reader is working in, and a plate that
// swallowed a click there would cost them a selection to say something they
// were only glancing at.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// A hit-transparent plate showing a hovered link's resolved target.
@objc(UBLinkPreviewBubble)
public final class LinkPreviewBubble: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 4
        static let borderWidth: CGFloat = 1
        static let paddingBesideText: CGFloat = 5
        static let paddingAboveText: CGFloat = 3
        /// The gap from the window's bottom-left corner.
        static let inset: CGFloat = 8
        /// The share of the window's width a very long target may take before
        /// it is truncated in the middle — enough to read the scheme and the
        /// tail, which is where a spoof shows.
        static let widthShare: CGFloat = 0.75
    }

    private let label = NSTextField(labelWithString: "")

    /// What the plate is saying, so a pointer move over the same link costs a
    /// string comparison rather than a layout.
    private var shownTarget: String?

    /// The link target the plate is about, so a line that arrives after the
    /// pointer has moved on is not shown.
    private var subject: String?

    private struct ResolutionRequest: Equatable, Sendable {
        let path: String
        let target: String
    }

    /// At most one request is admitted to the worker and one newest request
    /// waits here. Pointer movement replaces pending work, not queued blocks.
    private var activeResolution: ResolutionRequest?
    private var pendingResolution: ResolutionRequest?

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = Metrics.borderWidth
        // Pinned near the bottom-left corner as the window resizes.
        autoresizingMask = [.maxXMargin, .maxYMargin]
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .labelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LinkPreviewBubble is built in code")
    }

    /// Refuses every click, for itself and everything under it.
    ///
    /// - Parameter point: Ignored.
    /// - Returns: Nil, always, so the cells beneath take the click.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Shows one target in a window, or takes the plate away.
    ///
    /// Both shells call this; neither holds the view, because the content view
    /// already does and a second reference is a second answer to whether the
    /// window has one.
    ///
    /// - Parameters:
    ///   - target: What a click would open, or nil to withdraw the plate.
    ///   - window: The window to show it in.
    @objc(showTarget:inWindow:)
    public static func show(_ target: String?, in window: NSWindow?) {
        guard let window, let content = window.contentView else { return }
        let placed = content.subviews.compactMap { $0 as? LinkPreviewBubble }.first
        placed?.subject = nil
        placed?.pendingResolution = nil
        guard let target else {
            placed?.isHidden = true
            placed?.shownTarget = nil
            return
        }
        let bubble = placed ?? LinkPreviewBubble(frame: .zero)
        if bubble.superview !== content {
            content.addSubview(bubble, positioned: .above, relativeTo: nil)
        }
        guard bubble.shownTarget != target || bubble.isHidden else { return }
        bubble.shownTarget = target
        bubble.apply(target, over: content, appearance: window.effectiveAppearance)
    }

    /// Shows a link's line in a window, remembering which link it is about.
    ///
    /// - Parameters:
    ///   - text: What a click would open, as the plate says it.
    ///   - target: The link target the line is about.
    ///   - window: The window to show it in.
    public static func show(_ text: String, about target: String, in window: NSWindow?) {
        show(text, in: window)
        plate(in: window)?.subject = target
    }

    /// Replaces the line while the plate is still about the same link.
    ///
    /// The line a slower reading produced arrives after the plate went up,
    /// and by then the pointer may be over another link or none.
    ///
    /// - Parameters:
    ///   - text: The line to show.
    ///   - target: The link target the line is about.
    ///   - window: The window it was asked for.
    public static func replace(_ text: String, about target: String, in window: NSWindow?) {
        guard let bubble = plate(in: window), !bubble.isHidden, bubble.subject == target else { return }
        show(text, about: target, in: window)
    }

    /// Resolves only the newest local target after the current lookup finishes.
    ///
    /// - Parameters:
    ///   - path: The local path to inspect off the main actor.
    ///   - target: The link this reading belongs to.
    ///   - window: The window whose plate owns admission state.
    static func resolve(path: String, about target: String, in window: NSWindow?) {
        guard let bubble = plate(in: window), !bubble.isHidden else { return }
        let request = ResolutionRequest(path: path, target: target)
        if bubble.activeResolution == request { return }
        bubble.pendingResolution = request
        bubble.startPendingResolution()
    }

    private func startPendingResolution() {
        guard activeResolution == nil, !isHidden, let request = pendingResolution else { return }
        pendingResolution = nil
        activeResolution = request
        // Weak captures keep AppKit destruction on the main actor. The
        // worker owns only the copied request, never the plate or window.
        LinkOpener.previewResolution.async { [weak self] in
            let resolved = LinkOpener.resolvedPreviewText(forPath: request.path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeResolution = nil
                if !self.isHidden, self.subject == request.target {
                    Self.replace(resolved, about: request.target, in: self.window)
                }
                self.startPendingResolution()
            }
        }
    }

    #if UBIQUITTY_UI_TESTS
    /// Work retained by this plate, including the one admitted to the worker.
    package var retainedResolutionCountForTesting: Int {
        (activeResolution == nil ? 0 : 1) + (pendingResolution == nil ? 0 : 1)
    }

    /// The latest request waiting behind an admitted lookup.
    package var pendingResolutionTargetForTesting: String? { pendingResolution?.target }
    #endif

    /// The plate a window holds, if one has been placed.
    ///
    /// - Parameter window: The window.
    /// - Returns: The plate, or nil.
    private static func plate(in window: NSWindow?) -> LinkPreviewBubble? {
        window?.contentView?.subviews.compactMap { $0 as? LinkPreviewBubble }.first
    }

    /// Lays the plate out for one target.
    ///
    /// - Parameters:
    ///   - target: What a click would open.
    ///   - content: The window's content view, which the width share is of.
    ///   - appearance: The window's appearance.
    private func apply(_ target: String, over content: NSView, appearance: NSAppearance) {
        let scale = ChromeTypography.scaled(1.0)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize * CGFloat(scale))
        label.stringValue = target
        label.sizeToFit()
        // A layer's colours are resolved `CGColor`s, so they do not follow the
        // appearance the way the label's `NSColor` does: they are re-resolved
        // under the window's own appearance on each show, or a plate made in
        // light mode keeps its light chrome in a dark window.
        appearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let textSize = label.frame.size
        let width = min(
            textSize.width + Metrics.paddingBesideText * 2,
            content.bounds.width * Metrics.widthShare
        )
        let height = textSize.height + Metrics.paddingAboveText * 2
        frame = NSRect(x: Metrics.inset, y: Metrics.inset, width: width, height: height)
        // The label keeps its natural height and is centred: an `NSTextField`
        // top-aligns inside an over-tall field, which reads as a plate whose
        // text has slipped upward.
        label.frame = NSRect(
            x: Metrics.paddingBesideText,
            y: (height - textSize.height) / 2,
            width: width - Metrics.paddingBesideText * 2,
            height: textSize.height
        )
        isHidden = false
    }
}
