// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/VulkanColorGlyphAtlas.h"
#include "Core/Rendering/CellDecisions.h"
#include "Core/Rendering/SizedMaster.h"

#include "Platform/Linux/VulkanMemory.h"

#include <algorithm>
#include <cstring>
#include <span>

namespace Ubiquitty::Linux {

namespace {

// The same grid SoftwareRenderer's colour atlas uses, from the one derivation
// both ask. The two must agree slot for slot: a caller comparing the CPU raster
// against the GPU one is comparing renderers, and a different slot grid makes
// every pixel of the difference real and none of it about the renderer under
// test. Two spellings of one number drift apart, so neither arm spells it.
//
// The limit passed is the shared floor rather than this device's: a sheet cut
// to a limit the CPU one cannot know puts the two on different grids on exactly
// the devices that allow more.
Rendering::AtlasGridFit colorGrid(int slotInPixels)
{
    return Rendering::colourGlyphAtlasGrid(slotInPixels, Rendering::sharedColourAtlasTextureLimit);
}

} // namespace

VulkanColorGlyphAtlas::VulkanColorGlyphAtlas(Rendering::GlyphRasterizer& rasterizer, int cellHeightInPixels)
    : m_rasterizer(rasterizer)
    , m_hasColorSource(rasterizer.hasColorGlyphs())
    // A rasterizer with no colour source still gets a sheet, sized to one pixel.
    // The descriptor set binds this image unconditionally, and a null image view
    // in a bound descriptor is undefined behaviour rather than a quiet no-op —
    // so the absence of colour lives in `m_hasColorSource` and in whether the
    // backend hooks are filled, never in whether the image exists.
    , m_slotInPixels(m_hasColorSource && cellHeightInPixels > 0 ? cellHeightInPixels : 1)
    , m_columns(m_hasColorSource ? colorGrid(m_slotInPixels).columns : 1)
    , m_capacity(m_hasColorSource ? colorGrid(m_slotInPixels).columns * colorGrid(m_slotInPixels).rows : 1)
    // Twice the capacity, as every other cache here is bucketed.
    , m_cache(m_capacity, m_capacity * 2, m_columns)
{
    m_rows = m_columns > 0 ? m_capacity / m_columns : 1;
    if (m_rows <= 0)
        m_rows = 1;
    m_atlasWidth = m_columns * m_slotInPixels;
    m_atlasHeight = m_rows * m_slotInPixels;
    m_pixels.assign(static_cast<std::size_t>(m_atlasWidth) * m_atlasHeight * 4, 0);
    m_slotScratch.assign(static_cast<std::size_t>(m_slotInPixels) * m_slotInPixels * 4, 0);
}

bool VulkanColorGlyphAtlas::create(VkDevice device, VkPhysicalDevice physical)
{
    VkImageCreateInfo imageInfo {};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    // RGBA rather than the mono sheet's R8. An emoji carries its own layers, so
    // there is nothing to reconstruct from a single channel.
    imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
    imageInfo.extent = { static_cast<uint32_t>(m_atlasWidth), static_cast<uint32_t>(m_atlasHeight), 1 };
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    // TRANSFER_SRC is not used by the render path. It is what makes the sheet
    // readable back, and this sheet has no other check: the CPU renderer has no
    // colour atlas, so the CPU/GPU oracle that covers the mono path cannot see
    // an emoji at all. A wrong band offset here would land one emoji's pixels
    // in another's slot and draw a different face, with nothing to report it.
    imageInfo.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(device, &imageInfo, nullptr, &m_image) != VK_SUCCESS)
        return false;

