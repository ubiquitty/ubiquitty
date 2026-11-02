// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// Source/Platform/Linux/VulkanMemory.h — the memory-type search, once.
//
// `VulkanRenderer`, `VulkanGlyphAtlas` and `VulkanImageTextures` each carried
// their own copy of this loop. It is four lines and identical in all three,
// which is what makes a fourth copy tempting and what makes the set worth
// collapsing: a device whose memory types need a different predicate would have
// to be taught in as many places as there are copies, and the one that gets
// missed fails as an allocation error on somebody else's hardware.
//

#include <cstdint>
#include <span>
#include <vulkan/vulkan.h>

namespace Ubiquitty::Linux {

/// Finds a memory type satisfying a resource's bits and the properties wanted.
///
/// - Parameters:
///   - physical: The device whose memory types are searched.
///   - typeBits: The `memoryTypeBits` from the resource's requirements.
///   - want: The properties the allocation needs.
/// - Returns: The type index, or `UINT32_MAX` when none qualifies — a caller
///   must treat that as a failure rather than passing it to `vkAllocateMemory`,
///   which would reject it as an invalid index.
[[nodiscard]] inline std::uint32_t findVulkanMemoryType(VkPhysicalDevice physical, std::uint32_t typeBits, VkMemoryPropertyFlags want)
{
    VkPhysicalDeviceMemoryProperties properties {};
    vkGetPhysicalDeviceMemoryProperties(physical, &properties);
    for (std::uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        if ((typeBits & (1u << i)) != 0 && (properties.memoryTypes[i].propertyFlags & want) == want)
            return i;
    }
    return UINT32_MAX;
}

/// Which memory type a host-read staging buffer should use.
struct ReadbackMemoryChoice {
    /// The type index, or `UINT32_MAX` when the device offers none.
    std::uint32_t typeIndex = UINT32_MAX;
    /// Whether the chosen type is coherent. A cached type that is not coherent
    /// holds stale lines until the range is invalidated, so a caller that skips
    /// that reads whatever the CPU last had -- the previous frame, or nothing.
    bool isCoherent = false;
};

/// Picks the memory type for a buffer the host READS.
///
/// The direction is what decides this. A staging buffer written by the host and
/// read by the device wants coherent memory and does not care about the cache;
/// one the device writes and the host reads is the other way round, and getting
/// it wrong is not a small loss. On discrete GPUs the host-visible types that
/// are coherent but not cached are write-combined: CPU reads from them bypass
/// the cache and run about an order of magnitude slower than normal memory,
/// which for a full-frame readback is megabytes of uncached reads per repaint.
///
/// Preference order, and each step is a real device:
///
///   cached and coherent  — reads hit the cache and need no invalidate
///   cached only          — reads hit the cache; the caller must invalidate
///   coherent only        — no cached type exists; the write-combined read is
///                          what the device offers
///
/// Separated from the allocation so it can be checked against memory tables no
/// machine here has. The choice is the part that can be wrong on a device the
/// author cannot run.
///
/// - Parameters:
///   - typeFlags: Each memory type's property flags, in type-index order.
///   - allowedTypeBits: The `memoryTypeBits` from the buffer's requirements.
/// - Returns: The chosen type and whether it is coherent.
[[nodiscard]] inline ReadbackMemoryChoice chooseReadbackMemoryType(std::span<const VkMemoryPropertyFlags> typeFlags, std::uint32_t allowedTypeBits)
{
    constexpr VkMemoryPropertyFlags cachedAndCoherent
        = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    constexpr VkMemoryPropertyFlags cachedOnly
        = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    constexpr VkMemoryPropertyFlags coherentOnly
        = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    const auto firstWith = [&](VkMemoryPropertyFlags want) -> std::uint32_t {
        for (std::uint32_t index = 0; index < typeFlags.size(); ++index) {
            if ((allowedTypeBits & (1u << index)) != 0 && (typeFlags[index] & want) == want)
                return index;
        }
        return UINT32_MAX;
    };

    std::uint32_t index = firstWith(cachedAndCoherent);
    if (index != UINT32_MAX)
        return { index, true };
    index = firstWith(cachedOnly);
    if (index != UINT32_MAX)
        return { index, false };
    index = firstWith(coherentOnly);
    if (index != UINT32_MAX)
        return { index, true };
    return {};
}

} // namespace Ubiquitty::Linux
