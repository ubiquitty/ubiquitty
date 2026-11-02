// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// Source/Platform/Linux/VulkanColorGlyphAtlas.h — the emoji sheet, as a texture.
//
// Separate from `VulkanGlyphAtlas` rather than a second image inside it. That
// class is a single R8 coverage sheet everywhere: its format, its staging size
// and its slot arithmetic all assume one byte per pixel, and threading a second
// bytes-per-pixel through every one of them would leave a class whose invariant
// is "one of two things" — the shape that silently writes a quarter of a colour
// glyph rather than failing to compile.
//
// The layout mirrors `SoftwareRenderer`'s colour atlas exactly, because the two
// must agree slot for slot: a caller comparing the CPU raster against this one
// is comparing renderers, and a different slot grid would make every pixel of
// the difference real and none of it about the renderer.
//

#include "Core/Rendering/GlyphBackendTypes.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Core/Rendering/GlyphSlotCache.h"

#include <climits>
#include <cstdint>
#include <span>
#include <vector>
#include <vulkan/vulkan.h>

namespace Ubiquitty::Linux {

/// An RGBA sheet of colour glyphs, uploaded as a sampled Vulkan image.
class VulkanColorGlyphAtlas {
public:
    /// Creates the sheet over a rasterizer's colour source.
    ///
    /// A rasterizer with no colour source still gets an object, sized to one
    /// pixel: the descriptor set binds this image unconditionally, so something
    /// must exist to bind. Whether colour is available is answered by
    /// `hasColorSource`, never by whether the image is there — a null texture
    /// in a bound descriptor is undefined behaviour, and a one-pixel sheet
    /// nobody samples costs four bytes.
    ///
    /// - Parameters:
    ///   - rasterizer: Draws the clusters. The caller owns it and it must
    ///     outlive this.
    ///   - cellHeightInPixels: The slot edge. Square, and the cell HEIGHT on
    ///     both axes — an emoji is as tall as the line and spans two columns,
    ///     so sizing to the width would crop it.
    VulkanColorGlyphAtlas(Rendering::GlyphRasterizer& rasterizer, int cellHeightInPixels);

    /// Whether the rasterizer offered a colour source when this was built.
    ///
    /// - Returns: True when colour glyphs can be rasterised at all.
    [[nodiscard]] bool hasColorSource() const { return m_hasColorSource; }

    /// Creates the image, view, sampler and staging buffer.
    ///
    /// - Parameters:
    ///   - device: The logical device the objects belong to.
    ///   - physical: The device whose memory types back them.
    /// - Returns: False when any Vulkan object could not be created.
    bool create(VkDevice device, VkPhysicalDevice physical);

    /// Destroys everything `create` made.
    ///
    /// - Parameter device: The device the objects were created on.
    void destroy(VkDevice device);

    /// Copies the host mirror into the image when a slot has changed.
    ///
    /// - Parameters:
    ///   - device: The device holding the image and staging buffer.
    ///   - queue: The queue the copy is submitted on.
    ///   - commandPool: Allocates the one-shot command buffer.
    /// - Returns: False when the upload could not be submitted.
    bool upload(VkDevice device, VkQueue queue, VkCommandPool commandPool);

    /// Stages changed slots and records their copy beside the frame's draw.
    /// The previous upload must have completed. Keep this atlas unchanged until
    /// the command buffer completes, then call `didUpload`.
    [[nodiscard]] bool recordUpload(VkDevice device, VkCommandBuffer commandBuffer);

    /// Commits the dirty range and image layout after successful completion.
    void didUpload();

    [[nodiscard]] VkImageView view() const { return m_view; }

    /// The image, for a caller reading it back to check what an upload wrote.
    ///
    /// Exposed for that one purpose. The render path binds the view; this is
    /// what a case uses to compare the sheet against its mirror, which is the
    /// only check this sheet has.
    [[nodiscard]] VkImage imageForReadback() const { return m_image; }

    /// The host mirror, for a caller checking the image against it.
    [[nodiscard]] std::span<const std::uint8_t> mirrorForReadback() const { return m_pixels; }

