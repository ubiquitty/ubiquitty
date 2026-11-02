// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// MetalSamplers.swift — how each texture the renderer binds is read.
//
// Five sampler states, apart from the pipelines because they answer a different
// question: a pipeline says which shaders run and how their output composites, a
// sampler says how a texture is filtered and what lies outside it. A pass picks
// one of each, and the pairing is not fixed — the glyph and decoration passes
// share the atlas sampler while running different pipelines.
//
// Built once per device rather than per format: nothing here depends on the
// drawable's pixel format, which is why they outlive a format change that
// rebuilds every pipeline.

import Metal

/// The sampler states the renderer binds its textures through.
///
/// Immutable and device-scoped. Every one is non-optional: `makeSamplerState`
/// fails only for a descriptor Metal rejects, and these three are fixed at
/// compile time, so a nil here would mean the device itself is unusable rather
/// than a pass being unavailable.
public final class MetalSamplers {
    /// The glyph atlas and every other clamped sheet.
    ///
    /// Linear, so a glyph scaled between sizes stays smooth, and clamped to zero
    /// so a sample past the slot reads transparent rather than dragging in the
    /// neighbouring glyph's ink.
    public let atlas: MTLSamplerState
    /// The background image when it tiles.
    ///
    /// Repeat addressing is the whole difference from ``atlas`` — the same linear
    /// filtering, wrapping instead of clamping.
    public let repeating: MTLSamplerState
    /// Inline images enlarged by a whole number on both axes.
    ///
    /// Nearest: each texel covers an exact block of pixels, so pixel art and
    /// sixel bands keep their edges. Which quads take it is Core's
    /// `Image::ImageFilter`, the same decision every arm reads.
    public let image: MTLSamplerState
    /// Nearest on both axes, repeating the border texel past the edge; the
    /// bitmap tier's inline images, whose reference (the software renderer)
    /// clamps an out-of-range coordinate to the edge rather than to transparent.
    public let imageEdge: MTLSamplerState
    /// Inline images at every other scale: linear within a level, linear
    /// between the two mip levels that bracket the minification, and the edge
    /// texel repeated past the edge so the picture's border is not blended
    /// with nothing.
    public let imageFiltered: MTLSamplerState

    /// Builds the samplers for a device.
    ///
    /// - Parameter device: The device the states are built for.
    public init?(device: MTLDevice) {
        func sampler(
            _ filter: MTLSamplerMinMagFilter,
            _ addressMode: MTLSamplerAddressMode,
            mipFilter: MTLSamplerMipFilter = .notMipmapped
        ) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.mipFilter = mipFilter
            descriptor.sAddressMode = addressMode
            descriptor.tAddressMode = addressMode
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let atlas = sampler(.linear, .clampToZero),
            let repeating = sampler(.linear, .repeat),
            let image = sampler(.nearest, .clampToZero),
            let imageEdge = sampler(.nearest, .clampToEdge),
            let imageFiltered = sampler(.linear, .clampToEdge, mipFilter: .linear)
        else { return nil }
        self.atlas = atlas
        self.repeating = repeating
        self.image = image
        self.imageEdge = imageEdge
        self.imageFiltered = imageFiltered
    }
}