    VkMemoryRequirements imageRequirements {};
    vkGetImageMemoryRequirements(device, m_image, &imageRequirements);
    VkMemoryAllocateInfo imageAlloc {};
    imageAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    imageAlloc.allocationSize = imageRequirements.size;
    imageAlloc.memoryTypeIndex = findVulkanMemoryType(physical, imageRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (imageAlloc.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(device, &imageAlloc, nullptr, &m_imageMemory) != VK_SUCCESS)
        return false;
    if (vkBindImageMemory(device, m_image, m_imageMemory, 0) != VK_SUCCESS)
        return false;

    VkImageViewCreateInfo viewInfo {};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = m_image;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.layerCount = 1;
    if (vkCreateImageView(device, &viewInfo, nullptr, &m_view) != VK_SUCCESS)
        return false;

    // Nearest, like the mono sheet and like the CPU compositor's tap, so the
    // three software arms agree with each other on any scale.
    //
    // Not because linear would leak. The reason given here was that a bilinear
    // tap blends across the half-texel inset into the neighbouring slot, and
    // GlyphBackendTypes.h adds that inset saying it stops exactly that — one of
    // the two had to be wrong. Measured in
    // testAColourSlotEdgeTapCannotShowTheNeighbour: the inset puts the extreme
    // sample on a texel centre, and the largest weight a neighbour receives
    // across the slots tried is 4e-9, which no 8-bit channel can show.
    VkSamplerCreateInfo samplerInfo {};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_NEAREST;
    samplerInfo.minFilter = VK_FILTER_NEAREST;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    if (vkCreateSampler(device, &samplerInfo, nullptr, &m_sampler) != VK_SUCCESS)
        return false;

    m_stagingSize = static_cast<VkDeviceSize>(m_atlasWidth) * m_atlasHeight * 4;
    VkBufferCreateInfo bufferInfo {};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = m_stagingSize;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(device, &bufferInfo, nullptr, &m_staging) != VK_SUCCESS)
        return false;
    VkMemoryRequirements bufferRequirements {};
    vkGetBufferMemoryRequirements(device, m_staging, &bufferRequirements);
    VkMemoryAllocateInfo bufferAlloc {};
    bufferAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bufferAlloc.allocationSize = bufferRequirements.size;
    bufferAlloc.memoryTypeIndex = findVulkanMemoryType(physical, bufferRequirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (bufferAlloc.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(device, &bufferAlloc, nullptr, &m_stagingMemory) != VK_SUCCESS)
        return false;
    return vkBindBufferMemory(device, m_staging, m_stagingMemory, 0) == VK_SUCCESS;
}

void VulkanColorGlyphAtlas::destroy(VkDevice device)
{
    if (m_sampler) {
        vkDestroySampler(device, m_sampler, nullptr);
        m_sampler = VK_NULL_HANDLE;
    }
    if (m_view) {
        vkDestroyImageView(device, m_view, nullptr);
        m_view = VK_NULL_HANDLE;
    }
    if (m_image) {
        vkDestroyImage(device, m_image, nullptr);
        m_image = VK_NULL_HANDLE;
    }
    if (m_imageMemory) {
        vkFreeMemory(device, m_imageMemory, nullptr);
        m_imageMemory = VK_NULL_HANDLE;
    }
    if (m_staging) {
        vkDestroyBuffer(device, m_staging, nullptr);
        m_staging = VK_NULL_HANDLE;
    }
    if (m_stagingMemory) {
        vkFreeMemory(device, m_stagingMemory, nullptr);
        m_stagingMemory = VK_NULL_HANDLE;
    }
    m_isImageInitialized = false;
    m_hasPendingUpload = false;
    // The image is gone; whatever the mirror holds is ahead of what does not
    // exist, so the next upload sends all of it.
    m_firstDirtySlot = 0;
    m_lastDirtySlot = INT_MAX;
}

Rendering::ColorAtlasBinding VulkanColorGlyphAtlas::bindColorAtlas()
{
    return { &m_cache, m_columns, m_rows, m_slotInPixels, m_capacity };
}

void VulkanColorGlyphAtlas::clearSlot(int slot)
{
    if (slot < 0 || slot >= m_capacity)
        return;
    const int x0 = (slot % m_columns) * m_slotInPixels;
    const int y0 = (slot / m_columns) * m_slotInPixels;
    for (int y = 0; y < m_slotInPixels; ++y) {
        std::uint8_t* destination = &m_pixels[(static_cast<std::size_t>(y0 + y) * m_atlasWidth + x0) * 4];
        std::memset(destination, 0, static_cast<std::size_t>(m_slotInPixels) * 4);
    }
    markSlotDirty(slot);
}

bool VulkanColorGlyphAtlas::rasteriseColorGlyph(const std::uint32_t* codePoints, int count, int slot)
{
    // A slot outside the sheet cannot be written at all, so there is nothing to
    // define and writing would run past the pixels. The one refusal in this
    // file, and the only one Core must forget the key for.
    if (slot < 0 || slot >= m_capacity)
        return false;
    // Everything else here names a slot this sheet owns. Returning without
    // touching it leaves the previous tenant's pixels under this key — the same
    // hazard the decline path below clears for, reached by a different door.
    if (!m_hasColorSource || !codePoints || count <= 0) {
        clearSlot(slot);
        return true;
    }

    if (!m_rasterizer.rasterizeColorCluster(codePoints, count, m_slotInPixels, m_slotScratch.data())) {
        // The cache has already handed this key its slot, so leaving the pixels
        // alone shows the previous tenant — somebody else's emoji under this
        // cluster's key, for as long as the slot lives.
        clearSlot(slot);
        return true;
    }

    const int x0 = (slot % m_columns) * m_slotInPixels;
    const int y0 = (slot / m_columns) * m_slotInPixels;
    for (int y = 0; y < m_slotInPixels; ++y) {
        const std::uint8_t* source = &m_slotScratch[static_cast<std::size_t>(y) * m_slotInPixels * 4];
        std::uint8_t* destination = &m_pixels[(static_cast<std::size_t>(y0 + y) * m_atlasWidth + x0) * 4];
        std::memcpy(destination, source, static_cast<std::size_t>(m_slotInPixels) * 4);
    }
    markSlotDirty(slot);
    return true;
}

Rendering::AtlasGlyph VulkanColorGlyphAtlas::sizedColorGlyph(std::span<const std::uint32_t> codePoints, Rendering::SizedTile tile)
{
    if (!m_hasColorSource || codePoints.empty() || !(tile.scale >= 2 || tile.isFractional()))
        return {};
    const Rendering::SizedColorTileContents contents = Rendering::sizedColorTileContents(codePoints, tile);
    if (contents.count == 0)
        return {};
    bool isFresh = false;
    const int slot = m_cache.slotForKeyVerified(contents.key, contents.words.data(), contents.count, &isFresh);
    if (slot < 0)
        return {};
    if (isFresh) {
        const std::size_t rowBytes = static_cast<std::size_t>(m_slotInPixels) * 4;
        const std::span<std::uint8_t> window = std::span(m_slotScratch).first(rowBytes * static_cast<std::size_t>(m_slotInPixels));
        if (!Rendering::rasteriseSizedColorWindow(m_rasterizer, codePoints, tile, m_slotInPixels, m_sizedScratch, window)) {
            m_cache.forgetKey(contents.key);
            return {};
        }
        const int x0 = (slot % m_columns) * m_slotInPixels;
        const int y0 = (slot / m_columns) * m_slotInPixels;
        for (int y = 0; y < m_slotInPixels; ++y) {
            const std::span<const std::uint8_t> row = window.subspan(static_cast<std::size_t>(y) * rowBytes, rowBytes);
            std::ranges::copy(row, m_pixels.begin() + static_cast<std::ptrdiff_t>((static_cast<std::size_t>(y0 + y) * static_cast<std::size_t>(m_atlasWidth) + static_cast<std::size_t>(x0)) * 4));
        }
        markSlotDirty(slot);
    }
    const Rendering::GlyphUV uv = bindColorAtlas().atlasRectForSlot(slot);
    return { { uv.minU, uv.minV }, { uv.maxU, uv.maxV }, true };
}

void VulkanColorGlyphAtlas::markSlotDirty(int slot)
{
    if (slot < 0)
        return;
    if (slot < m_firstDirtySlot)
        m_firstDirtySlot = slot;
    if (m_lastDirtySlot == INT_MAX || slot > m_lastDirtySlot)
        m_lastDirtySlot = slot;
}

bool VulkanColorGlyphAtlas::upload(VkDevice device, VkQueue queue, VkCommandPool commandPool)
{
    if (m_lastDirtySlot < m_firstDirtySlot && m_isImageInitialized)
        return true;
    VkCommandBufferAllocateInfo allocateInfo {};
    allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocateInfo.commandPool = commandPool;
    allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocateInfo.commandBufferCount = 1;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(device, &allocateInfo, &commandBuffer) != VK_SUCCESS)
        return false;
    VkCommandBufferBeginInfo beginInfo {};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    bool didComplete = false;
    if (vkBeginCommandBuffer(commandBuffer, &beginInfo) == VK_SUCCESS
        && recordUpload(device, commandBuffer)
        && vkEndCommandBuffer(commandBuffer) == VK_SUCCESS) {
        VkSubmitInfo submit {};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffer;
        didComplete = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS
            && vkQueueWaitIdle(queue) == VK_SUCCESS;
    }
    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    if (didComplete)
        didUpload();
    return didComplete;
}

