// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit

/// Whether a remote pane draws the inline images its terminal holds.
///
/// Every pane here is a thin client: the host decodes a picture and its pixels
/// and placements reach the passive terminal's image store over the wire, which
/// `sync_image_e2e` pins against a real daemon. What only a live application
/// can show is the other half — the shared renderer finding the stored image,
/// uploading it as a texture and laying a quad over the cells it covers, on a
/// surface hosted the way the app hosts one. The images are written into the
/// passive terminal here rather than delivered over a carrier, which reaches
/// the same store the IMAGE frames' apply writes.
///
/// Both protocols the host relays are written: the iTerm2 OSC 1337
/// `File=inline=1` form and a Kitty graphics transmit-and-place.
enum InlineImageSmokeEntry {
    /// How long the walk waits for the frame that draws both pictures.
    private static let walkInSeconds = 3.0

    /// A 24x24 RGB PNG in four flat quadrants, the snapshot tier's own feed.
    private static let quadrantsPNG =
        "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAL0lEQVR42mO4Y6RPELXOZCCIGEYNGjVo1CC8Bql1XyKItnYyEESjBo0aNGoQXgQAtVDf3/jjW+IAAAAASUVORK5CYII="

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
        let hostBytes =
            "\u{1b}]1337;File=inline=1;width=24px;height=24px;size=104:\(quadrantsPNG)\u{7}\r\n"
            + "\u{1b}_Gf=100,a=T,i=77;\(quadrantsPNG)\u{1b}\\\r\n"
        let storedImages =
            surface.drive.withTerminal { terminal -> Int in
                hostBytes.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
                return (0..<Int(Ubiquitty.Image.maxTerminalImageCount))
                    .count { index in
                        Ubiquitty.Image.stored(terminal, Int32(index)) != nil
                    }
            } ?? 0
        guard storedImages >= 2 else {
            return failed("the terminal stored \(storedImages) of the two images it was written")
        }
        guard let window = SmokeLaunch.present(surface) else {
            return failed("no window to present in")
        }
        defer { window.isHidden = true }

        let start = Date()
        surface.setNeedsDisplay()
        var mostQuads: Int32 = -1
        while Date().timeIntervalSince(start) < walkInSeconds, mostQuads < 2 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0))
            mostQuads = max(mostQuads, surface.lastFrameImageQuadCount)
        }
        guard mostQuads >= 2 else {
            return failed(
                "no frame drew both images (most textured quads in one frame \(mostQuads), frames \(surface.drawnFrameCount))"
            )
        }
        return true
    }

    private static func failed(_ reason: String) -> Bool {
        SmokeLaunch.report("inline-image: FAIL: \(reason)")
        return false
    }
}
