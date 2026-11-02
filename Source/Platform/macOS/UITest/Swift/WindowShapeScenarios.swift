// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// WindowShapeScenarios.swift — a Swift-shell window has the house shape:
// continuous top corners, square bottom ones.
//
// The shape rides a private AppKit hook, so what a test can hold is the mask
// the window answers with. The mask itself is read as pixels: a square bottom
// corner is opaque where a rounded one is clear, and that difference is the
// whole feature.

/// Registers the window-shape scenarios with the UI-test runner.
enum WindowShapeScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // Chromeless is a composite, and every piece of it is something a
        // reader can see: the traffic lights, the hairline that would
        // otherwise rule a line across the grid, the accessories that would
        // draw over the first rows, and the top inset — which is the bottom
        // padding, not the zero a title row made unnecessary. Each is asked
        // separately, because "hide the title bar" passing with three of the
        // five pieces done is how a half-applied setting ships.
        UBUITestRegister("swift_shell_chromeless_clears_the_whole_title_row") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let window = shell.window, let surface = firstTerminalSurface(under: window) else {
                    t.expect(false, desc: "the window has a pane to measure")
                    return
                }
                // A number nothing else in the fold carries, so an inset read
                // back as this one names this key rather than agreeing with
                // padding_top by coincidence.
                let saved = t.configureAppending("[appearance]\ntitleless_padding_top = 17.0\n")
                defer { t.restoreConfiguration(saved) }

                t.expect(
                    !(window.standardWindowButton(.closeButton)?.isHidden ?? true),
                    desc: "a titled window shows its traffic lights"
                )
                let titledInset = surface.contentTopInsetInPoints
                t.expect(titledInset != 17, desc: "and does not take the titleless inset")

                shell.toggleHideTitleBar(nil)
                t.pump(0.4)
                for (button, name) in [
                    (NSWindow.ButtonType.closeButton, "close"),
                    (.miniaturizeButton, "miniaturize"),
                    (.zoomButton, "zoom"),
                ] {
                    t.expect(
                        window.standardWindowButton(button)?.isHidden ?? false,
                        desc: "chromeless hides the " + name + " button"
                    )
                }
                t.expect(window.titleVisibility == .hidden, desc: "and the title text")
                t.expect(
                    window.titlebarSeparatorStyle == .none,
                    desc: "and the hairline that would rule across the grid"
                )
                t.expect(
                    window.titlebarAccessoryViewControllers.allSatisfy { $0.isHidden && $0.view.isHidden },
                    desc: "and every accessory, view and controller both"
                )
                t.expect(surface.contentTopInsetInPoints == 17, desc: "and the grid takes the titleless inset")

                // Reversible, which is the half a one-way apply loses: a
                // window that went chromeless once would stay so for good.
                shell.toggleHideTitleBar(nil)
                t.pump(0.4)
                t.expect(
                    !(window.standardWindowButton(.closeButton)?.isHidden ?? true),
                    desc: "and the lights come back"
                )
                t.expect(window.titlebarSeparatorStyle == .automatic, desc: "and the hairline")
                t.expect(
                    window.titlebarAccessoryViewControllers.allSatisfy { !$0.isHidden && !$0.view.isHidden },
                    desc: "and the accessories"
                )
                t.expect(surface.contentTopInsetInPoints == titledInset, desc: "and the titled inset")
            }
        }

        // The same window-level composite against an Objective-C-controller window,
        // which applies it through the same component. The inset is not asked
        // here; what this twin catches is a piece of the title row that one
        // window kind clears and the other leaves standing.

        UBUITestRegister("swift_shell_window_squares_its_bottom_corners") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.2)

                guard let shaped = window as? SquareBottomWindow else {
                    t.expect(false, desc: "the window is the shaped kind, not a plain NSWindow")
                    return
                }
                // Reached by SELECTOR, which is how the window server reaches
                // it: the override is registered under a name no Swift
                // superclass declares, so calling the Swift method would prove
                // the method exists and not that it is the one AppKit lands
                // on.
                guard let mask = shaped.perform(NSSelectorFromString("_cornerMask"))?.takeUnretainedValue() as? NSImage
                else {
                    t.expect(false, desc: "the private frame hook answers a mask on this window")
                    return
                }

                // The mask is a 9-slice: the caps carry the corners and the
                // middle row and column stretch. Read the two bottom corners
                // and the two top ones out of the cap squares.
                guard let bitmap = bitmap(of: mask) else {
                    t.expect(false, desc: "the mask rasterises")
                    return
                }
                // Unflipped, so y grows up: the bottom corners are at y = 0.
                t.expect(
                    isOpaque(bitmap, atX: 0, y: bitmap.pixelsHigh - 1),
                    desc: "the bottom-left corner pixel is inside the mask, so that corner is square"
                )
                t.expect(
                    isOpaque(bitmap, atX: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1),
                    desc: "and so is the bottom-right"
                )
                t.expect(
                    !isOpaque(bitmap, atX: 0, y: 0),
                    desc: "the top-left corner pixel is outside it, so that corner is rounded"
                )
                t.expect(
                    !isOpaque(bitmap, atX: bitmap.pixelsWide - 1, y: 0),
                    desc: "and so is the top-right"
                )

                // Fullscreen fills the display edge to edge, where a rounded
                // top would clip the content against the screen. The shape
                // stands aside there rather than being carried in.
                t.expect(
                    shaped.styleMask.contains(.fullScreen) == false,
                    desc: "the window under test is not fullscreen, so the mask above is the windowed one"
                )
            }
        }
    }
}

/// Rasterises a mask image.
///
/// - Parameter image: The mask.
/// - Returns: Its bitmap, or nil when the image carries no raster.
@MainActor
private func bitmap(of image: NSImage) -> NSBitmapImageRep? {
    guard let data = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: data)
}

/// Whether a mask pixel is inside the shape.
///
/// - Parameters:
///   - bitmap: The rasterised mask.
///   - x: The column, from the left.
///   - y: The row, in the bitmap's own top-down order.
/// - Returns: Whether the pixel is opaque, which is what the clip keeps.
@MainActor
private func isOpaque(_ bitmap: NSBitmapImageRep, atX x: Int, y: Int) -> Bool {
    guard let color = bitmap.colorAt(x: x, y: y) else { return false }
    return color.alphaComponent > 0.5
}

/// The first terminal pane under a window, walked off the view tree.
///
/// - Parameter window: The window to look in.
/// - Returns: The pane, or nil in a window that has none yet.
@MainActor
private func firstTerminalSurface(under window: NSWindow) -> TerminalSurface? {
    func walk(_ view: NSView) -> TerminalSurface? {
        if let surface = view as? TerminalSurface {
            return surface
        }
        for subview in view.subviews {
            if let found = walk(subview) {
                return found
            }
        }
        return nil
    }
    guard let content = window.contentView else { return nil }
    return walk(content)
}
