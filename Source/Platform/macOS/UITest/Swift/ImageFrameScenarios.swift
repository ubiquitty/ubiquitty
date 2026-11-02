// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ImageFrameScenarios — a chafa image reaches the DRAWN FRAME and stays there.
//
// The Core seam is pinned separately (test_sixel_lifecycle,
// test_kitty_placeholders): the model keeps the image, the placement, and the
// partition through everything a shell does. These scenarios assert the same
// facts one layer up, on `lastFrameImageQuadCount` — what the last built frame
// actually carried — because the reported bugs (a sixel that vanishes on a
// keystroke, a placeholder image drawn as a screenful of copies) were invisible
// to every model-level probe. The model was right and the frame was not.

import AppKit
import UbiquittyCore
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

/// A 6x6 all-painted single-color sixel: raster 1:1, six `~` columns, each
/// covering six vertical pixels. What `chafa` emits, minus the palette runs.
private let smallSixel = "\u{1b}P0;0;0q\"1;1;6;6#0;2;100;0;0#0~~~~~~\u{1b}\\"

/// chafa's kitty shape: a control-only opener carrying every key (the c/r
/// virtual grid included), pixel chunks under m=1, the tail on m=0 — then
/// U+10EEEE placeholder cells, the image id in the 256-color foreground and
/// (row, column) in combining diacritics.
private func chunkedKittyTransmit() -> String {
    // 8x8 RGBA, all one value; 64 base64 characters per chunk like a small chafa.
    let rgba = [UInt8](repeating: 0x7F, count: 8 * 8 * 4)
    let encoded = Data(rgba).base64EncodedString()
    var out = "\u{1b}_Ga=T,U=1,q=2,f=32,s=8,v=8,c=2,r=2,i=1,m=1\u{1b}\\"
    var index = encoded.startIndex
    while encoded.distance(from: index, to: encoded.endIndex) > 64 {
        let next = encoded.index(index, offsetBy: 64)
        out += "\u{1b}_Gm=1;\(encoded[index..<next])\u{1b}\\"
        index = next
    }
    out += "\u{1b}_Gm=0;\(encoded[index...])\u{1b}\\"
    return out
}

/// Two rows of two placeholder cells for image id 1: U+10EEEE with the row and
/// column diacritics U+0305 (0) and U+030D (1).
private func placeholderGrid2x2() -> String {
    let diacritic: [Character] = ["\u{0305}", "\u{030D}"]
    var out = "\u{1b}[38;5;1m"
    for row in 0..<2 {
        for column in 0..<2 {
            out.append("\u{10EEEE}")
            out.append(diacritic[row])
            out.append(diacritic[column])
        }
        out += "\r\n"
    }
    out += "\u{1b}[39m"
    return out
}

@MainActor
private func pressKey(_ character: String, keyCode: UInt16, on surface: TerminalSurface) {
    if let press = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: keyCode
    ) {
        _ = surface.sendKey(press, eventType: .Press)
    }
}

