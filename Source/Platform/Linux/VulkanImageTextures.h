// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Vulkan side of the inline-image pass. Owns one RGBA8 VkImage per USED
// TerminalImage (format 24 RGB widened to opaque RGBA on upload), each with a
// nearest / clamp-to-edge sampler and a combined-image-sampler descriptor. Keyed
// by imageID, rebuilt when the Terminal's image set changes. The fragment shader
// samples with INTEGER texelFetch coords derived exactly as
// SoftwareRenderer::compositeImages picks its nearest texel and over-blends in the
// integer domain, so the GPU pass is byte-identical to the CPU path (the oracle).
// An image a filtered quad draws (Image::ImageFilter::Smooth) also carries the
// mip chain Core's rule builds, which the shader reads the same way.

#include "Core/Rendering/BackgroundImage.h"

#include <cstdint>
#include <span>
#include <vector>

#include <vulkan/vulkan.h>

namespace Ubiquitty::Image {
struct TerminalImage;
}

namespace Ubiquitty::Linux {

// One resolved image-pass instance, uploaded into a VkBuffer as the per-instance
// vertex input. Destination rect + normalized source UVs are ImageQuad fields;
// texSize lets the shader recover the nearest source texel the same way
// SoftwareRenderer::compositeImages does.
struct ImageInstance {
    float minXInPixels;
    float minYInPixels;
    float maxXInPixels;
    float maxYInPixels;
    float u0;
    float v0;
    float u1;
    float v1;
    float texWidth;
    float texHeight;
    float straightAlpha;
    float filtered; // 1 when Core marked the quad Image::ImageFilter::Smooth
};

// One per-image GPU texture (RGBA8 VkImage + view + sampler + descriptor set),
// keyed by the source TerminalImage::imageID.
class VulkanImageTextures {
public:
    // Borrow the device handles the renderer already owns. descriptorSetLayout
    // is the image pass's combined-image-sampler layout (one binding 0); the
    // cache allocates a descriptor set per texture from its own pool.
    bool create(VkDevice, VkPhysicalDevice, VkQueue, uint32_t queueFamily, VkCommandPool, VkDescriptorSetLayout);
    void destroy(VkDevice);

    /// What the caller can promise about work already submitted.
    ///
    /// An evicted texture is destroyed here, and destroying one a frame is
    /// still sampling is a use-after-free the driver reports as a corrupted
    /// image or not at all. Whether that can happen is the caller's fact, not
    /// this class's, so the caller states it.
    ///
    /// It is a parameter rather than a comment because the answer changes with
    /// the frame path. `renderGrid` submits and waits before it returns, so
    /// nothing is executing when the next frame calls in; a pipeline that let
    /// frames overlap would make that false, and the compiler asks for the new
    /// answer at every call site rather than leaving the old assumption to hold
    /// silently.
    enum class QueueState : std::uint8_t {
        /// Nothing submitted is still executing. An eviction destroys at once.
        Idle,
        /// Submitted work may still be running, and the queue owner cannot say
        /// which textures it reads. The device is idled before any destroy --
        /// correct, and as slow as that sounds.
        MayBeExecuting
    };

    /// Uploads a texture for every image in use and evicts the rest.
    ///
    /// - Parameters:
    ///   - images: The terminal's image table.
    ///   - imageCount: How many entries of `images` are live.
    ///   - queueState: Whether submitted work may still read an evicted
    ///     texture.
    /// - Returns: `false` on any Vulkan failure, leaving the cache usable but
    ///   incomplete.
    ///   - filteredImageIDs: The images a filtered quad draws this frame; each
    ///     carries a mip chain, built by Core's rule.
    bool sync(VkDevice, VkPhysicalDevice, VkQueue, VkCommandPool, const Ubiquitty::Image::TerminalImage* images, int imageCount,
        QueueState queueState, std::span<const std::uint32_t> filteredImageIDs);

    // The descriptor set bound to imageID's texture, or VK_NULL_HANDLE when the
    // id is not cached (the caller skips the draw).
    [[nodiscard]] VkDescriptorSet descriptorFor(uint32_t imageID) const;

    /// Uploads the window's background image when it changed.
    ///
    /// - Parameters:
    ///   - pixels: The decoded image, or null for none.
    ///   - generation: The raster context's count of image changes; the upload
    ///     is redone only when it moves.
    ///   - queueState: Whether submitted work may still read the old texture.
    /// - Returns: `false` on any Vulkan failure, leaving no background texture.
    bool syncBackdrop(VkDevice, VkPhysicalDevice, VkQueue, VkCommandPool, const Rendering::BackgroundImagePixels* pixels, uint64_t generation,
        QueueState queueState);

    /// The descriptor set bound to the background image's texture, or
    /// `VK_NULL_HANDLE` when none is uploaded.
    [[nodiscard]] VkDescriptorSet backdropDescriptor() const;

private:
    struct Texture {
        uint32_t imageID = 0;
        int width = 0;
        int height = 0;
        // What the uploaded pixels were, folded to one number by
        // Image::imageContentStamp: geometry, the animation frame, the format,
        // and the generation Core bumps whenever a same-id re-transmit replaces
        // pixels. An id and a size do not identify pixels -- a kitty frame
        // advance and a same-size re-decode both keep those and change these --
        // so this is what decides whether the cached upload is still the image.
        uint64_t contentStamp = 0;
        bool isMipmapped = false;
        VkImage image = VK_NULL_HANDLE;
        VkDeviceMemory imageMemory = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
        VkSampler sampler = VK_NULL_HANDLE;
        VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    };

    /// Which levels an upload carries.
    enum class Levels : std::uint8_t {
        /// Level zero alone, for an image only ever drawn nearest.
        BaseOnly,
        /// Level zero and Core's mip chain below it, for a filtered draw.
        Chain,
    };

    /// Uploads one image's pixels as an RGBA8 texture with its descriptor set.
    ///
    /// - Parameters:
    ///   - levels: Whether the mip chain is uploaded below level zero.
    ///   - out: Receives the created texture. Left untouched on failure, so a
    ///     caller never destroys half-created handles.
    /// - Returns: `false` on any Vulkan failure.
    bool uploadTexture(VkDevice, VkPhysicalDevice, VkQueue, VkCommandPool, const Ubiquitty::Image::TerminalImage&, Levels levels, Texture& out);
    /// Uploads pixels as a texture: the body of ``uploadTexture``, for a
    /// source that is not a terminal image.
    ///
    /// - Parameters:
    ///   - imageID: The identity the texture is recorded under.
    ///   - pixels: Row-major pixels in `format`.
    ///   - format: 24 for RGB, 32 for RGBA.
    ///   - levels: Whether the mip chain is uploaded below level zero.
    ///   - out: Receives the created texture.
    /// - Returns: `false` on any Vulkan failure.
    bool uploadPixels(VkDevice, VkPhysicalDevice, VkQueue, VkCommandPool, uint32_t imageID, const unsigned char* pixels, int width, int height, int format,
        Levels levels, Texture& out);
    void destroyTexture(VkDevice, Texture&);
    [[nodiscard]] uint32_t findMemoryType(VkPhysicalDevice, uint32_t typeBits, VkMemoryPropertyFlags want) const;

    VkDescriptorSetLayout m_descriptorSetLayout = VK_NULL_HANDLE;
    VkDescriptorPool m_descriptorPool = VK_NULL_HANDLE;
    std::vector<Texture> m_textures;
    // The window's background image, outside the terminal images' table, and
    // the raster context's generation it was uploaded at.
    Texture m_backdrop;
    uint64_t m_backdropGeneration = 0;
};

} // namespace Ubiquitty::Linux