    /// The sheet's pixel extent, for sizing a readback.
    [[nodiscard]] int widthForReadback() const { return m_atlasWidth; }
    /// The sheet's pixel height, for sizing a readback.
    [[nodiscard]] int heightForReadback() const { return m_atlasHeight; }
    /// One slot's edge in pixels, so a case can name a band.
    [[nodiscard]] int slotEdgeForReadback() const { return m_slotInPixels; }
    [[nodiscard]] VkSampler sampler() const { return m_sampler; }

    /// The slot grid, for the builder to probe without crossing the seam.
    ///
    /// - Returns: The cache and the grid it indexes.
    [[nodiscard]] Rendering::ColorAtlasBinding bindColorAtlas();

    /// Pins every colour slot used by the frame against eviction.
    void beginFrame() { m_cache.beginFrame(); }

    /// Rasterises a cluster into a slot the cache has already assigned.
    ///
    /// A slot the rasterizer declines is cleared rather than left alone: the
    /// cache has already given the key away, so the previous tenant's pixels
    /// would show through as somebody else's emoji.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster.
    ///   - count: How many code points.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether this slot's contents are now this cluster's. False
    ///   only for the argument guard, which returns before any write and leaves
    ///   the previous tenant in place; a declined cluster is cleared, so its
    ///   contents are defined and this key owns them.
    bool rasteriseColorGlyph(const std::uint32_t* codePoints, int count, int slot);

    /// Returns one colour-square window of a cluster drawn at a sized block's size.
    ///
    /// Backs ``Rendering::GlyphBackend::sizedColorGlyph`` with Core's sized
    /// colour master and key, the window `SoftwareRenderer::sizedColorGlyph`
    /// cuts, so the CPU and GPU sheets hold the same bytes.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - tile: The block's scale and the window's band and column.
    /// - Returns: The window's rect, or absent when full or declined.
    Rendering::AtlasGlyph sizedColorGlyph(std::span<const std::uint32_t> codePoints, Rendering::SizedTile tile);

private:
    /// Writes a slot's worth of transparent pixels.
    ///
    /// - Parameter slot: The slot to clear.
    void clearSlot(int slot);

    Rendering::GlyphRasterizer& m_rasterizer;
    bool m_hasColorSource = false;
    /// Widens the dirty range to include this slot.
    ///
    /// Called wherever the mirror is written: a write the range does not cover
    /// is a glyph the device never receives, and the slot then draws whichever
    /// emoji occupied it before.
    ///
    /// - Parameter slot: The slot just written. A negative slot widens nothing.
    void markSlotDirty(int slot);

    // The slots whose mirror is ahead of the image, inclusive. Four bytes per
    // pixel here against one on the mono sheet, so the band this spares is the
    // largest of the three sheets.
    //
    // Starts covering everything: the image is uninitialized until the first
    // upload, and a mirror never sent is entirely ahead of it.
    int m_firstDirtySlot = 0;
    int m_lastDirtySlot = INT_MAX;
    int m_slotInPixels = 1;
    int m_columns = 1;
    int m_rows = 1;
    int m_capacity = 1;
    int m_atlasWidth = 1;
    int m_atlasHeight = 1;
    Rendering::GlyphSlotCache m_cache;
    std::vector<std::uint8_t> m_pixels; // RGBA host mirror, atlasWidth*atlasHeight*4
    std::vector<std::uint8_t> m_slotScratch; // one slot, RGBA, reused per glyph
    std::vector<std::uint8_t> m_sizedScratch; // a sized cluster's master, RGBA, reused per window

    bool m_isImageInitialized = false;
    bool m_hasPendingUpload = false;

    VkImage m_image = VK_NULL_HANDLE;
    VkDeviceMemory m_imageMemory = VK_NULL_HANDLE;
    VkImageView m_view = VK_NULL_HANDLE;
    VkSampler m_sampler = VK_NULL_HANDLE;
    VkBuffer m_staging = VK_NULL_HANDLE;
    VkDeviceMemory m_stagingMemory = VK_NULL_HANDLE;
    VkDeviceSize m_stagingSize = 0;
};

} // namespace Ubiquitty::Linux
