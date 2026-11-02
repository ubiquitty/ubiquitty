// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// The handful of view-layer types whose only difference between the two Apple
// shells is their name.
//
// The surface below is one implementation, hosted by an AppKit window on the
// desktop and a UIKit one on the phone. What actually differs is the superclass
// and a few value types — not the drawing, not the geometry, not the model. So
// they are named once here, and the surface names these.
//
// What is not aliased: events. A mouse with a scroll wheel and a
// trackpad with momentum are not a touch, and pretending one type covers both
// would put the difference inside the shared code instead of at its edge. Event
// handling belongs to each shell.

#if canImport(AppKit)
public typealias PlatformView = NSView
public typealias PlatformColor = NSColor
public typealias PlatformEdgeInsets = NSEdgeInsets
#else
public typealias PlatformView = UIView
public typealias PlatformColor = UIColor
public typealias PlatformEdgeInsets = UIEdgeInsets
#endif

#if !canImport(AppKit)

// AppKit's spellings for edges UIKit has under other names.
//
// The surface asks for a repaint, a relayout and a backing conversion in one
// vocabulary. Two vocabularies would mean two versions of every method that
// uses them, which is the duplication this layer exists to avoid — so the
// shell that lacks a spelling gains it, rather than the shared code growing
// a branch at each call.
//
// Each is the UIKit operation with the same meaning, not an approximation:
// needsDisplay marks the view dirty, needsLayout schedules a layout pass,
// and convertToBacking is the point-to-pixel scale UIKit exposes through the
// trait collection.
extension UIView {
    /// Marks the view as needing a frame. Reading it is not meaningful on
    /// UIKit, which keeps no such flag; the surface only ever sets it.
    var needsDisplay: Bool {
        get { false }
        set {
            if newValue {
                setNeedsDisplay()
            }
        }
    }

    /// Schedules a layout pass. Reading it is not meaningful, as above.
    var needsLayout: Bool {
        get { false }
        set {
            if newValue {
                setNeedsLayout()
            }
        }
    }

    /// Always true: a UIView is layer-backed, which is the state AppKit's
    /// wantsLayer asks for.
    var wantsLayer: Bool {
        get { true }
        set {}
    }

    /// Whether this view or an ancestor is hidden.
    var isHiddenOrHasHiddenAncestor: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden {
                return true
            }
            view = current.superview
        }
        return false
    }

    /// Points to pixels, at this view's own scale.
    func convertToBacking(_ rect: CGRect) -> CGRect {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Points to pixels, at this view's own scale.
    func convertToBacking(_ size: CGSize) -> CGSize {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

extension UIColor {
    /// AppKit's sRGB initialiser, under its own name.
    ///
    /// UIColor's `init(red:...)` is already sRGB, so this is the same colour
    /// by the same numbers — the surface resolves a terminal colour once and
    /// should not have to say it twice.
    convenience init(srgbRed: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: srgbRed, green: green, blue: blue, alpha: alpha)
    }
}

extension UIWindow {
    /// A phone window is never miniaturised; the state does not exist.
    var isMiniaturized: Bool { false }

    /// The window's backing scale, under AppKit's name for it.
    var backingScaleFactor: CGFloat { screen.scale }
}

#endif
