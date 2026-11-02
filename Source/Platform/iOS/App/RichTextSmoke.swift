// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit

/// Whether a remote pane draws a rich text block in the phone's own metrics
/// (Docs/rich-text.md).
///
/// The host lays a block out and answers its programs' queries by the table the
/// client publishes, which Core's loopback tests pin over a real connection.
/// What only a live application can show is the phone's half: the shared
/// renderer measuring the faces it draws in, publishing that table to the
/// pane — and through its thin-client session to the host — and drawing the
/// block from it. The block is written into the passive terminal, which
/// reaches the store the screen plane's apply writes.
enum RichTextSmokeEntry {
    /// How long the walk waits for the frame that draws the block.
    private static let walkInSeconds = 3.0

    @MainActor
    static func run() -> Bool {
        let model = TerminalSessionModel()
        guard let surface = model.makePaneSurface() else {
            return failed("Core declined a surface")
        }
        let carrier = HeldCarrier()
        guard let factory = carrier.makeFactory() else {
            return failed("no carrier factory")
        }
        guard surface.attachRemoteOverCarrier(carrierFactory: ubiquittyIOSQUICFactoryAddress(factory)),
            surface.drive.isRemoteAttached
        else {
            return failed("the surface did not become a thin client")
        }
        let hostBytes = "\u{1b}]7404;w=30:h=4;{\\rtf1\\fs32\\b Phone\\b0\\par\\fs24 drawn in the phone's own faces}\u{1b}\\"
        let blocks =
            surface.drive.withTerminal { terminal -> Int in
                hostBytes.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
                return Int(terminal.richTextBlocks.blocks(.Primary).size())
            } ?? 0
        guard blocks == 1 else {
            return failed("the terminal holds \(blocks) blocks, not the one it was written")
        }
        guard let window = SmokeLaunch.present(surface) else {
            return failed("no window to present in")
        }
        defer { window.isHidden = true }

        let start = Date()
        surface.setNeedsDisplay()
        var rasters = 0
        while Date().timeIntervalSince(start) < walkInSeconds, rasters == 0 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0))
            rasters = surface.frameRenderers.values.reduce(0) { $0 + $1.richTextStore.rasterCount }
        }
        guard rasters > 0 else {
            return failed("no frame drew the block (frames \(surface.drawnFrameCount))")
        }
        // The table the block was laid out by is the one this renderer
        // measured: the three class faces in four styles, and a cell.
        let summary = surface.drive.withTerminal { Ubiquitty.RichText.typographySummary($0) }
        guard let summary, summary.faceCount == 12, summary.cellWidth > 0, summary.cellHeight > summary.cellWidth else {
            return failed("the pane holds no table measured from the phone's faces")
        }
        SmokeLaunch.report(
            "rich-text: cell \(Double(summary.cellWidth) / 64)x\(Double(summary.cellHeight) / 64) pt, \(summary.faceCount) faces, \(rasters) rasters"
        )
        return true
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("rich-text: FAIL: \(reason)")
        return false
    }
}
