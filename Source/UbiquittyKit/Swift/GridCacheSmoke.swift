// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GridCacheSmoke.swift — the retained grid against a full rebuild, frame by
// frame, over the events a feed cannot reach.
//
// A frame that Loads the retained target repaints only its dirty rows, and the
// contract is that the result is the frame a full rebuild draws. The snapshot
// command's consecutive frames hold that for what bytes can do; a search step,
// a selection drag, a focus change, a scroll of the view, a resize and a
// window backdrop are view state no byte reaches. Each step here draws the
// retained frame, then lets the target go and draws the same state whole, and
// the two must agree byte for byte.
//
// The steps run under the configuration the app runs with, and then a scroll
// scenario runs again over a pinned translucent ground. A scrolled frame keeps
// the window padding its scroll left beside the rows it repainted, and whether
// that padding is the rebuild's byte depends on the ground's colour: on a
// ground whose premultiplied channels sit between two codes it is the clear's
// rounding that decides. The pinned scenario holds that whatever the reader's
// configuration names.

#if canImport(AppKit)
import AppKit
import Metal
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The smoke's entry, which the application's entry point dispatches.
public final class GridCacheSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether every retained frame matched its full rebuild.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            GridCacheSmoke.run()
        }
    }
}

/// The scenarios: one surface each, many steps, two frames a step.
@MainActor
enum GridCacheSmoke {
    private static let rows = 10
    private static let columns = 40

    /// The theme the pinned scenario draws in.
    private static let pinnedTheme = "Noir"

    /// The ground opacity the pinned scenario draws at.
    ///
    /// Noir's ground premultiplied by it is 10.55 and 11.56 of 255 in red and
    /// green: past the middle of a code, where the target's encode may store a
    /// colour handed to it unrounded as either neighbour. A ground whose
    /// premultiplied channels sit near whole codes — the constructed palette
    /// at this opacity or at the 0.7 the configured scenario's backdrop steps
    /// set, or Noir opaque — stores one byte on every path, and cannot tell a
    /// padding cleared one way from a padding cleared another.
    private static let pinnedGroundOpacity = 0.502613

    /// - Returns: Whether every step's retained frame matched its rebuild.
    static func run() -> Bool {
        guard
            let configured = SurfaceSnapshot(
                rows: rows,
                columns: columns,
                contentScale: 2,
                configuration: Ubiquitty.Preferences.values().pointee
            )
        else {
            return failed("could not construct the surface")
        }
        guard let configuredRun = compare(configured, steps: steps(configured), scenario: nil) else {
            return false
        }
        guard let pinned = pinnedTranslucentSurface() else {
            return failed("could not construct the translucent \(pinnedTheme) surface")
        }
        guard let pinnedRun = compare(pinned, steps: scrollSteps(pinned), scenario: "translucent \(pinnedTheme)") else {
            return false
        }
        let mismatches = configuredRun.mismatches + pinnedRun.mismatches
        guard mismatches.isEmpty else {
            return failed("retained frames differ from their full rebuild: " + mismatches.joined(separator: ", "))
        }
        let stepCount = configuredRun.stepCount + pinnedRun.stepCount
        print("grid-cache-smoke: PASS (\(stepCount) steps, each retained frame equal to its full rebuild)")
        return true
    }

