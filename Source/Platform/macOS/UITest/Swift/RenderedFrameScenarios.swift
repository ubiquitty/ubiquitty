// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// RenderedFrameScenarios.swift — a real window's pane, drawn through its own
// renderer into an offscreen target and read back, so the glyph sheets, the
// theme and the shaders are exercised together rather than the model alone.
//
// The questions are coarse on purpose. A frame of text has more than one
// colour in it, and a screenful of glyphs covers more of it than a prompt
// does: a renderer that drew the ground and no glyph, or the same backdrop
// whatever the grid held, fails both, and neither depends on the font, the
// theme or the display the run landed on.

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

/// How a frame's pixels spread over colours.
private struct FrameColourCensus {
    /// How many distinct BGRA values the frame holds.
    var distinctColourCount: Int
    /// The share of the frame's pixels taken by its commonest colour, which
    /// on a terminal is the ground.
    var dominantShare: Double
}

/// Counts a frame's pixels by colour.
///
/// - Parameter pixels: Tightly packed BGRA pixels.
/// - Returns: The census, or nil for a frame with no pixels.
private func colourCensus(of pixels: Data) -> FrameColourCensus? {
    let pixelCount = pixels.count / 4
    guard pixelCount > 0 else { return nil }
    var histogram: [UInt32: Int] = [:]
    histogram.reserveCapacity(1024)
    pixels.withUnsafeBytes { raw in
        for index in 0..<pixelCount {
            histogram[raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self), default: 0] += 1
        }
    }
    let commonest = histogram.values.max() ?? 0
    return FrameColourCensus(
        distinctColourCount: histogram.count,
        dominantShare: Double(commonest) / Double(pixelCount)
    )
}

/// The census of what the surface draws now, recorded as a failure when no
/// frame can be read back.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The surface to draw.
///   - moment: What the frame shows, for the failure.
/// - Returns: The census, or nil when no frame was read.
@MainActor
private func census(_ t: UBUITestContext, of surface: TerminalSurface, at moment: String) -> FrameColourCensus? {
    guard let frame = surface.renderedFrameForTesting(), let counted = colourCensus(of: frame.pixels) else {
        t.expect(false, desc: "the surface draws a frame that reads back (\(moment))")
        return nil
    }
    return counted
}

/// Pumps until the grid's text contains `needle`, or a few seconds pass.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The surface whose grid is read.
///   - needle: The text to wait for.
/// - Returns: Whether the grid came to contain it.
@MainActor
private func waitForGridText(_ t: UBUITestContext, _ surface: TerminalSurface, _ needle: String) -> Bool {
    t.wait(until: { surface.gridTextForTesting().contains(needle) }, timeout: 8.0)
}

/// Registers the rendered-frame scenarios with the UI-test runner.
enum RenderedFrameScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_rendered_text_paints_foreground") { context in
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
                t.pump(0.3)
                // The marker is assembled from a variable, so it is on the grid
                // only once the output is, not as soon as the command echoes.
                surface.send("k=CHECK; printf \"RENDER${k}################\\n\"\n")
                t.expect(waitForGridText(t, surface, "RENDERCHECK"), desc: "the text reached the grid")
                t.pump(0.2)

                guard let frame = census(t, of: surface, at: "text on the grid") else { return }
                t.expect(
                    frame.distinctColourCount >= 2,
                    desc: "the frame holds the ground and glyph coverage (\(frame.distinctColourCount) colours)"
                )
                t.expect(frame.dominantShare < 1.0, desc: "the frame is not one uniform colour (\(frame.dominantShare))")
            }
        }

        UBUITestRegister("swift_shell_rendered_text_lowers_the_ground_share") { context in
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
                t.pump(0.4)
                guard let sparse = census(t, of: surface, at: "a near-empty screen") else { return }

                // The loop's own run of X is in the command line the shell
                // echoes, so waiting for it would be answered before a single
                // row is drawn. The marker after the loop is assembled from a
                // variable, so it appears only as output, and it says the fill
                // finished rather than that one line of it arrived.
                surface.send(
                    "i=0; while [ $i -lt 30 ]; do echo XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX; i=$((i+1)); done; k=ILLED; echo \"F${k}\"\n"
                )
                t.expect(waitForGridText(t, surface, "FILLED"), desc: "the fill loop ran to completion")
                t.pump(0.2)
                guard let dense = census(t, of: surface, at: "a screenful of text") else { return }

                // Repeated X rows scroll the prompt away. Their glyph pixels
                // lower the ground share, but their exact BGRA shade count need
                // not exceed the prompt's varied antialiasing and colours.
                t.expect(
                    dense.dominantShare < sparse.dominantShare,
                    desc: "a screenful of text lowers the ground's share (\(dense.dominantShare) against \(sparse.dominantShare))"
                )
            }
        }
    }
}
