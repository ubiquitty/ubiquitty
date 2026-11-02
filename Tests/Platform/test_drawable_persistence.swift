// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_drawable_persistence.swift
//
// Whether a drawable comes back holding what was last drawn into it.
//
// The full-screen composite's pass two samples the whole retained grid into
// the drawable every frame, damaged or not. Compositing only the damage rests
// on one platform fact — whether a drawable handed back by the pool still
// holds the pixels written to it last time it came round. Metal
// documents the contents as undefined on acquisition. Undefined is not the
// same as discarded, and the difference is the difference between a partial
// composite that works on this hardware and one that shows stale rows.
//
// So this asks the pool, on the machine the answer is for. It is a probe of
// platform behaviour, not of our code: a red verdict is not a bug in Ubiquitty,
// it is the answer being no.
//
// An offscreen CAMetalLayer, because a drawable pool needs a layer and a layer
// does not need a window. framebufferOnly is off so the contents can be read
// back at all -- which is itself a cost a real partial-composite path would
// pay, and is noted in the verdict.
//
// Compiled by plain `xcrun swiftc`. A failure prints FAIL file:line, and any
// failure exits nonzero.
//

import Foundation
import Metal
import QuartzCore

var failures = 0

func check(_ condition: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        print("FAIL \(file):\(line): \(what)")
        failures += 1
    }
}

let probeWidth = 256
let probeHeight = 256

/// Fills the whole drawable with one colour, so a later read says which frame
/// last wrote it.
func paint(_ commands: MTLCommandBuffer, _ target: MTLTexture, red: Double) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(red, 0.0, 0.0, 1.0)
    commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
}

/// The red channel of the texture's first pixel, or -1 when it cannot be read.
///
/// A framebuffer-only texture refuses the read; that is checked up front
/// rather than left to trap, so a pool that hands one out reads as unreadable.
func redOf(_ texture: MTLTexture) -> Int {
    if texture.isFramebufferOnly || texture.storageMode == .private {
        return -1
    }
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { bytes in
        texture.getBytes(bytes.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    }
    // BGRA8: red is the third byte.
    return Int(pixel[2])
}

@main
struct DrawablePersistenceTest {
    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            check(false, "a Metal device exists")
            print("test_drawable_persistence: no Metal device — nothing to ask")
            exit(0)
        }
        let queue = device.makeCommandQueue()
        check(queue != nil, "the device makes a command queue")
        guard let queue else {
            exit(1)
        }

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false // or getBytes below cannot read a thing
        layer.drawableSize = CGSize(width: probeWidth, height: probeHeight)
        layer.maximumDrawableCount = 3

        // Each pass paints its own shade and records which texture took it.
        // Enough passes to come round the pool several times.
        let passes = 12
        var lastShadeWritten: [ObjectIdentifier: Int] = [:]
        var slotsSeen = 0
        var slotsRevisited = 0
        var slotsHoldingWhatWasWritten = 0
        var slotsReadable = 0

        for pass in 0..<passes {
            guard let drawable = layer.nextDrawable() else {
                continue
            }
            let identity = ObjectIdentifier(drawable.texture)

            if let written = lastShadeWritten[identity] {
                slotsRevisited += 1
                let found = redOf(drawable.texture)
                if found >= 0 {
                    slotsReadable += 1
                    // Within one step of the byte that was written: the shade
                    // is stored through an 8-bit channel, so an exact match is
                    // not the question, holding it at all is.
                    if found >= written - 1 && found <= written + 1 {
                        slotsHoldingWhatWasWritten += 1
                    }
                }
            } else {
                slotsSeen += 1
            }

            let shade = 20 + pass * 15
            guard let commands = queue.makeCommandBuffer() else {
                continue
            }
            paint(commands, drawable.texture, red: Double(shade) / 255.0)
            commands.present(drawable)
            commands.commit()
            commands.waitUntilCompleted()
            lastShadeWritten[identity] = shade
        }

        // The probe reached the state it exists to ask about. Without this a
        // pool that handed out a fresh texture every time would report "no
        // stale content found" and read like a clean answer.
        check(slotsSeen > 0, "the pool handed out at least one drawable")
        check(slotsRevisited > 0, "the pool handed a drawable back at least once")

        print(
            "test_drawable_persistence: \(slotsSeen) distinct drawable(s), revisited \(slotsRevisited) time(s); "
                + "\(slotsReadable) readable, \(slotsHoldingWhatWasWritten) still held what was written"
        )
        if slotsReadable == 0 {
            print("  contents could not be read back at all — a partial composite cannot be based on them here")
        } else if slotsHoldingWhatWasWritten == slotsReadable {
            print(
                "  every revisited drawable held its previous contents: a partial composite has something to build on, "
                    + "subject to per-slot tracking"
            )
        } else {
            print(
                "  \(slotsReadable - slotsHoldingWhatWasWritten) of \(slotsReadable) revisited drawables came back changed: "
                    + "a partial composite would show stale or cleared pixels"
            )
        }

        if failures == 0 {
            print("test_drawable_persistence: all passed")
        } else {
            print("test_drawable_persistence: \(failures) failure(s)")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