    /// Draws each step retained, then whole, and names the steps whose two
    /// frames differ.
    ///
    /// - Parameters:
    ///   - capture: The surface the steps draw.
    ///   - steps: The steps, in order.
    ///   - scenario: The name a step is reported under, or nil to report it by
    ///     its own name.
    /// - Returns: The steps whose frames differ and the number taken, or nil
    ///   when a frame was not drawn, which is reported here.
    private static func compare(
        _ capture: SurfaceSnapshot,
        steps: [(String, () -> Void)],
        scenario: String?
    ) -> (mismatches: [String], stepCount: Int)? {
        capture.surface.setSurfaceFocused(true)
        var mismatches: [String] = []
        for (name, apply) in steps {
            let reported = scenario.map { "\($0): \(name)" } ?? name
            apply()
            // The step's own frame repaints whatever its plan owed. The
            // focused pill then bounces on the clock, in the overlay, from
            // that frame on; the compared pair is drawn once it has come to
            // rest, so it differs only by what the target kept: the frame
            // below Loads the target the step's frame left.
            guard capture.pixels() != nil else {
                _ = failed("the frame for \(reported) was not drawn")
                return nil
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            guard let retained = capture.pixels() else {
                _ = failed("the retained frame for \(reported) was not drawn")
                return nil
            }
            for renderer in capture.surface.frameRenderers.values {
                renderer.releaseRetainedGrid()
            }
            capture.surface.invalidateRetainedBaseline()
            guard let full = capture.pixels() else {
                _ = failed("the full frame for \(reported) was not drawn")
                return nil
            }
            if retained != full {
                let firstRow = firstDifferingRow(retained, full, width: capture.texture.width)
                mismatches.append("\(reported) (\(firstRow))")
            }
        }
        return (mismatches, steps.count)
    }

    /// Ten rows of text, colour and ligature candidates, each starting with
    /// `label` and its row number.
    private static func screen(_ label: String) -> String {
        (1...rows).map { "\u{1b}[\($0);1H\(label) \($0) \u{1b}[31mred\u{1b}[0m \u{1b}[44mblue\u{1b}[0m gjpqy -> != ===" }
            .joined()
    }

    /// The steps, in order: each changes one thing a frame draws.
    private static func steps(_ capture: SurfaceSnapshot) -> [(String, () -> Void)] {
        let surface = capture.surface
        func feed(_ text: String) {
            capture.feed(std.string(text))
        }
        func select(_ row0: Int32, _ column0: Int32, _ row1: Int32, _ column1: Int32) {
            guard let terminal = surface.drive.borrowTerminal() else { return }
            var bounds = Ubiquitty.SelectionBounds()
            bounds.row0 = row0
            bounds.column0 = column0
            bounds.row1 = row1
            bounds.column1 = column1
            surface.selectionModel.session.pointee.state = Ubiquitty.Selection.characterSelectionOverVisibleRows(terminal, bounds)
        }
        return [
            // The cursor blinks on the clock; hidden, it cannot differ
            // between the two frames of a step.
            ("first frame", { feed("\u{1b}[?25l" + screen("row")) }),
            ("settled", {}),
            ("an edited row", { feed("\u{1b}[3;5Hedited") }),
            ("a search opened", { _ = surface.searchScrollbackAndWait("blue", isRegex: false, isCaseSensitive: true) }),
            ("the next match", { _ = surface.findNextMatch() }),
            ("the match after", { _ = surface.findNextMatch() }),
            ("the previous match", { _ = surface.findPreviousMatch() }),
            ("the search closed", { surface.clearSearch() }),
            ("a selection colour named", { feed("\u{1b}]17;rgb:00/80/ff\u{07}") }),
            ("a selection drawn", { select(2, 3, 4, 12) }),
            ("the selection grown", { select(2, 3, 6, 20) }),
            ("the selection shrunk", { select(3, 1, 3, 9) }),
            ("the selection cleared", { surface.clearSelection() }),
            ("focus lost", { surface.setSurfaceFocused(false) }),
            ("focus regained", { surface.setSurfaceFocused(true) }),
            ("stacked marks above a row", { feed("\u{1b}[6;1H\u{1b}[2Ke\u{301}\u{302}\u{303}\u{304} a\u{30a}\u{30b}") }),
            ("the marks erased", { feed("\u{1b}[6;1H\u{1b}[2K") }),
            ("history written", { feed("\u{1b}[\(rows);1H\r\nmore\r\nlines\r\nfor\r\nhistory") }),
            ("the view scrolled back", { surface.viewOffset = 2 }),
            ("the view back at the tail", { surface.viewOffset = 0 }),
            ("a shorter grid", { surface.drive.resize(rows: rows - 2, columns: columns - 4) }),
            ("the grid restored", { surface.drive.resize(rows: rows, columns: columns) }),
            ("a refill", { feed(screen("refill")) }),
            (
                "a translucent window with a backdrop",
                {
                    var style = capture.renderer.style
                    style.backgroundOpacity = 0.7
                    capture.renderer.style = style
                    installBackdrop(on: capture)
                }
            ),
            ("an edit over the backdrop", { feed("\u{1b}[4;3Hover the picture") }),
            ("another edit over the backdrop", { feed("\u{1b}[8;6Hand again") }),
            ("the backdrop removed", { capture.renderer.setBackdrop(texture: nil, opacity: 0, mode: 0, pixelWidth: 0, pixelHeight: 0) }),
            ("an edit after it", { feed("\u{1b}[2;2Hafter") }),
        ]
    }

    /// The pinned scenario's surface: the constructed configuration in
    /// ``pinnedTheme``, over a ground at ``pinnedGroundOpacity``.
    ///
    /// The opacity is set on the style as well as named in the configuration:
    /// under Reduce Transparency the configuration draws the window opaque, and
    /// the scenario would compare a ground with nothing between two codes.
    private static func pinnedTranslucentSurface() -> SurfaceSnapshot? {
        var configuration = Ubiquitty.Preferences.Values()
        configuration.themeName = .init(std.string(pinnedTheme))
        configuration.backgroundOpacity = .init(pinnedGroundOpacity)
        guard
            let capture = SurfaceSnapshot(
                rows: rows,
                columns: columns,
                contentScale: 2,
                configuration: configuration
            )
        else { return nil }
        var style = capture.renderer.style
        style.backgroundOpacity = pinnedGroundOpacity
        capture.renderer.style = style
        return capture
    }

    /// The pinned scenario's steps, in order: an edit, whose margins a strip
    /// restores where the rebuild has the clear, then scrolls, whose exposed
    /// rows keep the padding the scroll's own clear left.
    private static func scrollSteps(_ capture: SurfaceSnapshot) -> [(String, () -> Void)] {
        func feed(_ text: String) {
            capture.feed(std.string(text))
        }
        return [
            ("first frame", { feed("\u{1b}[?25l" + screen("row")) }),
            ("settled", {}),
            ("an edited row", { feed("\u{1b}[3;5Hedited") }),
            ("history written", { feed("\u{1b}[\(rows);1H\r\nmore\r\nlines\r\nfor\r\nhistory") }),
            ("a line of history", { feed("\r\none more") }),
        ]
    }

    /// Installs a small generated gradient as the window backdrop.
    private static func installBackdrop(on capture: SurfaceSnapshot) {
        let size = 16
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = capture.renderer.device.makeTexture(descriptor: descriptor) else { return }
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let index = (y * size + x) * 4
                bytes[index] = UInt8(x * 16)
                bytes[index + 1] = UInt8(y * 16)
                bytes[index + 2] = 128
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size * 4)
        capture.renderer.setBackdrop(texture: texture, opacity: 0.6, mode: 0, pixelWidth: Int32(size), pixelHeight: Int32(size))
    }

    private static func firstDifferingRow(_ a: Data, _ b: Data, width: Int) -> String {
        let count = min(a.count, b.count) / 4
        var differing = 0
        var minRow = Int.max
        var maxRow = -1
        var minColumn = Int.max
        var maxColumn = -1
        for pixel in 0..<count {
            let index = pixel * 4
            if a[a.startIndex + index..<a.startIndex + index + 4] == b[b.startIndex + index..<b.startIndex + index + 4] { continue }
            differing += 1
            let row = pixel / max(width, 1)
            let column = pixel % max(width, 1)
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
            minColumn = min(minColumn, column)
            maxColumn = max(maxColumn, column)
        }
        return "\(differing) pixels in rows \(minRow)...\(maxRow), columns \(minColumn)...\(maxColumn)"
    }

    private static func failed(_ reason: String) -> Bool {
        print("grid-cache-smoke: FAIL: \(reason)")
        return false
    }
}
#endif
