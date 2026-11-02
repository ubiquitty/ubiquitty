// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/VulkanImageTextures.cpp — see VulkanImageTextures.h.

#include "Platform/Linux/VulkanImageTextures.h"

#include "Platform/Linux/VulkanMemory.h"

#include "Core/Image/ImagePlacement.h"
#include "Core/Image/TerminalImage.h"

#include <algorithm>
#include <cstring>
#include <vector>

namespace Ubiquitty::Linux {

namespace {
// The Core caps images at maxTerminalImageCount; size the descriptor pool for the
// whole set so every used image can hold a live descriptor at once.
// One texture per terminal image, and the window's background image.
constexpr uint32_t maxTextures = Image::maxTerminalImageCount + 1;
} // namespace

uint32_t VulkanImageTextures::findMemoryType(VkPhysicalDevice physical, uint32_t typeBits, VkMemoryPropertyFlags want) const
{
    return findVulkanMemoryType(physical, typeBits, want);
}

bool VulkanImageTextures::create(VkDevice device, VkPhysicalDevice /*physical*/, VkQueue /*queue*/, uint32_t /*queueFamily*/, VkCommandPool /*commandPool*/, VkDescriptorSetLayout descriptorSetLayout)
{
    m_descriptorSetLayout = descriptorSetLayout;

    VkDescriptorPoolSize poolSize {};
    poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = maxTextures;
    VkDescriptorPoolCreateInfo poolInfo {};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.maxSets = maxTextures;
    poolInfo.poolSizeCount = 1;
    poolInfo.pPoolSizes = &poolSize;
    // Per-texture descriptor sets are freed individually on eviction.
    poolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    if (vkCreateDescriptorPool(device, &poolInfo, nullptr, &m_descriptorPool) != VK_SUCCESS)
        return false;
    return true;
}

void VulkanImageTextures::destroyTexture(VkDevice device, Texture& texture)
{
    if (texture.descriptorSet != VK_NULL_HANDLE) {
        vkFreeDescriptorSets(device, m_descriptorPool, 1, &texture.descriptorSet);
        texture.descriptorSet = VK_NULL_HANDLE;
    }
    if (texture.sampler) {
        vkDestroySampler(device, texture.sampler, nullptr);
        texture.sampler = VK_NULL_HANDLE;
    }
    if (texture.view) {
        vkDestroyImageView(device, texture.view, nullptr);
        texture.view = VK_NULL_HANDLE;
    }
    if (texture.image) {
        vkDestroyImage(device, texture.image, nullptr);
        texture.image = VK_NULL_HANDLE;
    }
    if (texture.imageMemory) {
        vkFreeMemory(device, texture.imageMemory, nullptr);
        texture.imageMemory = VK_NULL_HANDLE;
    }
}

void VulkanImageTextures::destroy(VkDevice device)
{
    for (Texture& texture : m_textures)
        destroyTexture(device, texture);
    m_textures.clear();
    destroyTexture(device, m_backdrop);
    m_backdrop = Texture {};
    m_backdropGeneration = 0;
    if (m_descriptorPool) {
        vkDestroyDescriptorPool(device, m_descriptorPool, nullptr);
        m_descriptorPool = VK_NULL_HANDLE;
    }
    m_descriptorSetLayout = VK_NULL_HANDLE;
}

bool VulkanImageTextures::uploadTexture(VkDevice device, VkPhysicalDevice physical, VkQueue queue, VkCommandPool commandPool, const Ubiquitty::Image::TerminalImage& image, Levels levels, Texture& out)
{
    return uploadPixels(device, physical, queue, commandPool, image.imageID, image.pixels, static_cast<int>(image.width),
        static_cast<int>(image.height), static_cast<int>(image.format), levels, out);
}

bool VulkanImageTextures::uploadPixels(VkDevice device, VkPhysicalDevice physical, VkQueue queue, VkCommandPool commandPool, uint32_t imageID,
    const unsigned char* pixels, int width, int height, int format, Levels levels, Texture& out)
{
    if (width <= 0 || height <= 0 || !pixels)
        return false;

    out.imageID = imageID;
    out.width = width;
    out.height = height;

    // Widen format-24 RGB to opaque RGBA8 (format-32 copies straight through) via
    // the shared Image::widenToRGBA8, so the shader reads RGB + straight alpha
    // exactly as compositeImages reads img->pixels.
    std::vector<std::uint8_t> rgba(static_cast<std::size_t>(width) * height * 4);
    Ubiquitty::Image::widenToRGBA8(pixels, width, height, format, rgba.data());

    // A filtered image's levels, appended after level zero in one staging
    // buffer: bled and halved by Core's rule, the levels the CPU samples.
    const bool isMipmapped = levels == Levels::Chain;
    const int levelCount = isMipmapped ? Ubiquitty::Image::imageMipLevelCount(width, height) : 1;
    std::vector<VkBufferImageCopy> regions;
    regions.reserve(static_cast<std::size_t>(levelCount));
    {
        VkBufferImageCopy region {};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = { static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1 };
        regions.push_back(region);
    }
    if (isMipmapped) {
        Ubiquitty::Image::bleedIntoTransparentTexels(rgba.data(), width, height);
        int levelWidth = width;
        int levelHeight = height;
        std::size_t levelOffset = 0;
        for (int level = 1; level < levelCount; ++level) {
            const int nextWidth = std::max(1, levelWidth / 2);
            const int nextHeight = std::max(1, levelHeight / 2);
            const std::size_t nextOffset = rgba.size();
            rgba.resize(nextOffset + static_cast<std::size_t>(nextWidth) * nextHeight * 4);
            Ubiquitty::Image::downsampleImageMipLevel(rgba.data() + levelOffset, levelWidth, levelHeight, rgba.data() + nextOffset);
            Ubiquitty::Image::bleedIntoTransparentTexels(rgba.data() + nextOffset, nextWidth, nextHeight);
            VkBufferImageCopy region {};
            region.bufferOffset = static_cast<VkDeviceSize>(nextOffset);
            region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            region.imageSubresource.mipLevel = static_cast<uint32_t>(level);
            region.imageSubresource.layerCount = 1;
            region.imageExtent = { static_cast<uint32_t>(nextWidth), static_cast<uint32_t>(nextHeight), 1 };
            regions.push_back(region);
            levelOffset = nextOffset;
            levelWidth = nextWidth;
            levelHeight = nextHeight;
        }
    }
    out.isMipmapped = isMipmapped;

    VkImageCreateInfo imageInfo {};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
    imageInfo.extent = { static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1 };
    imageInfo.mipLevels = static_cast<uint32_t>(levelCount);
    imageInfo.arrayLayers = 1;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(device, &imageInfo, nullptr, &out.image) != VK_SUCCESS)
        return false;

