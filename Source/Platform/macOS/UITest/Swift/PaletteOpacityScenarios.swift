// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PaletteOpacityScenarios — a theme's per-index foreground opacity reaches
// the Swift frame, and a program's OSC 4 write takes it back.
//
// The alpha lives in Core's palette beside the colour, and the frame capture
// reads it there on every frame; what this scenario reads is the alpha the
// built cell instance carries, which is what the screen was drawn with.

import AppKit
import UbiquittyKit

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

/// Pumps until the drawn alpha at the cell satisfies the predicate, or a few
/// seconds pass. Each turn asks for a frame that builds every row: a frame
/// that reuses the retained target builds only the rows the drain dirtied,
/// and a cell no frame rebuilt has no instance to read.
@MainActor
private func waitForDrawnAlpha(
    _ t: UBUITestContext,
    of surface: TerminalSurface,
    row: Int,
    column: Int,
    _ predicate: (Float) -> Bool
) -> Float? {
    var remaining = 30
    var alpha = surface.drawnForegroundAlphaForTesting(row: row, column: column)
    while !(alpha.map(predicate) ?? false), remaining > 0 {
        surface.invalidateRetainedBaseline()
        surface.needsDisplay = true
        t.pump(0.1)
        remaining -= 1
        alpha = surface.drawnForegroundAlphaForTesting(row: row, column: column)
    }
    return alpha
}

enum PaletteOpacityScenarios {
    static func register() {
        UBUITestRegister("swift_shell_a_dimmed_palette_index_draws_dimmed_until_the_program_rewrites_it") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A quiet child: the grid is what the scenario feeds, nothing more.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens on a quiet child with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.5)

                // The first theme's colours, with index 1 dimmed to half: what a
                // `#rrggbb80` red in a theme file applies.
                var indexedRGB = [UInt8](repeating: 0, count: 768)
                var defaultsRGB = [UInt8](repeating: 0, count: 9)
                let described = indexedRGB.withUnsafeMutableBufferPointer { indexed in
                    defaultsRGB.withUnsafeMutableBufferPointer { defaults in
                        Ubiquitty.Themes.themeColorBytes(0, indexed.baseAddress, defaults.baseAddress, nil)
                    }
                }
                t.expect(described, desc: "Core describes theme 0")
                var indexedAlpha = [UInt8](repeating: 255, count: 256)
                indexedAlpha[1] = 0x80
                t.expect(
                    surface.applyPalette(indexedRGB: indexedRGB, defaultsRGB: defaultsRGB, indexedAlpha: indexedAlpha),
                    desc: "the palette applies with its alpha"
                )

                // Red text at the origin, and a default-coloured cell beside it.
                surface.feed(Data("\u{1b}[H\u{1b}[31mX\u{1b}[0mY".utf8))
                let dimmed = waitForDrawnAlpha(t, of: surface, row: 0, column: 0) { abs($0 - 0.5) < 0.02 }
                t.expect(
                    dimmed.map { abs($0 - 0.5) < 0.02 } ?? false,
                    desc: "the dimmed index draws at half alpha (drawn \(dimmed.map { String($0) } ?? "nothing"))"
                )
                let plain = surface.drawnForegroundAlphaForTesting(row: 0, column: 1)
                t.expect(
                    plain.map { $0 > 0.98 } ?? false,
                    desc: "the default foreground beside it is opaque (drawn \(plain.map { String($0) } ?? "nothing"))"
                )

                // The program replaces the colour: its colour has no alpha, so
                // the theme's dimming of that slot is gone on the next frame,
                // with no theme re-apply and no keypress.
                surface.feed(Data("\u{1b}]4;1;rgb:ff/00/00\u{1b}\\".utf8))
                let rewritten = waitForDrawnAlpha(t, of: surface, row: 0, column: 0) { $0 > 0.98 }
                t.expect(
                    rewritten.map { $0 > 0.98 } ?? false,
                    desc: "an OSC 4 rewrite draws the slot opaque (drawn \(rewritten.map { String($0) } ?? "nothing"))"
                )

                // And OSC 104 gives the theme's dimming back with its colour.
                surface.feed(Data("\u{1b}]104;1\u{1b}\\".utf8))
                let restored = waitForDrawnAlpha(t, of: surface, row: 0, column: 0) { abs($0 - 0.5) < 0.02 }
                t.expect(
                    restored.map { abs($0 - 0.5) < 0.02 } ?? false,
                    desc: "OSC 104 restores the theme's alpha (drawn \(restored.map { String($0) } ?? "nothing"))"
                )
            }
        }
    }
}
