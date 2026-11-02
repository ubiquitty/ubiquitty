// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// SurfaceDrawableScenarios.swift — the Swift shell's Metal layer holds the
// grid at its own pitch, whatever the view's size and the display's scale are
// doing.
//
// Core Animation's default gravity STRETCHES a layer's contents across its
// bounds, so a drawable that is not exactly `bounds x contentsScale` draws the
// glyphs at the wrong pitch rather than leaving an edge for the next frame.
// Two things keep the two equal — a rounded drawable, and one scale source
// for the drawable and for the encode — and one thing makes a mismatch
// survivable rather than visible, which is the top-left anchor. All three are
// asserted here against a real window, because none of them is visible to a
// renderer-side check: the renderer is handed the drawable it is handed.

/// A half-point view size. AppKit aligns a layer-backed view's frame to the
/// backing grid, so at a retina scale this is the finest a resize can land on
/// — and its product with a scale of three is a half pixel, which is the case
/// the drawable's rounding exists for.
private let halfPointWidth = 700.5
private let halfPointHeight = 500.5

/// A scale the window's backing will not be, so a drawable derived from the
/// view's own conversion and one derived from the layer's are told apart. It
/// stands for the middle of a drag between displays of different scale, where
/// the layer's scale has moved and the view's frame has not.
private let divergentScale = 3.0