    VkMemoryRequirements imageRequirements {};
    vkGetImageMemoryRequirements(device, out.image, &imageRequirements);
    VkMemoryAllocateInfo imageAlloc {};
    imageAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    imageAlloc.allocationSize = imageRequirements.size;
    imageAlloc.memoryTypeIndex = findMemoryType(physical, imageRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (imageAlloc.memoryTypeIndex == UINT32_MAX)
        return false;
    if (vkAllocateMemory(device, &imageAlloc, nullptr, &out.imageMemory) != VK_SUCCESS)
        return false;
    if (vkBindImageMemory(device, out.image, out.imageMemory, 0) != VK_SUCCESS)
        return false;

    VkImageViewCreateInfo viewInfo {};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = out.image;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.levelCount = static_cast<uint32_t>(levelCount);
    viewInfo.subresourceRange.layerCount = 1;
    if (vkCreateImageView(device, &viewInfo, nullptr, &out.view) != VK_SUCCESS)
        return false;

    // Nearest + clamp-to-edge: the shader uses integer texelFetch (no filtering),
    // but the sampler still declares nearest to match the CPU nearest tap.
    VkSamplerCreateInfo samplerInfo {};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_NEAREST;
    samplerInfo.minFilter = VK_FILTER_NEAREST;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    if (vkCreateSampler(device, &samplerInfo, nullptr, &out.sampler) != VK_SUCCESS)
        return false;

    // Staging buffer (host-visible) holding the widened RGBA8 mirror.
    const VkDeviceSize stagingSize = static_cast<VkDeviceSize>(rgba.size());
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
    VkBufferCreateInfo bufferInfo {};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = stagingSize;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(device, &bufferInfo, nullptr, &staging) != VK_SUCCESS)
        return false;
    VkMemoryRequirements bufferRequirements {};
    vkGetBufferMemoryRequirements(device, staging, &bufferRequirements);
    VkMemoryAllocateInfo bufferAlloc {};
    bufferAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bufferAlloc.allocationSize = bufferRequirements.size;
    bufferAlloc.memoryTypeIndex = findMemoryType(physical, bufferRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (bufferAlloc.memoryTypeIndex == UINT32_MAX) {
        vkDestroyBuffer(device, staging, nullptr);
        return false;
    }
    if (vkAllocateMemory(device, &bufferAlloc, nullptr, &stagingMemory) != VK_SUCCESS) {
        vkDestroyBuffer(device, staging, nullptr);
        return false;
    }
    if (vkBindBufferMemory(device, staging, stagingMemory, 0) != VK_SUCCESS) {
        vkDestroyBuffer(device, staging, nullptr);
        vkFreeMemory(device, stagingMemory, nullptr);
        return false;
    }
    void* mapped = nullptr;
    if (vkMapMemory(device, stagingMemory, 0, stagingSize, 0, &mapped) != VK_SUCCESS) {
        vkDestroyBuffer(device, staging, nullptr);
        vkFreeMemory(device, stagingMemory, nullptr);
        return false;
    }
    std::memcpy(mapped, rgba.data(), static_cast<std::size_t>(stagingSize));
    vkUnmapMemory(device, stagingMemory);

    // One-time command buffer: UNDEFINED -> TRANSFER_DST, copy, then ->
    // SHADER_READ_ONLY_OPTIMAL so the image pass samples it.
    VkCommandBufferAllocateInfo allocInfo {};
    allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.commandPool = commandPool;
    allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandBufferCount = 1;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    bool ok = vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer) == VK_SUCCESS;