enum ImageFrameScenarios {
    static func register() {
        UBUITestRegister("inline_image_protocols_preserve_measured_pixel_aspect") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift terminal opens for pixel measurement")
                    return
                }
                defer { shell.shellCloseWindow() }
                t.pump(0.3)
                for (width, height) in [(120, 60), (90, 90), (60, 120)] {
                    guard
                        let bitmap = NSBitmapImageRep(
                            bitmapDataPlanes: nil,
                            pixelsWide: width,
                            pixelsHigh: height,
                            bitsPerSample: 8,
                            samplesPerPixel: 4,
                            hasAlpha: true,
                            isPlanar: false,
                            colorSpaceName: .deviceRGB,
                            bytesPerRow: width * 4,
                            bitsPerPixel: 32
                        )
                    else {
                        t.expect(false, desc: "the source bitmap can be allocated")
                        return
                    }
                    for row in 0..<height {
                        for column in 0..<width {
                            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: column, y: row)
                        }
                    }
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        t.expect(false, desc: "the iTerm2 fixture can be encoded as PNG")
                        return
                    }
                    let rgb = Data(Array(repeating: [UInt8(255), 0, 0], count: width * height).flatMap { $0 })
                    let band = String(repeating: "~", count: width)
                    let sixel = Array(repeating: band, count: height / 6).joined(separator: "-")
                    let sourceAspect = Double(width) / Double(height)
                    let cellAspect = surface.drawnCellSizeForTesting.map { Double($0.width / $0.height) } ?? 0
                    let fixtures: [(String, String, Double)] = [
                        ("kitty", "\u{1b}_Ga=T,f=24,s=\(width),v=\(height),q=2;\(rgb.base64EncodedString())\u{1b}\\", sourceAspect),
                        (
                            "kitty-width", "\u{1b}_Ga=T,f=24,s=\(width),v=\(height),c=7,q=2;\(rgb.base64EncodedString())\u{1b}\\",
                            sourceAspect
                        ),
                        (
                            "kitty-height", "\u{1b}_Ga=T,f=24,s=\(width),v=\(height),r=3,q=2;\(rgb.base64EncodedString())\u{1b}\\",
                            sourceAspect
                        ),
                        (
                            "kitty-stretch", "\u{1b}_Ga=T,f=24,s=\(width),v=\(height),c=7,r=4,q=2;\(rgb.base64EncodedString())\u{1b}\\",
                            cellAspect * 7 / 4
                        ),
                        ("iterm2", "\u{1b}]1337;File=inline=1:\(png.base64EncodedString())\u{7}", sourceAspect),
                        ("iterm2-width", "\u{1b}]1337;File=inline=1;width=8:\(png.base64EncodedString())\u{7}", sourceAspect),
                        ("iterm2-box", "\u{1b}]1337;File=inline=1;width=8;height=8:\(png.base64EncodedString())\u{7}", sourceAspect),
                        (
                            "iterm2-stretch",
                            "\u{1b}]1337;File=inline=1;width=8;height=8;preserveAspectRatio=0:\(png.base64EncodedString())\u{7}", cellAspect
                        ),
                        ("sixel", "\u{1b}P0;1;0q\"1;1;\(width);\(height)#0;2;100;0;0#0\(sixel)\u{1b}\\", sourceAspect),
                        ("sixel-tall-pixels", "\u{1b}P0;1;0q\"2;1;\(width);\(height)#0;2;100;0;0#0\(sixel)\u{1b}\\", sourceAspect / 2),
                        ("sixel-wide-pixels", "\u{1b}P0;1;0q\"1;2;\(width);\(height)#0;2;100;0;0#0\(sixel)\u{1b}\\", sourceAspect * 2),
                    ]
                    for (name, bytes, expectedAspect) in fixtures {
                        surface.feed(Data("\u{1b}[2J\u{1b}[?25l\u{1b}]11;rgb:00/00/00\u{7}\u{1b}[H".utf8))
                        surface.feed(Data(bytes.utf8))
                        t.pump(0.3)
                        surface.needsDisplay = true
                        t.pump(0.2)
                        guard let frame = surface.renderedFrameForTesting() else {
                            t.expect(false, desc: "the image frame can be read back from Metal")
                            return
                        }
                        var left = frame.width
                        var right = -1
                        var top = frame.height
                        var bottom = -1
                        for row in 0..<frame.height {
                            for column in 0..<frame.width {
                                let offset = (row * frame.width + column) * 4
                                if frame.pixels[offset + 2] > 200 && frame.pixels[offset + 1] < 80 && frame.pixels[offset] < 80 {
                                    left = min(left, column)
                                    right = max(right, column)
                                    top = min(top, row)
                                    bottom = max(bottom, row)
                                }
                            }
                        }
                        let drawnWidth = max(0, right - left + 1)
                        let drawnHeight = max(0, bottom - top + 1)
                        let ratio = Double(drawnWidth) / Double(max(1, drawnHeight))
                        FileHandle.standardOutput.write(
                            Data(
                                "image-aspect: \(name) source=\(width)x\(height) rendered=\(drawnWidth)x\(drawnHeight) ratio=\(ratio)\n"
                                    .utf8
                            )
                        )
                        t.expect(
                            drawnWidth > 0 && drawnHeight > 0
                                && abs(Double(drawnWidth) - Double(drawnHeight) * expectedAspect) <= max(1, expectedAspect),
                            desc: "\(name) renders aspect \(expectedAspect) in pixels (\(drawnWidth)x\(drawnHeight))"
                        )
                    }
                }
            }
        }
        UBUITestRegister("swift_shell_kitty_local_file_reaches_the_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift terminal opens")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.drive.stopIngest()
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    try Data([255, 0, 0]).write(to: file)
                } catch {
                    t.expect(false, desc: "the fixture file is writable")
                    return
                }
                let directory = file.deletingLastPathComponent().absoluteString
                surface.feed(Data("\u{1b}]7;\(directory)\u{1b}\\".utf8))
                let path = Data(file.path.utf8).base64EncodedString()
                surface.feed(Data("\u{1b}_Ga=T,t=f,f=24,s=1,v=1,i=91,q=2;\(path)\u{1b}\\".utf8))
                surface.drive.withTerminal { terminal in
                    t.expect(Ubiquitty.Image.placementCount(terminal) > 0, desc: "the protocol placed the file image")
                }
                surface.needsDisplay = true
                t.expect(
                    t.wait(until: { surface.lastFrameImageQuadCount > 0 }, timeout: 3),
                    desc: "the local file transport draws an image"
                )
            }
        }

        UBUITestRegister("swift_shell_a_live_resize_carries_the_picture_across_a_redraw_gap") { context in
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

                // An image application redraws by deleting and re-placing its
                // picture every frame. Off a drag, the delete is a delete.
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(Data(smallSixel.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount >= 1,
                    desc: "the sixel reaches the frame (\(surface.lastFrameImageQuadCount) quads)"
                )
                surface.feed(Data("\u{1b}[2J".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount == 0,
                    desc: "with no drag running a whole-screen clear takes the picture"
                        + " (\(surface.lastFrameImageQuadCount) quads)"
                )

                // Inside a drag the same clear is the gap between the delete and
                // the re-place, and a frame captured there must not blank the
                // picture — that is the resize blink.
                surface.feed(Data(smallSixel.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                surface.viewWillStartLiveResize()
                surface.feed(Data("\u{1b}[2J".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount >= 1,
                    desc: "mid-drag the last good layer is carried across the gap"
                        + " (\(surface.lastFrameImageQuadCount) quads)"
                )
                surface.feed(Data(smallSixel.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount >= 1,
                    desc: "and the re-placed picture resolves again (\(surface.lastFrameImageQuadCount) quads)"
                )

                // The drag ends, and a delete is a delete again.
                surface.viewDidEndLiveResize()
                surface.feed(Data("\u{1b}[2J".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount == 0,
                    desc: "after the drag the clear takes the picture (\(surface.lastFrameImageQuadCount) quads)"
                )
            }
        }

        UBUITestRegister("swift_shell_sixel_image_reaches_the_frame_and_stays") { context in
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

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(Data(smallSixel.utf8))
                surface.feed(Data("\r\n".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount >= 1,
                    desc: "the sixel reaches the frame (\(surface.lastFrameImageQuadCount) quads)"
                )
                // And the pixels moved to the texture off the model lock. The
                // picture is the same either way — what a transfer under the
                // lock costs is the parser's wait for it, so the work is what
                // is counted rather than the result.
                t.expect(
                    surface.offLockImageUploadCount >= 1,
                    desc: "its pixels were uploaded off the model lock"
                        + " (\(surface.offLockImageUploadCount) uploads)"
                )

                // A keystroke and its echo — the shape of the vanish report.
                pressKey("x", keyCode: 7, on: surface)
                surface.feed(Data("x".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount >= 1,
                    desc: "a keystroke does not take it (\(surface.lastFrameImageQuadCount) quads)"
                )

                // Push it off screen, then step the view back into scrollback.
                let rows = Int(surface.drive.readSnapshot().rows)
                for _ in 0..<(rows + 2) {
                    surface.feed(Data("filler\r\n".utf8))
                }
                surface.needsDisplay = true
                t.pump(0.3)
                surface.offsetView(byLines: rows + 2)
                surface.needsDisplay = true
                t.pump(0.3)
                t.expect(
                    surface.lastFrameImageQuadCount >= 1,
                    desc: "scrolled back to, it is still drawn (\(surface.lastFrameImageQuadCount) quads)"
                )
            }
        }

        UBUITestRegister("swift_shell_kitty_placeholders_draw_once_partitioned") { context in
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

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(Data(chunkedKittyTransmit().utf8))
                surface.feed(Data(placeholderGrid2x2().utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                // Exactly four: one per placeholder cell. One would be an
                // unpartitioned image; more would be the reported copies.
                t.expect(
                    surface.lastFrameImageQuadCount == 4,
                    desc: "four placeholder cells draw four quads (\(surface.lastFrameImageQuadCount))"
                )

                // Keystrokes must not multiply it.
                for _ in 0..<3 {
                    pressKey("y", keyCode: 16, on: surface)
                    surface.feed(Data("y".utf8))
                    surface.needsDisplay = true
                    t.pump(0.15)
                }
                t.expect(
                    surface.lastFrameImageQuadCount == 4,
                    desc: "typing leaves the four quads four (\(surface.lastFrameImageQuadCount))"
                )
            }
        }
    }
}

extension ImageFrameScenarios {
    /// The end-to-end truth: REAL chafa in a REAL login shell, both formats,
    /// watched at the frame. The synthetic cases above pass while the report
    /// stands, so the divergence — if it is in this app at all — lives in what
    /// a live shell adds: detection probes, prompt redraw, timing.
    static func registerRealChafa() {
        UBUITestRegister("swift_shell_real_chafa_draws_and_stays") { context in
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
                t.pump(1.0) // the login shell's prompt

                // Self-contained input: a 2x2 RGBA PAM the shell writes itself,
                // alpha 0x80 throughout — stacked copies of a SEMI-TRANSPARENT
                // image compose darker instead of overdrawing idempotently, so
                // the stacking under test cannot hide behind an opaque repaint.
                surface.transmitAsUserInput(
                    "printf 'P7\\nWIDTH 2\\nHEIGHT 2\\nDEPTH 4\\nMAXVAL 255\\nTUPLTYPE RGB_ALPHA\\nENDHDR\\n' > /tmp/ubq-uitest-chafa.pam; "
                        + "printf '\\377\\000\\000\\200\\000\\377\\000\\200\\000\\000\\377\\200\\377\\377\\000\\200' >> /tmp/ubq-uitest-chafa.pam\r"
                )
                t.pump(0.5)

                // Hard-fail, never skip: without chafa this scenario proves
                // nothing, and a silent return would read as coverage.
                surface.transmitAsUserInput("command -v chafa >/dev/null || echo UBQ-NO-CHAFA\r")
                t.pump(0.5)

                // The model's own answer, beside the frame's: when they
                // disagree, the divergence names the layer that lost the image.
                @MainActor
                func modelQuadCount() -> Int {
                    surface.drive.withTerminal { term -> Int in
                        var quads = [Ubiquitty.Image.ImageQuad](repeating: .init(), count: 64)
                        return quads.withUnsafeMutableBufferPointer { buffer in
                            Int(
                                Ubiquitty.Rendering.collectImageQuads(
                                    term,
                                    .init(width: 10, height: 20),
                                    .init(x: 0, y: 0),
                                    1.0,
                                    0,
                                    .init(buffer),
                                    .init(width: 0, height: 0)
                                )
                            )
                        }
                    } ?? -1
                }

                @MainActor
                func quadsSettle(atLeast floor: Int32, within seconds: Double, why: String) -> Int32 {
                    let deadline = Date().addingTimeInterval(seconds)
                    while Date() < deadline {
                        surface.needsDisplay = true
                        t.pump(0.2)
                        if surface.lastFrameImageQuadCount >= floor {
                            return surface.lastFrameImageQuadCount
                        }
                    }
                    t.expect(false, desc: "\(why) (frame \(surface.lastFrameImageQuadCount), model \(modelQuadCount()))")
                    return surface.lastFrameImageQuadCount
                }

                surface.transmitAsUserInput("chafa --format=sixel --size=10x5 /tmp/ubq-uitest-chafa.pam; echo UBQ-RC=$?\r")
                let sixelQuads = quadsSettle(atLeast: 1, within: 8.0, why: "real chafa sixel reaches the frame")
                if sixelQuads >= 1 {
                    surface.transmitAsUserInput("x")
                    surface.needsDisplay = true
                    t.pump(0.5)
                    t.expect(
                        surface.lastFrameImageQuadCount >= 1,
                        desc: "a typed character does not take the sixel (\(surface.lastFrameImageQuadCount) quads)"
                    )
                }

                // Kitty second — the forced format of the copies report. The
                // count must SETTLE: reaching a level and then growing past it
                // on later frames is exactly "adds copies over and over".
                surface.transmitAsUserInput("\u{15}\r") // ^U clears the typed x
                t.pump(0.3)
                surface.transmitAsUserInput("chafa --format=kitty --size=10x5 /tmp/ubq-uitest-chafa.pam\r")
                let kittyQuads = quadsSettle(atLeast: 1, within: 8.0, why: "real chafa kitty reaches the frame")
                if kittyQuads >= 1 {
                    // The reported copies accumulated on a roughly half-second
                    // cadence, so one glance after settling proves nothing:
                    // watch the count across three seconds of frames.
                    t.pump(1.0)
                    let after = surface.lastFrameImageQuadCount
                    t.expect(
                        after <= kittyQuads + Int32(sixelQuads),
                        desc: "the kitty quads settle rather than multiply (was \(kittyQuads), now \(after))"
                    )
                    for _ in 0..<6 {
                        surface.needsDisplay = true
                        t.pump(0.5)
                        t.expect(
                            surface.lastFrameImageQuadCount <= after,
                            desc: "no copy joined over the watch (\(surface.lastFrameImageQuadCount) vs \(after))"
                        )
                    }
                    surface.transmitAsUserInput("y")
                    surface.needsDisplay = true
                    t.pump(0.5)
                    t.expect(
                        surface.lastFrameImageQuadCount <= after,
                        desc: "typing does not add copies (\(surface.lastFrameImageQuadCount))"
                    )
                }
            }
        }
    }
}
