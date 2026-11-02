// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ObjectiveC.runtime

/// Contains every ordered test window, including panels, outside the desktop.
///
/// Frames remain real AppKit frames. Only their horizontal placement changes;
/// size, vertical geometry, layout, and drawable acquisition remain observable.
@objc(UBUITestWindowContainment)
@MainActor
public final class WindowContainment: NSObject {
    private static var replacements: [(Method, Method)] = []

    /// Indicates whether the harness prevents windows from becoming visible and active.
    @objc
    public static var isOffscreen: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-test") && !arguments.contains("--ui-test-visible")
    }

    /// Installs process-local containment before the harness creates a window.
    @objc
    public static func install() {
        guard isOffscreen, replacements.isEmpty else { return }
        let selectors: [(AnyClass, Selector, Selector)] = [
            (NSWindow.self, #selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.uiTestSetFrame(_:display:))),
            (NSWindow.self, #selector(NSWindow.setFrame(_:display:animate:)), #selector(NSWindow.uiTestSetFrame(_:display:animate:))),
            (NSWindow.self, #selector(NSWindow.setFrameOrigin(_:)), #selector(NSWindow.uiTestSetFrameOrigin(_:))),
            (NSWindow.self, #selector(NSWindow.setFrameTopLeftPoint(_:)), #selector(NSWindow.uiTestSetFrameTopLeftPoint(_:))),
            (NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)), #selector(NSWindow.uiTestConstrainFrameRect(_:to:))),
            (NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.uiTestOrder(_:relativeTo:))),
            (NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.uiTestOrderFrontRegardless)),
            (
                NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)),
                #selector(NSApplication.uiTestActivate(ignoringOtherApps:))
            ),
        ]
        for entry in selectors {
            let (type, originalSelector, replacementSelector): (AnyClass, Selector, Selector) = entry
            guard let original = class_getInstanceMethod(type, originalSelector),
                let replacement = class_getInstanceMethod(type, replacementSelector)
            else {
                preconditionFailure("The UI-test window containment method is unavailable")
            }
            replacements.append((original, replacement))
            method_exchangeImplementations(original, replacement)
        }
    }

    /// Restores the AppKit implementations owned by this test process.
    ///
    /// The harness tears down on the main thread. A process-wide exit handler
    /// cannot own this operation because another thread can call `exit`.
    @objc
    public static func restore() {
        for (original, replacement) in replacements.reversed() {
            method_exchangeImplementations(original, replacement)
        }
        replacements.removeAll()
    }

    /// Translates an unparked frame without changing its drawable dimensions.
    ///
    /// Ordinary display coordinates share a fixed translation, preserving
    /// distinct requested positions. Oversized frames receive enough additional
    /// distance to keep their right edge outside every display. Already parked
    /// frames pass through, including resize and restore requests.
    static func parkedFrame(_ frame: NSRect, displays: [NSRect]) -> NSRect {
        let leftmostDisplay = displays.map(\.minX).min() ?? 0
        let safeRightEdge = leftmostDisplay - 1
        guard frame.maxX > safeRightEdge else { return frame }
        let translation = max(65_536, 2 * (frame.maxX - safeRightEdge))
        return frame.offsetBy(dx: -translation, dy: 0)
    }

    static func parkedFrame(_ frame: NSRect) -> NSRect {
        isOffscreen ? parkedFrame(frame, displays: NSScreen.screens.map(\.frame)) : frame
    }

    static func park(_ window: NSWindow) {
        let parked = parkedFrame(window.frame)
        if parked != window.frame {
            window.setFrame(parked, display: false)
        }
    }
}

@MainActor
extension NSApplication {
    @objc
    dynamic fileprivate func uiTestActivate(ignoringOtherApps shouldIgnoreOtherApps: Bool) {
        // Activation is a desktop capability, not simulated test state. The
        // application stays inactive and its real key-window state is retained.
    }
}

@MainActor
extension NSWindow {
    // The replacement selectors hold AppKit's implementations after exchange.
    // Objective-C dispatch reaches those implementations; static Swift calls
    // would recurse into these wrappers.
    @objc
    dynamic fileprivate func uiTestSetFrame(_ frame: NSRect, display shouldDisplay: Bool) {
        uiTestSetFrame(WindowContainment.parkedFrame(frame), display: shouldDisplay)
    }

    @objc
    dynamic fileprivate func uiTestSetFrame(_ frame: NSRect, display shouldDisplay: Bool, animate shouldAnimate: Bool) {
        // An animation interpolates physical frames only; an on-screen endpoint
        // must not be handed to AppKit even while the window starts offscreen.
        uiTestSetFrame(WindowContainment.parkedFrame(frame), display: shouldDisplay, animate: shouldAnimate)
    }

    @objc
    dynamic fileprivate func uiTestSetFrameOrigin(_ point: NSPoint) {
        uiTestSetFrameOrigin(WindowContainment.parkedFrame(NSRect(origin: point, size: frame.size)).origin)
    }

    @objc
    dynamic fileprivate func uiTestSetFrameTopLeftPoint(_ point: NSPoint) {
        let requested = NSRect(x: point.x, y: point.y - frame.height, width: frame.width, height: frame.height)
        let parked = WindowContainment.parkedFrame(requested)
        uiTestSetFrameTopLeftPoint(NSPoint(x: parked.minX, y: parked.maxY))
    }

    @objc
    dynamic fileprivate func uiTestConstrainFrameRect(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        WindowContainment.parkedFrame(frame)
    }

    @objc
    dynamic fileprivate func uiTestOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
        if place != .out {
            WindowContainment.park(self)
        }
        uiTestOrder(place, relativeTo: otherWindowNumber)
    }

    @objc
    dynamic fileprivate func uiTestOrderFrontRegardless() {
        WindowContainment.park(self)
        uiTestOrderFrontRegardless()
    }
}
