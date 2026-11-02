// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RichTextSelectionSmoke.swift — a finger selects inside a rich text block
// (Docs/rich-text.md, "Selection and copy").
//
// The touch selection gesture reaches Core's pointer ladder with a click
// count of two, and inside a block the ladder takes the word around the
// character under the finger from Core's layout of the block, which the
// renderer drew from the table this phone measured. The smoke aims the touch
// through that layout, so a pass says the ladder took the word a finger was
// on, and then that a frame drew the highlight.

#if canImport(UIKit)

import Foundation
import UIKit
internal import UbiquittyCore

/// The launch-argument entry point.
public enum RichTextSelectionSmokeEntry {
    /// Runs the smoke.
    ///
    /// - Returns: Whether every leg passed.
    @MainActor
    public static func run() -> Bool { RichTextSelectionSmoke.run() }
}

enum RichTextSelectionSmoke {
    /// How long a leg waits for the frame it needs.
    private static let waitInSeconds = 3.0

    @MainActor
    static func run() -> Bool {
        // Through the factory, so the surface carries a renderer: the table a
        // block is laid out by is published when its first frame is cut.
        guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13) else {
            return failed("Core declined a surface, or the renderer could not be built")
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return failed("no window scene, so no view is ever asked to draw")
        }
        let window = UIWindow(windowScene: scene)
        surface.frame = window.bounds
        window.addSubview(surface)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        surface.layoutIfNeeded()
        guard wait(until: { surface.drawnFrameCount > 0 }) else {
            return failed("no frame was drawn, so no table was published")
        }

        let bytes = "\u{1b}]7404;w=40:h=3;{\\rtf1\\fs28 alpha beta gamma\\par delta}\u{1b}\\"
        let blocks =
            surface.drive.withTerminal { terminal -> Int in
                bytes.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
                return Int(terminal.richTextBlocks.blocks(.Primary).size())
            } ?? 0
        guard blocks == 1 else {
            return failed("the terminal holds \(blocks) blocks, not the one it was written")
        }
        surface.setNeedsDisplay()
        guard wait(until: { surface.frameRenderers.values.reduce(0) { $0 + $1.richTextStore.rasterCount } > 0 }) else {
            return failed("no frame drew the block")
        }

        // `t` of "beta" is character 8: a double tap on it, the touch word
        // gesture, takes the word around it, bounded by the block.
        guard let point = point(on: surface, atCharacter: 8) else {
            return failed("the block's layout names no point for its characters")
        }
        let framesBefore = surface.drawnFrameCount
        surface.selectionDrag(.began, atViewPoint: point)
        surface.selectionDrag(.ended, atViewPoint: point)
        guard surface.selectedText == "beta" else {
            return failed("a double tap on `t` selected \((surface.selectedText ?? "nothing").debugDescription), not \"beta\"")
        }
        surface.setNeedsDisplay()
        guard wait(until: { surface.drawnFrameCount > framesBefore }) else {
            return failed("no frame drew the selection")
        }
        report("rich-text-selection: a double tap inside a block selected \"beta\" and a frame drew it")
        return true
    }

    /// The middle of a character of the first block, in view coordinates,
    /// through Core's layout of the block.
    @MainActor
    private static func point(on surface: TerminalSurface, atCharacter index: Int) -> CGPoint? {
        let found = surface.drive.withTerminal { terminal -> (Int, Int, Ubiquitty.RichText.Layout)? in
            guard let block = terminal.richTextBlocks.blocks(.Primary).first else { return nil }
            return (Int(block.row), Int(block.column), Ubiquitty.RichText.layoutOf(terminal, block).pointee)
        }
        guard let read = found.flatMap({ $0 }) else { return nil }
        let (row, column, layout) = read
        guard let centre = surface.viewPoint(forRow: row, column: column),
            let right = surface.viewPoint(forRow: row, column: column + 1),
            let below = surface.viewPoint(forRow: row + 1, column: column)
        else { return nil }
        let cellWidth = right.x - centre.x
        let cellHeight = below.y - centre.y
        for lineIndex in 0..<layout.visibleLineCount() {
            let line = layout.line(lineIndex)
            guard Int(line.first) <= index, index < Int(line.end) else { continue }
            let left = Double(layout.leftEdge(line, index))
            let across = Double(line.origin) + (left + Double(layout.rightEdge(index))) / 2
            let down = Double(line.top) + Double(line.height) / 2
            return CGPoint(
                x: centre.x - cellWidth / 2 + CGFloat(across / Double(layout.cellWidth())) * cellWidth,
                y: centre.y - cellHeight / 2 + CGFloat(down / Double(layout.cellHeight())) * cellHeight
            )
        }
        return nil
    }

    @MainActor
    private static func wait(until condition: () -> Bool) -> Bool {
        let start = Date()
        while !condition() {
            guard Date().timeIntervalSince(start) < waitInSeconds else { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0))
        }
        return true
    }

    private static func failed(_ reason: String) -> Bool {
        report("rich-text-selection: FAIL: \(reason)")
        return false
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

#endif
