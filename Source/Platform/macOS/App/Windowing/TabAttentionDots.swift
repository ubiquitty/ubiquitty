// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TabAttentionDots.swift — a small, vertically-centered round status dot shown
// in an inactive tab's accessory slot, tinted to the OSC 21337 indicator color
// (a program's own blue for waiting, orange for busy, green for idle). The owner fades it
// out (layer opacity) when the tab is selected.
//
// The dots are a template image tinted by an image view, as AppKit draws a
// tab's own controls, so a system label colour is composited with the strip's
// glass rather than painted flat; a program's colour stays that colour.
//

import AppKit

/// One status dot, or the three dots unread output reads as, in a tab's
/// accessory slot.
@objc(UBTabAttentionDots)
public final class TabAttentionDots: NSView {
    // The accessory sits at the tab's trailing edge, so this right pad sets the
    // dots' distance from that edge (smaller = further right).
    private static let rightPad: CGFloat = 4.0

    // One fat centered status dot, or several small bottom-aligned ones (a
    // circle "…", an activity indicator).
    private static func dotDiameter(_ n: Int) -> CGFloat { n <= 1 ? 6.0 : 2.5 }
    private static func dotGap(_ n: Int) -> CGFloat { n <= 1 ? 0.0 : 1.5 }

    /// The colour the dots are drawn in: a system label colour, composited
    /// vibrantly, or a program's or theme's colour, painted as it is.
    @objc
    public var tintColor: NSColor = NSColor(white: 1.0, alpha: 0.55) {
        didSet {
            dotsView.contentTintColor = tintColor
            dotsView.isVibrant = TabTitleStyling.isSystemColor(tintColor)
        }
    }

    /// 1 for a centered status dot; 3 for a bottom-aligned circle "…".
    @objc
    public var dotCount: Int = 1 {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// An image view that composites the dots vibrantly while they wear a
    /// system label colour.
    private final class DotsView: NSImageView {
        var isVibrant = false

        override var allowsVibrancy: Bool { isVibrant }
    }

    private let dotsView = DotsView()

    /// The size and count the current image was drawn for.
    private var drawnFor: (size: NSSize, count: Int)?

    /// The view the dots are drawn in, for a scenario to read.
    package var imageViewForTesting: NSImageView { dotsView }

    public override var allowsVibrancy: Bool { dotsView.isVibrant }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dotsView.imageScaling = .scaleNone
        dotsView.imageAlignment = .alignBottomLeft
        dotsView.contentTintColor = tintColor
        addSubview(dotsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var intrinsicContentSize: NSSize {
        let n = max(1, dotCount)
        let dot = Self.dotDiameter(n)
        let gap = Self.dotGap(n)
        return NSSize(
            width: CGFloat(n) * dot + CGFloat(n - 1) * gap + Self.rightPad,
            height: 13.0
        )
    }

    public override func layout() {
        super.layout()
        dotsView.frame = bounds
        let n = max(1, dotCount)
        if let drawnFor, drawnFor.size == bounds.size, drawnFor.count == n { return }
        drawnFor = (bounds.size, n)
        dotsView.image = Self.dots(count: n, in: bounds.size)
    }

    /// The dots as a template image the size of the view, drawn on demand at
    /// whatever scale the screen asks for.
    ///
    /// - Parameters:
    ///   - n: How many dots.
    ///   - size: The view's size.
    /// - Returns: The image.
    private static func dots(count n: Int, in size: NSSize) -> NSImage {
        let dot = dotDiameter(n)
        let gap = dotGap(n)
        let image = NSImage(size: size, flipped: false) { rect in
            // Single dot: vertically centered. Ellipsis: small dots sat on the tab
            // title's baseline (a touch up from the very bottom) so they read "…".
            let y = (n == 1) ? (rect.height - dot) / 2.0 : 2.0
            var x: CGFloat = 0.0
            NSColor.black.setFill()
            for _ in 0..<n {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
                x += dot + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
