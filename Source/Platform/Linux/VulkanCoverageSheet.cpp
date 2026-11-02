// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/VulkanCoverageSheet.h"

#include "Platform/Linux/VulkanMemory.h"

#include <cstring>

namespace Ubiquitty::Linux {

bool VulkanCoverageSheet::create(VkDevice device, VkPhysicalDevice physical, int widthInPixels, int heightInPixels)
{
    if (widthInPixels <= 0 || heightInPixels <= 0)
        return false; // a degenerate extent is refused here rather than by the driver
    m_widthInPixels = widthInPixels;
    m_heightInPixels = heightInPixels;

    VkImageCreateInfo imageInfo {};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.format = VK_FORMAT_R8_UNORM;
    imageInfo.extent = { static_cast<uint32_t>(widthInPixels), static_cast<uint32_t>(heightInPixels), 1 };
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    // TRANSFER_SRC is not used by the render path. It is what makes the sheet
    // readable back, and the upload writes sub-regions whose offsets are the
    // one thing here that can be wrong without failing: a bad offset lands a
    // glyph's coverage in a neighbouring slot, which draws as the wrong
    // character rather than as an error. Reading the image back and comparing
    // it to the mirror is what catches that, and it needs this bit.
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
    viewInfo.format = VK_FORMAT_R8_UNORM;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.layerCount = 1;
    if (vkCreateImageView(device, &viewInfo, nullptr, &m_view) != VK_SUCCESS)
        return false;

    // Nearest + clamp-to-edge. Inert for the two passes that read coverage with
    // texelFetch; it is decoration.frag's texture() sample that this decides.
    // See the header — no test here detects a change to it.
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

    m_stagingSize = static_cast<VkDeviceSize>(widthInPixels) * static_cast<VkDeviceSize>(heightInPixels);
    VkBufferCreateInfo bufferInfo {};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = m_stagingSize;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(device, &bufferInfo, nullptr, &m_staging) != VK_SUCCESS)
        return false;

    VkMemoryRequirements stagingRequirements {};
    vkGetBufferMemoryRequirements(device, m_staging, &stagingRequirements);
    VkMemoryAllocateInfo stagingAlloc {};
    stagingAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    stagingAlloc.allocationSize = stagingRequirements.size;
    stagingAlloc.memoryTypeIndex = findVulkanMemoryType(physical, stagingRequirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (stagingAlloc.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(device, &stagingAlloc, nullptr, &m_stagingMemory) != VK_SUCCESS)
        return false;
    return vkBindBufferMemory(device, m_staging, m_stagingMemory, 0) == VK_SUCCESS;
}

void VulkanCoverageSheet::destroy(VkDevice device)
{
    if (m_staging) {
        vkDestroyBuffer(device, m_staging, nullptr);
        m_staging = VK_NULL_HANDLE;
    }
    if (m_stagingMemory) {
        vkFreeMemory(device, m_stagingMemory, nullptr);
        m_stagingMemory = VK_NULL_HANDLE;
    }
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
    m_isImageInitialized = false;
    m_hasPendingUpload = false;
}

bool VulkanCoverageSheet::upload(VkDevice device, VkQueue queue, VkCommandPool commandPool, std::span<const std::uint8_t> mirror)
{
    return upload(device, queue, commandPool, mirror, 0, m_heightInPixels);
}

bool VulkanCoverageSheet::upload(VkDevice device, VkQueue queue, VkCommandPool commandPool, std::span<const std::uint8_t> mirror,
    int firstRow, int rowCount)
{
    if (!m_image || !m_staging)
        return false;
    if (rowCount <= 0)
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
        && recordUpload(device, commandBuffer, mirror, firstRow, rowCount)
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

void VulkanCoverageSheet::didUpload()
{
    if (m_hasPendingUpload) {
        m_isImageInitialized = true;
        m_hasPendingUpload = false;
    }
}

bool VulkanCoverageSheet::recordUpload(VkDevice device, VkCommandBuffer commandBuffer, std::span<const std::uint8_t> mirror,
    int firstRow, int rowCount)
{
    m_hasPendingUpload = false;
    if (!m_image || !m_staging)
        return false;
    // An empty range is a caller saying nothing changed, which is not a failure.
    if (rowCount <= 0)
        return true;
    // Refused rather than clamped, like the mirror size below: a range past the
    // sheet means the caller computed it wrong, and copying the part that fits
    // leaves the rest showing the previous glyph.
    if (firstRow < 0 || firstRow > m_heightInPixels || rowCount > m_heightInPixels - firstRow)
        return false;
    // Refused rather than clamped: a mirror of another size would either read
    // past its own storage or leave part of the sheet holding an older frame,
    // and both look like a rendering bug rather than a size mismatch.
    if (mirror.size() != static_cast<std::size_t>(m_stagingSize))
        return false;

    // Stage the band at offset zero. `vkMapMemory` requires an aligned offset,
    // while a row stride is not generally aligned; the image destination still
    // carries `firstRow`, so no full-sheet copy is needed.
    const VkDeviceSize rowStride = static_cast<VkDeviceSize>(m_widthInPixels);
    const VkDeviceSize byteOffset = rowStride * static_cast<VkDeviceSize>(firstRow);
    const VkDeviceSize byteCount = rowStride * static_cast<VkDeviceSize>(rowCount);

    void* mapped = nullptr;
    if (vkMapMemory(device, m_stagingMemory, 0, byteCount, 0, &mapped) != VK_SUCCESS)
        return false;
    std::memcpy(mapped, mirror.data() + byteOffset, static_cast<std::size_t>(byteCount));
    vkUnmapMemory(device, m_stagingMemory);

    VkImageSubresourceRange range {};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    auto barrier = [&](VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess, VkAccessFlags dstAccess,
                       VkPipelineStageFlags srcStage, VkPipelineStageFlags dstStage) {
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
    barrier(from, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, m_isImageInitialized ? VK_ACCESS_SHADER_READ_BIT : 0,
        VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT);

    VkBufferImageCopy region {};
    region.bufferOffset = 0;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageOffset = { 0, firstRow, 0 };
    region.imageExtent = { static_cast<uint32_t>(m_widthInPixels), static_cast<uint32_t>(rowCount), 1 };
    vkCmdCopyBufferToImage(commandBuffer, m_staging, m_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    barrier(VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

    m_hasPendingUpload = true;
    return true;
}

} // namespace Ubiquitty::Linux