void VulkanColorGlyphAtlas::didUpload()
{
    if (m_hasPendingUpload) {
        m_isImageInitialized = true;
        m_firstDirtySlot = INT_MAX;
        m_lastDirtySlot = -1;
        m_hasPendingUpload = false;
    }
}

bool VulkanColorGlyphAtlas::recordUpload(VkDevice device, VkCommandBuffer commandBuffer)
{
    m_hasPendingUpload = false;
    if (!m_image || !m_staging)
        return false;
    const bool isDirty = m_lastDirtySlot >= m_firstDirtySlot;
    if (!isDirty && m_isImageInitialized)
        return true;

    // The rows the dirty slots sit in, by the same rule the mono sheet uses.
    // The first upload sends everything: the image is uninitialized, so rows
    // outside any band hold nothing rather than the previous frame.
    int firstRow = 0;
    int rowCount = m_atlasHeight;
    if (m_isImageInitialized && m_lastDirtySlot != INT_MAX) {
        const Rendering::AtlasRowBand band = Rendering::atlasDirtyRowBand(m_firstDirtySlot, m_lastDirtySlot,
            m_columns, m_slotInPixels, m_atlasHeight);
        firstRow = band.firstRow;
        rowCount = band.rowCount;
    }
    if (rowCount <= 0) {
        m_firstDirtySlot = INT_MAX;
        m_lastDirtySlot = -1;
        return true;
    }

    // Four bytes per pixel. Stage the band at offset zero so the mapped offset
    // satisfies the device's alignment independently of the selected row.
    const VkDeviceSize rowStride = static_cast<VkDeviceSize>(m_atlasWidth) * 4;
    const VkDeviceSize byteOffset = rowStride * static_cast<VkDeviceSize>(firstRow);
    const VkDeviceSize byteCount = rowStride * static_cast<VkDeviceSize>(rowCount);

    void* mapped = nullptr;
    if (vkMapMemory(device, m_stagingMemory, 0, byteCount, 0, &mapped) != VK_SUCCESS)
        return false;
    std::memcpy(mapped, m_pixels.data() + byteOffset, static_cast<std::size_t>(byteCount));
    vkUnmapMemory(device, m_stagingMemory);

    VkImageSubresourceRange range {};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    auto barrier = [&](VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess, VkAccessFlags dstAccess, VkPipelineStageFlags srcStage, VkPipelineStageFlags dstStage) {
        VkImageMemoryBarrier memoryBarrier {};
        memoryBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        memoryBarrier.oldLayout = from;
        memoryBarrier.newLayout = to;
        memoryBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        memoryBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        memoryBarrier.image = m_image;
        memoryBarrier.subresourceRange = range;
        memoryBarrier.srcAccessMask = srcAccess;
        memoryBarrier.dstAccessMask = dstAccess;
        vkCmdPipelineBarrier(commandBuffer, srcStage, dstStage, 0, 0, nullptr, 0, nullptr, 1, &memoryBarrier);
    };

    const VkImageLayout from = m_isImageInitialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
    barrier(from, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, m_isImageInitialized ? VK_ACCESS_SHADER_READ_BIT : 0, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);

    VkBufferImageCopy region {};
    region.bufferOffset = 0;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageOffset = { 0, firstRow, 0 };
    region.imageExtent = { static_cast<uint32_t>(m_atlasWidth), static_cast<uint32_t>(rowCount), 1 };
    vkCmdCopyBufferToImage(commandBuffer, m_staging, m_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    barrier(VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

    m_hasPendingUpload = true;
    return true;
}

} // namespace Ubiquitty::Linux
