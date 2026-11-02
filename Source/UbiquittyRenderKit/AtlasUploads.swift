// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// AtlasUploads.swift — how a rasterised slot reaches its sheet.
//
// `MTLTexture.replace` is a CPU write ordered against nothing on the GPU's
// timeline. A frame committed moments ago is still sampling the sheet, and a
// slot rewritten under it hands one glyph's ink to another glyph's
// coordinates — a wrong letterform for a frame or two, recovering as soon as
// the row is drawn again. It reads as a font bug and it is a synchronisation
// bug, and no pixel oracle in the repo can see it: every one renders to a file
// behind a drain, which is the control arm of the race rather than a witness.
//
// Staging the bytes and copying them with a blit on the drawing queue puts the
// write where the ordering already exists — a queue runs its command buffers in
// the order they were committed, so a copy committed now lands after the frames
// that read those slots and before the frame that will.
//
import Metal

/// The staged path from a rasteriser's bytes to an atlas sheet.
///
/// One uploader serves every sheet of an atlas: the records carry their own
/// destination, so the batch is per queue rather than per texture.
package final class AtlasUploader {
    private struct Record {
        let texture: MTLTexture
        let offset: Int
        let bytesPerRow: Int
        let region: MTLRegion
    }

    /// How many buffers the ring holds.
    ///
    /// Three, because a batch is not waited on: the bytes must stay untouched
    /// until the GPU has copied them, and two more batches is longer than any
    /// frame's copy survives. The buffer's own command buffer is consulted
    /// before it is reused, so the depth is an optimisation rather than the
    /// guarantee.
    private static let ringDepth = 3

    /// The queue the copies are committed on.
    ///
    /// Shared by every renderer that samples this uploader's atlas. Switching
    /// queues after a flush would let another view read a cached slot before
    /// the previous queue uploads its pixels.
    private let queue: MTLCommandQueue
    private var ring: [MTLBuffer?]
    private var ringCommands: [MTLCommandBuffer?]
    private var ringIndex = 0
    private var used = 0
    private var records: [Record] = []
    private let device: MTLDevice
    private let capacityInBytes: Int
    /// What the staged path has carried, for the census.
    ///
    /// A fix that is not running looks exactly like a fix that did not work,
    /// and these two numbers tell those apart in one line.
    package private(set) var stagedCount = 0
    package private(set) var flushedCount = 0
    package private(set) var unorderedCount = 0

    /// Makes an uploader.
    ///
    /// - Parameters:
    ///   - queue: The atlas's upload and rendering command order.
    ///   - capacityInBytes: How much one batch stages before it is flushed.
    package init(queue: MTLCommandQueue, capacityInBytes: Int = 4 << 20) {
        self.queue = queue
        self.device = queue.device
        self.capacityInBytes = max(capacityInBytes, 1 << 16)
        self.ring = Array(repeating: nil, count: AtlasUploader.ringDepth)
        self.ringCommands = Array(repeating: nil, count: AtlasUploader.ringDepth)
        self.records.reserveCapacity(256)
    }

    /// Stages one slot's bytes for the next flush.
    ///
    /// A slot larger than the whole staging capacity is written directly,
    /// because a batch that cannot hold it has nothing to offer: the hazard it
    /// would avoid is smaller than the frame it would drop.
    ///
    /// - Parameters:
    ///   - bytes: The rasterised slot, tightly packed at `bytesPerRow`.
    ///   - bytesPerRow: The source pitch.
    ///   - region: Where the slot sits in the sheet.
    ///   - texture: The sheet.
    package func stage(
        _ bytes: UnsafeRawPointer,
        bytesPerRow: Int,
        region: MTLRegion,
        into texture: MTLTexture
    ) {
        let byteCount = bytesPerRow * region.size.height
        guard byteCount > 0 else { return }
        guard byteCount <= capacityInBytes else {
            unorderedCount += 1
            texture.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
            return
        }
        if used + byteCount > capacityInBytes {
            flush()
        }
        guard let buffer = buffer(atRingIndex: ringIndex) else {
            unorderedCount += 1
            texture.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
            return
        }
        buffer.contents().advanced(by: used).copyMemory(from: bytes, byteCount: byteCount)
        stagedCount += 1
        records.append(Record(texture: texture, offset: used, bytesPerRow: bytesPerRow, region: region))
        used += byteCount
    }

    /// Commits every staged copy on the drawing queue.
    ///
    /// On its own command buffer, never the frame's: a frame's buffer can be
    /// built and then dropped uncommitted — the image paths re-encode after
    /// priming their geometry — and a copy that rode a dropped buffer never
    /// arrives, which draws the row blank. Called before the frame's buffer is
    /// committed, so the copies are ordered ahead of the passes that read them.
    package func flush() {
        defer {
            records.removeAll(keepingCapacity: true)
            used = 0
        }
        guard !records.isEmpty, let buffer = ring[ringIndex] else {
            return
        }
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            // A refused command allocation must not drop cached coverage.
            unorderedCount += records.count
            for record in records {
                record.texture.replace(
                    region: record.region,
                    mipmapLevel: 0,
                    withBytes: buffer.contents().advanced(by: record.offset),
                    bytesPerRow: record.bytesPerRow
                )
            }
            return
        }
        for record in records {
            blit.copy(
                from: buffer,
                sourceOffset: record.offset,
                sourceBytesPerRow: record.bytesPerRow,
                sourceBytesPerImage: record.bytesPerRow * record.region.size.height,
                sourceSize: record.region.size,
                to: record.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: record.region.origin
            )
        }
        blit.endEncoding()
        commands.commit()
        flushedCount += records.count
        ringCommands[ringIndex] = commands
        ringIndex = (ringIndex + 1) % AtlasUploader.ringDepth
    }

    /// The ring's buffer at an index, made on first use and never written while
    /// its own batch is still in flight.
    ///
    /// - Parameter index: The ring slot.
    /// - Returns: The buffer, or nil when the device refuses one.
    private func buffer(atRingIndex index: Int) -> MTLBuffer? {
        if let inFlight = ringCommands[index], inFlight.status != .completed {
            inFlight.waitUntilCompleted()
            ringCommands[index] = nil
        }
        if let existing = ring[index] {
            return existing
        }
        ring[index] = device.makeBuffer(length: capacityInBytes, options: .storageModeShared)
        return ring[index]
    }
}
