// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <span>
#include <vulkan/vulkan.h>

// One R8 coverage sheet on the device, uploaded from a host mirror.
//
// The glyph atlas and the ligature strip sheet are the same object at this
// level: an R8 image the fragment stage samples as coverage, a nearest sampler,
// and a staging buffer the whole mirror is copied through when a slot changes.
// They differ only in extent and in what writes the mirror.
//
// Extracted because the second one was about to be the same two hundred lines of
// image, memory, view, sampler, staging and barriers again. Two copies of a
// resource lifetime drift in the way that is hardest to see: the sampler's
// filter, a barrier's stage mask, or the layout an upload leaves behind can
// differ between them and only show as one sheet sampling slightly differently
// from the other.
//
// Nearest and clamp-to-edge, not a choice a caller makes. The reason is narrower
// than it looks, and is written down because the obvious version of it is wrong:
// `cell.frag` and `glyph.frag` read coverage with `texelFetch`, which ignores the
// sampler entirely, so the CPU-versus-GPU byte oracle rests on the fetch and not
// on this filter. `decoration.frag` is the one pass that samples with
// `texture()`, and there the filter decides what a rule's coverage reads.
//
// Measured: flipping this to `VK_FILTER_LINEAR` leaves all forty Linux smokes
// green. So nothing here detects a change to it, and the setting is held by this
// comment rather than by a test — which is worth knowing before trusting a green
// after touching it.

namespace Ubiquitty::Linux {

/// Owns one single-channel coverage image and everything needed to fill it.
///
/// The image, its view, a nearest sampler and a staging buffer are one unit
/// because their lifetimes are: the view outlives nothing the image does not,
/// and the staging buffer is sized by the extent the image was created with. A
/// caller supplies the extent and a host mirror; where the mirror's bytes come
/// from is the caller's, and this class never interprets them.
///
/// Every entry point tolerates a sheet that was never created or whose creation
/// failed partway, so a caller that gives up midway can call ``destroy`` without
/// tracking how far it got.
class VulkanCoverageSheet {
public:
    /// Creates the image, its view, the sampler and the staging buffer.
    ///
    /// - Parameters:
    ///   - device: The logical device that owns every handle here.
    ///   - physical: Queried for a memory type; not retained.
    ///   - widthInPixels: The sheet's width. Must be positive; a zero extent is
    ///     refused rather than handed to `vkCreateImage`.
    ///   - heightInPixels: The sheet's height, on the same terms.
    /// - Returns: Whether every handle was created. On failure the caller calls
    ///   ``destroy``, which tolerates a partially built sheet.
    [[nodiscard]] bool create(VkDevice device, VkPhysicalDevice physical, int widthInPixels, int heightInPixels);

    /// Releases every handle, in the order that keeps each one's dependencies
    /// alive until it is gone.
    ///
    /// Safe on a sheet that was never created, and on one whose creation failed
    /// partway: each handle is checked against `VK_NULL_HANDLE` first, which is
    /// what lets ``create`` report failure by returning rather than by unwinding
    /// whatever it managed to build.
    ///
    /// - Parameters:
    ///   - device: The logical device the handles belong to. Must be the one
    ///     passed to ``create``; the sheet does not retain it between calls.
    void destroy(VkDevice device);

    /// Copies rows `[firstRow, firstRow + rowCount)` of `mirror` into the image
    /// and leaves it in the shader-read layout.
    ///
    /// Rows rather than slots, because rows are what a buffer-to-image copy
    /// addresses: a slot is a rectangle inside a row band, and copying its
    /// columns alone would need one region per slot row for no saving that
    /// matters. A caller holding dirty SLOTS converts them to the band that
    /// contains them.
    ///
    /// A frame that faults one glyph copies one band. The whole sheet is
    /// megabytes and a band is kilobytes, and the copy is the same one either
    /// way — only its extent changes, so the barriers do not move.
    ///
    /// The call is synchronous: it submits the copy and waits for the queue to
    /// go idle before returning, so the caller may reuse or free `mirror` the
    /// moment it has.
    ///
    /// - Parameters:
    ///   - device: The logical device the sheet's handles belong to.
    ///   - queue: The queue the copy is submitted on, and the one waited upon.
    ///   - commandPool: Allocates the one-shot command buffer, which is freed
    ///     before returning.
    ///   - mirror: The host bytes, exactly `width * height` of them. A mirror of
    ///     another size is refused — it would either read past the sheet or
    ///     leave part of it holding the previous frame.
    ///   - firstRow: The first pixel row to copy.
    ///   - rowCount: How many rows to copy. A range reaching past the sheet is
    ///     refused rather than clamped, for the same reason a mis-sized mirror
    ///     is: the caller has computed something wrong and a partial copy would
    ///     leave the difference on screen as a stale glyph.
    /// - Returns: Whether the image now holds those rows of `mirror`.
    [[nodiscard]] bool upload(VkDevice device, VkQueue queue, VkCommandPool commandPool, std::span<const std::uint8_t> mirror,
        int firstRow, int rowCount);

    /// Copies the whole mirror, for a caller that has no dirty range to give.
    ///
    /// - Parameters:
    ///   - device: The logical device the sheet's handles belong to.
    ///   - queue: The queue the copy is submitted on, and the one waited upon.
    ///   - commandPool: Allocates the one-shot command buffer.
    ///   - mirror: The host bytes, exactly `width * height` of them.
    /// - Returns: Whether the image now holds `mirror`.
    [[nodiscard]] bool upload(VkDevice device, VkQueue queue, VkCommandPool commandPool, std::span<const std::uint8_t> mirror);

    /// Stages a row band and records its copy into a caller-owned command buffer.
    /// The previous upload must have completed. Keep the sheet and its staging
    /// storage alive and unchanged until this buffer completes, then call
    /// `didUpload`. Discarding an unsubmitted buffer leaves the image state intact.
    [[nodiscard]] bool recordUpload(VkDevice device, VkCommandBuffer commandBuffer, std::span<const std::uint8_t> mirror,
        int firstRow, int rowCount);

    /// Commits the image layout after the recorded upload completes successfully.
    void didUpload();

    /// The view the descriptor binds.
    [[nodiscard]] VkImageView view() const { return m_view; }
    /// The sampler the descriptor binds.
    [[nodiscard]] VkSampler sampler() const { return m_sampler; }
    /// The image, for a caller reading it back to check what an upload wrote.
    ///
    /// Exposed for that one purpose: the offsets a partial upload computes are
    /// the thing here that can be wrong without failing, and comparing the
    /// image to the mirror is what catches it. The render path binds the view
    /// and the sampler above and has no use for this.
    [[nodiscard]] VkImage imageForReadback() const { return m_image; }

    /// Whether an upload has happened, so the image is in the shader-read layout.
    [[nodiscard]] bool isReadable() const { return m_isImageInitialized; }

private:
    int m_widthInPixels = 0;
    int m_heightInPixels = 0;
    VkImage m_image = VK_NULL_HANDLE;
    VkDeviceMemory m_imageMemory = VK_NULL_HANDLE;
    VkImageView m_view = VK_NULL_HANDLE;
    VkSampler m_sampler = VK_NULL_HANDLE;
    VkBuffer m_staging = VK_NULL_HANDLE;
    VkDeviceMemory m_stagingMemory = VK_NULL_HANDLE;
    VkDeviceSize m_stagingSize = 0;
    // False until the first upload's layout transition, which decides whether a
    // barrier comes from UNDEFINED or from SHADER_READ_ONLY.
    bool m_isImageInitialized = false;
    bool m_hasPendingUpload = false;
};

} // namespace Ubiquitty::Linux
