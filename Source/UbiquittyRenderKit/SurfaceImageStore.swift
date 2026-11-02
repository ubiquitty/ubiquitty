// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// SurfaceImageStore.swift — the inline images a surface's frames composite:
// kitty and iTerm2 placements and sixel bands, as Metal textures keyed by the
// model's image ids, and the per-frame layer of quads over them.
//
// The model keeps the pixels (Core/Image/TerminalImage.h); this keeps one
// texture per stored image, re-uploaded when the image's content stamp moves
// — a new frame of an animation, a replaced upload — and dropped when the
// model drops the image. An image a filtered quad draws carries a mip chain,
// built by Core's rule (`Image::downsampleImageMipLevel`) so its levels are
// the ones the CPU arm samples; one only ever drawn at a whole-number
// enlargement carries level zero alone and costs what it did. The layer is
// resolved by Core in the protocol's draw order
// (`collectImageQuadsOrdered`), so what the surface draws follows the
// protocol's layer order.
//
import Metal
import UbiquittyCore

/// One surface's inline-image textures and the layer its next frame draws.
package final class SurfaceImageStore {
    private struct Entry {
        var texture: MTLTexture?
        var stamp: UInt64 = 0
        var isSeenThisSync = false
        /// Pixels copied out of the model, waiting for their upload.
        ///
        /// The copy happens under the model lock because the model owns the
        /// bytes; the upload does not, because a pixel transfer is the
        /// frontend's own work and holding the lock through it stalls the
        /// thread parsing the host's output. Empty once uploaded.
        var stagedPixels: [UInt8] = []
        var stagedWidth = 0
        var stagedHeight = 0
        /// Whether the texture carries a mip chain, filled at upload.
        var isMipmapped = false
    }

    private let device: MTLDevice
    private var entries: [UInt32: Entry] = [:]
    private var quadScratch: [Ubiquitty.Image.ImageQuad]
    private var quads: GrowableBuffer
    private var textures: [MTLTexture?] = []
    private var isFiltered: [Bool] = []

    /// The last layer a frame resolved, kept for a frame that cannot.
    ///
    /// Its own allocation rather than a reference into `quads`: the next
    /// resolve writes `quads` in place, and a carry that pointed there would
    /// carry whatever that resolve left, which for the gap it exists for is
    /// nothing. Which frames carry is `Rendering::imageLayerAction`.
    private var carriedQuads: GrowableBuffer
    private var carriedTextures: [MTLTexture?] = []
    private var carriedIsFiltered: [Bool] = []
    private var carriedSplit = 0
    private var carriedCount = 0

    /// Whether the resolved layer contains pixels that a replacement frame must erase.
    package var hasResolvedImages: Bool { carriedCount > 0 }

    /// Builds a store over the device the surface's renderer draws with.
    ///
    /// - Parameter device: The Metal device.
    package init(device: MTLDevice) {
        self.device = device
        self.quads = GrowableBuffer(
            device: device,
            growth: .geometric,
            stride: MemoryLayout<Ubiquitty.Rendering.ImageInstance>.stride
        )
        self.carriedQuads = GrowableBuffer(
            device: device,
            growth: .geometric,
            stride: MemoryLayout<Ubiquitty.Rendering.ImageInstance>.stride
        )
        self.quadScratch = [Ubiquitty.Image.ImageQuad](
            repeating: Ubiquitty.Image.ImageQuad(),
            count: Int(Ubiquitty.Image.maxTerminalImagePlacementCount)
        )
    }

    /// Brings the textures up to the model's images, under the model lock.
    ///
    /// An image whose stamp — size, frame, format, content generation — the
    /// entry already holds is left alone; one that moved is re-uploaded into
    /// a texture of its size; one the model no longer stores is dropped. An
    /// image a filtered quad draws gets a mipmapped texture, uploaded again
    /// once when an image first drawn sharp is first drawn filtered.
    ///
    /// - Parameters:
    ///   - terminal: The model, read under its lock.
    ///   - filteredImages: The ids of the images this frame filters.
    private func sync(from terminal: Ubiquitty.Terminal, filteredImages: Set<UInt32>) {
        for key in entries.keys {
            entries[key]?.isSeenThisSync = false
        }
        for index in 0..<Int(Ubiquitty.Image.maxTerminalImageCount) {
            guard let image = Ubiquitty.Image.stored(terminal, Int32(index)) else { continue }
            sync(image: image.pointee, isFiltered: filteredImages.contains(image.pointee.imageID))
        }
        entries = entries.filter { $0.value.isSeenThisSync }
    }

    /// The ids of the images the first `count` resolved quads filter.
    ///
    /// - Parameter count: How many of the scratch quads the frame resolved.
    /// - Returns: The ids whose quads Core marked `Smooth`.
    private func filteredImages(count: Int) -> Set<UInt32> {
        var filtered = Set<UInt32>()
        for index in 0..<count where quadScratch[index].filter == .Smooth {
            filtered.insert(quadScratch[index].imageID)
        }
        return filtered
    }

    /// Builds the image layer from the immutable frame, without borrowing the live model.
    package func layer(for capture: Ubiquitty.Rendering.FrameCapture) -> ImageLayer? {
        let capturedQuads = capture.imageQuads()
        let count = capturedQuads.count
        for (index, quad) in capturedQuads.enumerated() {
            quadScratch[index] = quad
        }
        let filtered = filteredImages(count: count)
        for key in entries.keys {
            entries[key]?.isSeenThisSync = false
        }
        for image in capture.images() {
            sync(image: image, isFiltered: filtered.contains(image.imageID))
        }
        entries = entries.filter { $0.value.isSeenThisSync }
        var frame = Ubiquitty.Rendering.ImageLayerFrame()
        frame.hasPlacements = count > 0
        frame.canResolve = true
        frame.resolvedPlacements = Int32(count)
        return resolvedLayer(frame: frame, resolved: count)
    }

    private func sync(image: Ubiquitty.Image.TerminalImage, isFiltered: Bool) {
        guard image.used, image.width > 0, image.height > 0, image.format == 24 || image.format == 32 else { return }
        var source: UnsafePointer<UInt8>? = UnsafePointer(image.pixels)
        var sourceLength = Int(image.pixelLength)
        if image.frameCount > 0, image.currentFrame < image.frameCount {
            let frame = image.frames[Int(image.currentFrame)]
            if frame.used, let pixels = frame.pixels {
                source = UnsafePointer(pixels)
                sourceLength = Int(frame.pixelLength)
            }
        }
        guard let source else { return }
        let width = Int(image.width)
        let height = Int(image.height)
        guard
            let byteCounts = Self.stagingByteCounts(
                width: width,
                height: height,
                format: Int(image.format),
                sourceLength: sourceLength
            )
        else { return }
        // The image-taking form: every field the key folds is read from the
        // image, so this call site cannot leave one out.
        let stamp = Ubiquitty.Image.imageContentStamp(image)
        var entry = entries[image.imageID] ?? Entry()
        entry.isSeenThisSync = true
        defer { entries[image.imageID] = entry }
        // A texture without levels cannot be filtered across them, so the
        // first filtered draw of an image uploaded sharp uploads it again.
        let needsLevels = isFiltered && !entry.isMipmapped
        if entry.texture != nil, entry.stamp == stamp, !needsLevels { return }
        let rgbaByteCount = byteCounts.rgba
        let isMipmapped = entry.isMipmapped || isFiltered
        // The texture OBJECT is made here rather than at upload: the frame's
        // encode binds it while the lock is still held, and a bind of nothing
        // would drop the picture for a frame the model says is there.
        if entry.texture == nil || entry.texture?.width != width || entry.texture?.height != height
            || isMipmapped != entry.isMipmapped
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: isMipmapped
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = device.cpuWrittenTextureStorageMode
            entry.texture = device.makeTexture(descriptor: descriptor)
            entry.isMipmapped = isMipmapped
        }
        guard entry.texture != nil else { return }
        // Copied, not uploaded: `uploadStagedPixels` runs it after the caller
        // drops the model lock and before the frame commits, so the GPU still
        // reads these bytes for this frame.
        if entry.stagedPixels.count != rgbaByteCount {
            entry.stagedPixels = [UInt8](repeating: 0, count: rgbaByteCount)
        }
        if image.format == 32 {
            entry.stagedPixels.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return }
                base.copyMemory(from: source, byteCount: rgbaByteCount)
            }
        } else {
            // RGB24 widens to RGBA8 on the way in, the texture format both
            // protocols' pixels share once uploaded. The destination pointer
            // stays inside the staging array's borrow; no pointer into Swift
            // storage survives the closure that vends it.
            entry.stagedPixels.withUnsafeMutableBufferPointer { destination in
                Ubiquitty.Image.widenToRGBA8(
                    source,
                    Int32(width),
                    Int32(height),
                    Int32(image.format),
                    destination.baseAddress
                )
            }
        }
        entry.stagedWidth = width
        entry.stagedHeight = height
        entry.stamp = stamp
    }

    /// Returns the source and staged byte counts for a model image.
    ///
    /// The model applies the same decoded-image ceiling before storage, but the
    /// renderer rechecks it before allocating a texture or a staging buffer: a
    /// malformed snapshot must be refused rather than turn wrapped arithmetic
    /// into an undersized copy.
    static func stagingByteCounts(
        width: Int,
        height: Int,
        format: Int,
        sourceLength: Int
    ) -> (source: Int, rgba: Int)? {
        guard width > 0, height > 0, format == 24 || format == 32, sourceLength >= 0 else { return nil }
        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow else { return nil }
        let sourceBytesPerPixel = format == 32 ? 4 : 3
        let (sourceByteCount, sourceByteCountOverflow) = pixelCount.multipliedReportingOverflow(by: sourceBytesPerPixel)
        let (rgbaByteCount, rgbaByteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !sourceByteCountOverflow, !rgbaByteCountOverflow,
            sourceByteCount <= sourceLength,
            sourceByteCount <= Int(Ubiquitty.Image.maxDecodedImageBytes)
        else {
            return nil
        }
        return (sourceByteCount, rgbaByteCount)
    }

    /// How many image uploads this store has run off the model lock.
    ///
    /// The staging is a cost decision — the frame draws the same picture
    /// whether the transfer happens under the lock or after it — so the only
    /// observable difference is where the work is done, and a count of the
    /// work done here is what says so. A caller outside the frame can never
    /// catch a pending upload: the frame stages and uploads within one call.
    package private(set) var offLockUploadCount = 0

    /// Uploads every staged image, off the model lock.
    ///
    /// Called after the caller releases the lock and before it commits the
    /// frame: a CPU `replace` before the commit is what the GPU reads when the
    /// frame executes, so the picture is whole without the parser having
    /// waited for the bytes to move.
    package func uploadStagedPixels() {
        for (imageID, entry) in entries where !entry.stagedPixels.isEmpty {
            if let texture = entry.texture {
                if entry.isMipmapped {
                    Self.uploadLevels(entry.stagedPixels, width: entry.stagedWidth, height: entry.stagedHeight, into: texture)
                } else {
                    entry.stagedPixels.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, entry.stagedWidth, entry.stagedHeight),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: entry.stagedWidth * 4
                        )
                    }
                }
            }
            var uploaded = entry
            uploaded.stagedPixels.removeAll(keepingCapacity: true)
            entries[imageID] = uploaded
            offLockUploadCount += 1
        }
    }

    /// Uploads level zero and every level below it, each halved from the one
    /// above by Core's rule after the transparent texels take the edge's
    /// colour, so filtering across the picture's edge shows no dark fringe.
    ///
    /// - Parameters:
    ///   - pixels: Level zero, four bytes a texel, straight alpha.
    ///   - width: Its width.
    ///   - height: Its height.
    ///   - texture: The mipmapped texture to fill.
    private static func uploadLevels(_ pixels: [UInt8], width: Int, height: Int, into texture: MTLTexture) {
        var width = width
        var height = height
        var level = pixels
        level.withUnsafeMutableBufferPointer { texels in
            Ubiquitty.Image.bleedIntoTransparentTexels(texels.baseAddress, Int32(width), Int32(height))
        }
        for mipmapLevel in 0..<texture.mipmapLevelCount {
            level.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: mipmapLevel,
                    withBytes: base,
                    bytesPerRow: width * 4
                )
            }
            guard mipmapLevel + 1 < texture.mipmapLevelCount else { break }
            let nextWidth = max(1, width / 2)
            let nextHeight = max(1, height / 2)
            var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
            level.withUnsafeBufferPointer { source in
                next.withUnsafeMutableBufferPointer { destination in
                    Ubiquitty.Image.downsampleImageMipLevel(source.baseAddress, Int32(width), Int32(height), destination.baseAddress)
                    Ubiquitty.Image.bleedIntoTransparentTexels(destination.baseAddress, Int32(nextWidth), Int32(nextHeight))
                }
            }
            level = next
            width = nextWidth
            height = nextHeight
        }
    }

    /// Resolves the frame's image layer, under the model lock.
    ///
    /// - Parameters:
    ///   - terminal: The model, read under its lock.
    ///   - cellSizeInPixels: One cell's device-pixel size.
    ///   - origin: The grid's top-left in the drawable.
    ///   - scale: Points to device pixels.
    ///   - presentationScale: Uniform local scaling of cells and intrinsic image pixels.
    ///   - viewOffset: Scrollback rows above the live tail.
    ///   - drawableSizeInPixels: The drawable, for the fullscreen fits.
    ///   - isHoldingForResize: Whether a live resize is in progress, where an
    ///     image application's per-frame delete-and-replace shows as a
    ///     momentary zero that must not blank the picture.
    /// - Returns: The layer to draw, or nil when the frame carries no image.
    package func layer(
        for terminal: Ubiquitty.Terminal,
        cellSizeInPixels: Ubiquitty.FloatSize,
        origin: Ubiquitty.FloatPoint,
        scale: Float,
        presentationScale: Float = 1,
        viewOffset: Int32,
        drawableSizeInPixels: Ubiquitty.FloatSize,
        isHoldingForResize: Bool
    ) -> ImageLayer? {
        // What an empty layer means is Core's rule: a frame that could not
        // resolve carries the previous layer across the gap, and a frame that
        // resolved to nothing draws nothing, because every placement clipped
        // out of the viewport. The frame is described here, decided there.
        var frame = Ubiquitty.Rendering.ImageLayerFrame()
        frame.hasPlacements = Ubiquitty.Rendering.hasImagePlacements(terminal, viewOffset)
        frame.isHoldingForResize = isHoldingForResize
        frame.hasCarriedLayer = carriedCount > 0
        let hasCell = cellSizeInPixels.width > 0 && cellSizeInPixels.height > 0

        // Resolved before the textures are brought up to the model, because
        // which images the frame filters decides which textures carry levels.
        var resolved = 0
        if frame.hasPlacements, hasCell {
            resolved = quadScratch.withUnsafeMutableBufferPointer { scratch in
                Int(
                    Ubiquitty.Rendering.collectImageQuadsOrdered(
                        terminal,
                        cellSizeInPixels,
                        origin,
                        scale,
                        viewOffset,
                        Ubiquitty.Rendering.ImageQuadSpan(scratch),
                        drawableSizeInPixels,
                        presentationScale
                    )
                )
            }
        }
        sync(from: terminal, filteredImages: filteredImages(count: resolved))
        frame.canResolve = hasCell && !entries.isEmpty
        if frame.hasPlacements, frame.canResolve {
            frame.resolvedPlacements = Int32(resolved)
            return resolvedLayer(frame: frame, resolved: resolved)
        }
        return resolvedLayer(frame: frame, resolved: 0)
    }

    private func resolvedLayer(frame: Ubiquitty.Rendering.ImageLayerFrame, resolved: Int) -> ImageLayer? {
        var frame = frame
        var written = 0
        var split = 0
        if resolved > 0, quads.ensure(resolved),
            let destination = quads.elements(as: Ubiquitty.Rendering.ImageInstance.self)
        {
            textures.removeAll(keepingCapacity: true)
            isFiltered.removeAll(keepingCapacity: true)
            for index in 0..<resolved {
                let quad = quadScratch[index]
                guard let texture = entries[quad.imageID]?.texture else { continue }
                var instance = Ubiquitty.Rendering.ImageInstance()
                instance.topLeftInPixels = Ubiquitty.Rendering.Vec2(x: quad.minXInPixels, y: quad.minYInPixels)
                instance.bottomRightInPixels = Ubiquitty.Rendering.Vec2(x: quad.maxXInPixels, y: quad.maxYInPixels)
                instance.uv0 = Ubiquitty.Rendering.Vec2(x: quad.u0, y: quad.v0)
                instance.uv1 = Ubiquitty.Rendering.Vec2(x: quad.u1, y: quad.v1)
                destination[written] = instance
                textures.append(texture)
                isFiltered.append(quad.filter == .Smooth)
                // The order is Core's: the under-text band first, so the
                // split is the count of negative-z placements.
                if quad.zIndex < 0 { split = written + 1 }
                written += 1
            }
        }
        frame.drawableQuads = Int32(written)
        switch Ubiquitty.Rendering.imageLayerAction(frame) {
        case .UseResolved:
            // The layer to carry if a later frame cannot resolve: copied, so the
            // next resolve's writes to `quads` leave it whole.
            if carriedQuads.ensure(written),
                let source = quads.elements(as: Ubiquitty.Rendering.ImageInstance.self),
                let kept = carriedQuads.elements(as: Ubiquitty.Rendering.ImageInstance.self)
            {
                kept.update(from: source, count: written)
                carriedTextures = textures
                carriedIsFiltered = isFiltered
                carriedSplit = split
                carriedCount = written
            }
            return ImageLayer(buffer: quads.buffer, textures: textures, isFiltered: isFiltered, split: split)
        case .CarryPrevious:
            return ImageLayer(buffer: carriedQuads.buffer, textures: carriedTextures, isFiltered: carriedIsFiltered, split: carriedSplit)
        case .DrawNothing:
            carriedTextures.removeAll(keepingCapacity: true)
            carriedIsFiltered.removeAll(keepingCapacity: true)
            carriedSplit = 0
            carriedCount = 0
            return nil
        @unknown default:
            return nil
        }
    }
}