    if (ok) {
        VkCommandBufferBeginInfo beginInfo {};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        ok = vkBeginCommandBuffer(commandBuffer, &beginInfo) == VK_SUCCESS;
    }
    if (ok) {
        VkImageSubresourceRange range {};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.levelCount = static_cast<uint32_t>(levelCount);
        range.layerCount = 1;

        auto barrier = [&](VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess, VkAccessFlags dstAccess, VkPipelineStageFlags srcStage, VkPipelineStageFlags dstStage) {
            VkImageMemoryBarrier memoryBarrier {};
            memoryBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            memoryBarrier.oldLayout = from;
            memoryBarrier.newLayout = to;
            memoryBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            memoryBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            memoryBarrier.image = out.image;
            memoryBarrier.subresourceRange = range;
            memoryBarrier.srcAccessMask = srcAccess;
            memoryBarrier.dstAccessMask = dstAccess;
            vkCmdPipelineBarrier(commandBuffer, srcStage, dstStage, 0, 0, nullptr, 0, nullptr, 1, &memoryBarrier);
        };

        barrier(VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);

        vkCmdCopyBufferToImage(commandBuffer, staging, out.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, static_cast<uint32_t>(regions.size()), regions.data());

        barrier(VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

        ok = vkEndCommandBuffer(commandBuffer) == VK_SUCCESS;
    }
    if (ok) {
        VkSubmitInfo submit {};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffer;
        ok = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS;
        if (ok)
            vkQueueWaitIdle(queue);
    }
    if (commandBuffer != VK_NULL_HANDLE)
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    vkDestroyBuffer(device, staging, nullptr);
    vkFreeMemory(device, stagingMemory, nullptr);
    if (!ok)
        return false;

    // Allocate + write the descriptor set bound to this texture.
    VkDescriptorSetAllocateInfo dsAlloc {};
    dsAlloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    dsAlloc.descriptorPool = m_descriptorPool;
    dsAlloc.descriptorSetCount = 1;
    dsAlloc.pSetLayouts = &m_descriptorSetLayout;
    if (vkAllocateDescriptorSets(device, &dsAlloc, &out.descriptorSet) != VK_SUCCESS)
        return false;
    VkDescriptorImageInfo descriptorImage {};
    descriptorImage.sampler = out.sampler;
    descriptorImage.imageView = out.view;
    descriptorImage.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkWriteDescriptorSet write {};
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = out.descriptorSet;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &descriptorImage;
    vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
    return true;
}

bool VulkanImageTextures::sync(VkDevice device, VkPhysicalDevice physical, VkQueue queue, VkCommandPool commandPool, const Ubiquitty::Image::TerminalImage* images, int imageCount,
    QueueState queueState, std::span<const std::uint32_t> filteredImageIDs)
{
    const auto isFiltered = [filteredImageIDs](std::uint32_t imageID) {
        return std::find(filteredImageIDs.begin(), filteredImageIDs.end(), imageID) != filteredImageIDs.end();
    };
    if (!images)
        imageCount = 0;

    // Evict cached textures whose imageID is no longer a used, displayable image.
    // A caller that cannot promise the queue is idle gets the device idled
    // before the first destroy, because a texture bound by work still running
    // would otherwise be freed under it.
    bool waited = queueState == QueueState::Idle;
    for (std::size_t i = 0; i < m_textures.size();) {
        const uint32_t id = m_textures[i].imageID;
        bool stillUsed = false;
        for (int ii = 0; ii < imageCount; ++ii) {
            const Ubiquitty::Image::TerminalImage& candidate = images[ii];
            if (candidate.used && candidate.pixels && candidate.width > 0 && candidate.height > 0 && candidate.imageID == id) {
                // Pixels, not geometry. A kitty frame advance and a same-id
                // re-transmit at identical size both leave width and height
                // alone, so a texture judged by those alone keeps sampling the
                // first upload for as long as the id lives -- an animation
                // frozen on frame 1, and the CPU renderer disagreeing with the
                // GPU about what is on screen.
                //
                // The same fold the macOS store compares, so the two backends
                // cannot decide differently about what a cached texture holds.
                // And levels: a texture uploaded for nearest draws has none,
                // so the first filtered draw of the image uploads it again.
                stillUsed = m_textures[i].contentStamp == Ubiquitty::Image::imageContentStamp(candidate)
                    && (m_textures[i].isMipmapped || !isFiltered(id));
                break;
            }
        }
        if (!stillUsed) {
            if (!waited) {
                vkDeviceWaitIdle(device);
                waited = true;
            }
            destroyTexture(device, m_textures[i]);
            m_textures.erase(m_textures.begin() + static_cast<std::ptrdiff_t>(i));
        } else {
            ++i;
        }
    }

    // Upload any used image that has no cached texture yet.
    for (int ii = 0; ii < imageCount; ++ii) {
        const Ubiquitty::Image::TerminalImage& candidate = images[ii];
        if (!candidate.used || !candidate.pixels || candidate.width <= 0 || candidate.height <= 0)
            continue;
        bool cached = false;
        for (const Texture& texture : m_textures) {
            if (texture.imageID == candidate.imageID) {
                cached = true;
                break;
            }
        }
        if (cached)
            continue;
        Texture texture;
        if (!uploadTexture(device, physical, queue, commandPool, candidate, isFiltered(candidate.imageID) ? Levels::Chain : Levels::BaseOnly, texture)) {
            destroyTexture(device, texture);
            return false;
        }
        // Stamped from the image this upload read, so the next sync compares
        // what is on the GPU against what Core now holds.
        texture.contentStamp = Ubiquitty::Image::imageContentStamp(candidate);
        m_textures.push_back(texture);
    }
    return true;
}

bool VulkanImageTextures::syncBackdrop(VkDevice device, VkPhysicalDevice physical, VkQueue queue, VkCommandPool commandPool,
    const Rendering::BackgroundImagePixels* pixels, uint64_t generation, QueueState queueState)
{
    const bool hasPixels = pixels && !pixels->isEmpty();
    if (generation == m_backdropGeneration && (m_backdrop.image != VK_NULL_HANDLE) == hasPixels)
        return true;
    if (m_backdrop.image != VK_NULL_HANDLE) {
        if (queueState == QueueState::MayBeExecuting)
            vkDeviceWaitIdle(device);
        destroyTexture(device, m_backdrop);
        m_backdrop = Texture {};
    }
    m_backdropGeneration = generation;
    if (!hasPixels)
        return true;
    Texture uploaded;
    if (!uploadPixels(device, physical, queue, commandPool, 0, pixels->rgba.data(), pixels->width, pixels->height, 32, Levels::BaseOnly, uploaded)) {
        destroyTexture(device, uploaded);
        return false;
    }
    m_backdrop = uploaded;
    return true;
}

VkDescriptorSet VulkanImageTextures::backdropDescriptor() const { return m_backdrop.descriptorSet; }

VkDescriptorSet VulkanImageTextures::descriptorFor(uint32_t imageID) const
{
    for (const Texture& texture : m_textures) {
        if (texture.imageID == imageID)
            return texture.descriptorSet;
    }
    return VK_NULL_HANDLE;
}

} // namespace Ubiquitty::Linux