/// Registers the surface drawable-geometry scenarios with the UI-test runner.
enum SurfaceDrawableScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_ui_test_parking_preserves_geometry") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let displays = [
                    NSRect(x: -5120, y: -700, width: 2560, height: 1440),
                    NSRect(x: -2560, y: 0, width: 2560, height: 1440),
                    NSRect(x: 0, y: 0, width: 2560, height: 1440),
                ]
                let requests = [
                    NSRect(x: 140, y: 90, width: 700, height: 420),
                    NSRect(x: 204, y: 90, width: 700, height: 420),
                    NSRect(x: -5000, y: -400, width: 700, height: 420),
                    NSRect(x: 0, y: 0, width: 120000, height: 420),
                ]
                for requested in requests {
                    let parked = WindowContainment.parkedFrame(requested, displays: displays)
                    t.expect(
                        !displays.contains(where: { $0.intersects(parked) }),
                        desc: "parking clears every display, including negative origins"
                    )
                    t.expect(
                        parked.size == requested.size && parked.origin.y == requested.origin.y,
                        desc: "parking preserves size and vertical geometry"
                    )
                    t.expect(WindowContainment.parkedFrame(parked, displays: displays) == parked, desc: "parking is idempotent")
                }
                let first = WindowContainment.parkedFrame(requests[0], displays: displays)
                let second = WindowContainment.parkedFrame(requests[1], displays: displays)
                t.expect(second.minX - first.minX == 64, desc: "distinct requested horizontal positions remain distinct")
            }
        }

        UBUITestRegister("swift_shell_ui_test_contains_plain_windows_and_panels") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard WindowContainment.isOffscreen else {
                    t.expect(false, desc: "this containment scenario requires offscreen UI-test mode")
                    return
                }
                let initial = NSRect(x: 140, y: 190, width: 320, height: 200)
                let windows: [NSWindow] = [
                    NSWindow(contentRect: initial, styleMask: [.titled, .resizable], backing: .buffered, defer: false),
                    NSPanel(contentRect: initial, styleMask: [.titled, .resizable], backing: .buffered, defer: false),
                ]
                for window in windows {
                    window.isReleasedWhenClosed = false
                }
                defer { windows.forEach { $0.close() } }
                for window in windows {
                    window.setFrame(initial, display: false)
                    t.expect(
                        window.frame == WindowContainment.parkedFrame(initial),
                        desc: "the shared frame setter contains an ordinary window or panel"
                    )
                    guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
                        t.expect(false, desc: "containment failed before ordering; the unsafe window remains hidden")
                        return
                    }
                    window.orderFrontRegardless()
                    t.pump(0.05)
                    t.expect(window.isVisible, desc: "the contained window remains ordered")
                    t.expect(
                        !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
                        desc: "ordering does not rehome the window onto the desktop"
                    )

                    window.setFrameOrigin(NSPoint(x: 204, y: 210))
                    let moved = NSRect(x: 204, y: 210, width: initial.width, height: initial.height)
                    t.expect(
                        window.frame == WindowContainment.parkedFrame(moved),
                        desc: "origin moves keep distinct horizontal positions offscreen"
                    )

                    window.setFrameTopLeftPoint(NSPoint(x: 268, y: 700))
                    let topLeft = NSRect(x: 268, y: 700 - initial.height, width: initial.width, height: initial.height)
                    t.expect(window.frame == WindowContainment.parkedFrame(topLeft), desc: "top-left moves preserve their vertical anchor")

                    let resized = NSRect(x: 332, y: 250, width: 420, height: 260)
                    window.setFrame(resized, display: true, animate: false)
                    t.expect(
                        window.frame == WindowContainment.parkedFrame(resized),
                        desc: "the animated frame entry preserves dimensions and containment"
                    )
                    window.setFrame(initial, display: true, animate: true)
                    t.pump(0.4)
                    t.expect(
                        window.frame == WindowContainment.parkedFrame(initial),
                        desc: "animated placement finishes at the contained requested frame"
                    )
                    t.expect(
                        window.constrainFrameRect(initial, to: NSScreen.main) == WindowContainment.parkedFrame(initial),
                        desc: "screen constraints cannot pull the parked frame onto a display"
                    )
                    window.orderOut(nil)
                    window.order(.above, relativeTo: 0)
                    t.expect(
                        !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
                        desc: "reordering preserves containment"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_ui_test_windows_park_offscreen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.2)

                t.expect(window.isVisible, desc: "the parked window remains ordered in")
                t.expect(
                    !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
                    desc: "the Swift UI-test window is fully outside every attached display (is \(window.frame))"
                )
                t.expect(
                    surface.bounds.width > 0 && surface.bounds.height > 0
                        && surface.metalLayer.drawableSize.width > 0 && surface.metalLayer.drawableSize.height > 0,
                    desc: "the parked window still lays out a drawable terminal surface"
                )
                surface.viewWillStartLiveResize()
                t.expect(
                    surface.isDrivingFramesForTesting,
                    desc: "offscreen containment still exercises foreground frame scheduling"
                )
                surface.viewDidEndLiveResize()
            }
        }

        UBUITestRegister("swift_shell_ui_test_does_not_activate_the_application") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard WindowContainment.isOffscreen else {
                    t.expect(false, desc: "this activation containment scenario requires offscreen UI-test mode")
                    return
                }
                let policy = NSApp.activationPolicy()
                NSApp.activate(ignoringOtherApps: true)
                t.pump(0.05)
                t.expect(!NSApp.isActive, desc: "a test-requested activation does not take the desktop focus")
                t.expect(NSApp.activationPolicy() == policy, desc: "activation containment does not change application policy")
            }
        }

        UBUITestRegister("swift_shell_layer_anchors_and_never_stretches") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)
                let layer = surface.metalLayer

                t.expect(
                    layer.contentsGravity == .topLeft,
                    desc: "the layer anchors its drawable top-left instead of stretching it (is \(layer.contentsGravity.rawValue))"
                )

                // The drawable a window opens with already has to satisfy the
                // invariant: an attach is where the scale becomes known, and
                // nothing else is owed before the first frame.
                expectDrawableMatchesBounds(t, surface, at: "the size the window opened at")

                // A resize, driven through the view's own hook, which is the
                // path every real one takes. Asserted without pumping the run
                // loop: a pane relayout would put the surface back on the
                // layout's rect, and the case would go untested rather than
                // failing.
                surface.setFrameSize(NSSize(width: halfPointWidth, height: halfPointHeight))
                expectDrawableMatchesBounds(t, surface, at: "a resize")

                // The drawable follows the LAYER's scale, which is the scale
                // the renderer lays the cell metrics out at. Sized from the
                // view's own point-to-pixel conversion instead it would follow
                // the WINDOW's backing scale, and the two disagree for as long
                // as a drag between displays of different scale takes to
                // settle — long enough to lay the grid into a drawable cut for
                // the other scale. It is also the case where the product is a
                // fraction of a pixel, since the frame stayed aligned to the
                // scale it was laid out at.
                let windowScale = shell.window?.backingScaleFactor ?? 1
                t.expect(
                    windowScale != divergentScale,
                    desc: "the two scales are distinguishable (the window's is \(windowScale))"
                )
                layer.contentsScale = divergentScale
                surface.syncDrawableSize()
                let unrounded = surface.bounds.width * divergentScale
                t.expect(
                    unrounded != unrounded.rounded(),
                    desc: "the bounds times the layer's scale is a fraction of a pixel (is \(unrounded))"
                )
                t.expect(
                    layer.drawableSize.width == layer.drawableSize.width.rounded()
                        && layer.drawableSize.height == layer.drawableSize.height.rounded(),
                    desc: "the drawable is still whole device pixels (is \(layer.drawableSize))"
                )
                t.expect(
                    layer.drawableSize
                        == CGSize(
                            width: unrounded.rounded(),
                            height: (surface.bounds.height * divergentScale).rounded()
                        ),
                    desc: "and it is the layer's scale that sized it, not the window's (is \(layer.drawableSize))"
                )
                layer.contentsScale = windowScale
                surface.syncDrawableSize()
                expectDrawableMatchesBounds(t, surface, at: "the scale restored")
            }
        }

        UBUITestRegister("swift_shell_chrome_labels_take_the_ui_font_scale") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyAppearanceToOpenWindows()
                }

                // The public fan-out a settings write and a config reload take,
                // rather than a private re-derivation: the claim is that the
                // scale reaches a live window, and a test that called past the
                // fan-out would hold whether it does.
                @MainActor
                func titleFontSize() -> CGFloat? {
                    TerminalWindowController.applyAppearanceToOpenWindows()
                    guard let baked = window.tab.attributedTitle, baked.length > 0,
                        let font = baked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    else {
                        return nil
                    }
                    return font.pointSize
                }

                t.configureAppending("[appearance]\nui_font_scale = 1.0\n")
                guard let plain = titleFontSize() else {
                    t.expect(false, desc: "the tab title carries a font to read")
                    return
                }
                // A scale the schema admits (0.5..2.0) and far enough from one
                // that a rounded point size cannot hide the difference.
                t.restoreConfiguration(saved)
                t.configureAppending("[appearance]\nui_font_scale = 1.75\n")
                guard let enlarged = titleFontSize() else {
                    t.expect(false, desc: "the tab title still carries a font at the larger scale")
                    return
                }
                // The reader who set the scale asked for every chrome label,
                // not the ones a frontend remembered to multiply: the sizes go
                // through `ChromeTypography.scaled`.
                t.expect(
                    abs(enlarged - plain * 1.75) < 0.01,
                    desc: "the tab title scales with ui_font_scale (\(plain) then \(enlarged))"
                )
            }
        }

        UBUITestRegister("swift_shell_one_quantiser_owns_the_window_size") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.2)

                // AppKit applies `contentResizeIncrements` first, before the
                // delegate is asked, so a window carrying both quantises twice, to two
                // different answers: increments step from whatever extent the
                // window has, while `windowWillResize(_:to:)` snaps the content
                // box to whole cells with the padding reserved. A drag under
                // both lands between them, on a content box that is not a whole
                // grid.
                //
                // Asserted on the window's configuration rather than on a drag:
                // `inLiveResize` is AppKit's to set, so the delegate's own
                // guard cannot be entered from a test, and a programmatic
                // `setFrame` was measured to pass under both settings — an
                // instrument that agrees with either answer says nothing about
                // which one is in force.
                t.expect(
                    window.contentResizeIncrements == NSSize(width: 1, height: 1),
                    desc: "the window declares no resize increments (is \(window.contentResizeIncrements))"
                )
                _ = surface
            }
        }

        UBUITestRegister("swift_shell_the_grid_fits_inside_its_padding") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the app delegate answers")
                    return
                }
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)
                guard let opening = surface.gridFitBoxForTesting else {
                    t.expect(false, desc: "the surface reports the box it fits a grid into")
                    return
                }
                // A padding this arm has to reserve. Restored to whatever the
                // run started with, read off the surface rather than guessed:
                // the effective value is the one the renderer insets by.
                let restoreBottom = Double(opening.insets.bottom)
                app.settingsSetWindowPaddingBottom(9.0)
                defer { app.settingsSetWindowPaddingBottom(restoreBottom) }
                t.pump(0.2)

                // A sweep one point at a time across a whole cell: the fit
                // only goes wrong where the height's remainder over the cell
                // is smaller than the padding, which is a band a single size
                // walks past. Every height in it must still hold its grid.
                var worst = ""
                var overflows = 0
                let base = surface.bounds.height.rounded()
                for step in 0..<24 {
                    surface.setFrameSize(NSSize(width: surface.bounds.width, height: base - Double(step)))
                    t.pump(0.05)
                    guard let box = surface.gridFitBoxForTesting else { continue }
                    let rows = Double(surface.drive.readSnapshot().rows)
                    let needed = Double(box.insets.top) + rows * box.cell.height + Double(box.insets.bottom)
                    if needed > box.bounds.height + 0.001 {
                        overflows += 1
                        if worst.isEmpty {
                            worst =
                                "\(rows) rows of \(box.cell.height) plus \(box.insets.top)+\(box.insets.bottom) padding need \(needed) in \(box.bounds.height)"
                        }
                    }
                }
                // The row a grid claims but its box cannot hold is drawn below
                // the bottom edge: the reader loses the line the shell is
                // printing on, and every geometry derived from the count — the
                // scroller's proportion, the retained frame's blit — is
                // computed for a screen taller than the one on display.
                t.expect(
                    overflows == 0,
                    desc:
                        "every height across a cell fits its grid inside the padding (\(overflows) of 24 overflowed; first: \(worst))"
                )
            }
        }

        UBUITestRegister("swift_shell_resize_reads_the_stationary_bottom_edge") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The fact the grid resize anchors the primary screen on: a
                // window whose bottom edge stands still while its size changes.
                let start = CGRect(x: 100, y: 100, width: 800, height: 600)
                t.expect(
                    TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: CGRect(x: 100, y: 100, width: 900, height: 600)),
                    desc: "a right-edge drag holds the bottom"
                )
                t.expect(
                    TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: CGRect(x: 100, y: 100, width: 800, height: 700)),
                    desc: "a top-edge drag holds the bottom"
                )
                t.expect(
                    TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: CGRect(x: 0, y: 100, width: 900, height: 600)),
                    desc: "a left-edge drag holds the bottom"
                )
                t.expect(
                    !TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: CGRect(x: 100, y: 0, width: 800, height: 700)),
                    desc: "a bottom-edge drag moves the bottom"
                )
                // A Fill zoom of a window flush with the screen's right side:
                // only the right edge stands still.
                t.expect(
                    !TerminalSurface.isBottomEdgeFixed(
                        resizingFrom: CGRect(x: 1336, y: 300, width: 1688, height: 500),
                        to: CGRect(x: 842, y: 120, width: 2182, height: 1700)
                    ),
                    desc: "a zoom with only the right edge still moves the bottom"
                )
                // A divider dragged between two panes leaves the window frame
                // alone. Read as a stationary bottom edge, it would anchor a
                // resizing pane off its own top-left origin.
                t.expect(
                    !TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: start),
                    desc: "an unchanged window frame holds no edge"
                )
            }
        }
    }
}

/// Asserts the drawable covers the bounds exactly, in whole device pixels.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The surface to read.
///   - at: What the surface was doing, for the failure text.
@MainActor
private func expectDrawableMatchesBounds(_ t: UBUITestContext, _ surface: TerminalSurface, at moment: String) {
    let layer = surface.metalLayer
    let expected = CGSize(
        width: (surface.bounds.width * layer.contentsScale).rounded(),
        height: (surface.bounds.height * layer.contentsScale).rounded()
    )
    t.expect(
        layer.drawableSize == expected,
        desc: "the drawable covers the bounds at \(moment) (is \(layer.drawableSize), bounds x scale is \(expected))"
    )
}

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}
