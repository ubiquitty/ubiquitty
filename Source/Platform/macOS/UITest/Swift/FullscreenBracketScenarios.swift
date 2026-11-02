// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// FullscreenBracketScenarios.swift — a native full-screen transition on the
// Swift shell, bracketed by the delegate's will/did hooks.
//
// AppKit animates the transition: the window passes through frames that are
// nobody's, and the layer can pass through a scale that is not the display's.
// The shell brackets the animation with the delegate's will/did hooks: a
// program's geometry request arriving inside it waits for the settle, and
// once settled the chrome is painted again and every surface republishes its
// geometry off the scale the window ended on, with a frame forced so the
// renderer re-bakes what it drew against the animation's drawable.
//
// Driven through the hooks rather than through the system: the UI-test app
// runs as an accessory with parked windows, and a real toggle would take a
// Space on the machine running the suite. What the hooks do is the port; what
// AppKit does around them is AppKit's.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let found = view as? TerminalSurface {
        return found
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Registers the full-screen bracket scenarios with the UI-test runner.
enum FullscreenBracketScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_fullscreen_transition_defers_a_programs_resize_and_settles_the_scale") { context in
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
                t.pump(0.6)
                guard let renderer = surface.renderer else {
                    t.expect(false, desc: "the surface has a renderer")
                    return
                }
                let cell = renderer.cellSize(for: surface)
                let displayScale = window.backingScaleFactor
                // A scale the display does not have, standing in for the one
                // the animation's re-host can leave on the layer.
                let transitionalScale: CGFloat = displayScale == 1 ? 2 : 1
                // The whole run is scaled and rounded once, not the cell: what
                // the surface publishes is the drawn text area, and a cell of
                // 7.2 points over 40 columns draws 288 device pixels, not the
                // 280 that rounding each cell down to 7 would claim. Rounding
                // per cell understates the area by the fraction times the
                // column count, which is the disagreement between the report
                // and the drawn extent that the pixel basis exists to close.
                @MainActor
                func textAreaWidth(at scale: CGFloat) -> Int {
                    Int((cell.width * scale * CGFloat(surface.publishedGrid.columns)).rounded())
                }

                // Entry. A program's resize inside the bracket waits: performed
                // against the animation's frame it would size the window to
                // somewhere it no longer is.
                let frameBefore = window.frame
                shell.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
                t.expect(shell.isInFullScreenTransitionForTesting, desc: "the bracket opens on will-enter")
                surface.feed(Data("\u{1b}[8;10;40t".utf8))
                t.pump(0.35)
                t.expect(window.frame == frameBefore, desc: "a CSI 8 t inside the bracket moves nothing yet (\(window.frame.size))")
                shell.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
                t.pump(0.35)
                t.expect(!shell.isInFullScreenTransitionForTesting, desc: "and closes on did-enter")
                t.expect(
                    surface.publishedGrid.rows == 10 && surface.publishedGrid.columns == 40,
                    desc: "the deferred request ran against the settled frame (\(surface.publishedGrid))"
                )
                t.expect(
                    shell.chromeSettlesAfterFullScreenForTesting == 1,
                    desc:
                        "the chrome was painted again once AppKit had wired the titlebar (\(shell.chromeSettlesAfterFullScreenForTesting))"
                )

                // Exit. A resize inside the bracket publishes the pixel grid
                // at whatever scale the layer carries, and the animation can
                // leave it at one the display does not have. The settle reads
                // the window's scale again and republishes off it, with a
                // frame for the drawable that scale sizes.
                shell.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
                surface.metalLayer.contentsScale = transitionalScale
                var taller = window.frame
                taller.size.height += cell.height * 2
                window.setFrame(taller, display: true)
                t.pump(0.3)
                let published = surface.reportedTextAreaPixelsForTesting?.width
                t.expect(
                    published == textAreaWidth(at: transitionalScale),
                    desc:
                        "inside the bracket the pixel grid was published at the animation's scale (\(String(describing: published)) for \(textAreaWidth(at: transitionalScale)))"
                )
                // Quiet first, so a frame counted after the settle is the settle's.
                t.pump(0.4)
                let quiet = surface.framesEncodedForTesting
                t.pump(0.4)
                t.expect(
                    surface.framesEncodedForTesting == quiet,
                    desc: "an idle surface encodes no frame (\(quiet) then \(surface.framesEncodedForTesting))"
                )
                shell.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
                t.expect(shell.chromeSettlesAfterFullScreenForTesting == 2, desc: "the chrome is painted again on exit, at once")
                t.pump(0.4)
                t.expect(
                    surface.metalLayer.contentsScale == displayScale,
                    desc: "the settle read the display's scale off the window again (\(surface.metalLayer.contentsScale))"
                )
                let settled = surface.reportedTextAreaPixelsForTesting?.width
                t.expect(
                    settled == textAreaWidth(at: displayScale),
                    desc: "and republished the pixel grid off it (\(String(describing: settled)) for \(textAreaWidth(at: displayScale)))"
                )
                let settledDrawable = CGSize(
                    width: (surface.bounds.width * displayScale).rounded(),
                    height: (surface.bounds.height * displayScale).rounded()
                )
                t.expect(
                    surface.metalLayer.drawableSize == settledDrawable,
                    desc: "the drawable is sized for the settled scale (\(surface.metalLayer.drawableSize) for \(settledDrawable))"
                )
                // A frame follows either way: the chrome repaint asks for one
                // too. What only the settle gives it is the drawable above and
                // the dropped baseline, so every row is read again into it.
                t.expect(
                    surface.framesEncodedForTesting > quiet,
                    desc: "and a frame was encoded after the settle (\(quiet) to \(surface.framesEncodedForTesting))"
                )
            }
        }
    }
}
