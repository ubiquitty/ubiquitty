// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <algorithm>
#include <cstdint>

namespace Ubiquitty::Linux {

/// An image's size in device pixels.
///
/// Free of the Vulkan headers, so the bound it carries can be checked on a host
/// with no Vulkan SDK; ``VulkanRenderer`` fills it from the device it runs on.
struct ImageExtent {
    std::uint32_t width = 0;
    std::uint32_t height = 0;

    friend constexpr bool operator==(const ImageExtent&, const ImageExtent&) = default;

    /// Whether an image of the given size fits inside this one.
    ///
    /// - Parameters:
    ///   - imageWidth: The image's width in device pixels.
    ///   - imageHeight: Its height.
    /// - Returns: Whether neither side is past this extent's.
    [[nodiscard]] constexpr bool contains(std::uint64_t imageWidth, std::uint64_t imageHeight) const
    {
        return imageWidth <= width && imageHeight <= height;
    }

    /// Whether a grid's frame fits: its columns and rows at one cell each.
    ///
    /// The products are taken in 64 bits, so a grid at the model's maximum
    /// over a cell at the largest font cannot wrap round to a frame that fits.
    ///
    /// - Parameters:
    ///   - columns: The grid's columns.
    ///   - rows: Its rows.
    ///   - cellWidth: A cell's width in device pixels.
    ///   - cellHeight: A cell's height in device pixels.
    /// - Returns: Whether the frame fits; an empty grid or cell has no frame and does not.
    [[nodiscard]] constexpr bool containsGrid(int columns, int rows, int cellWidth, int cellHeight) const
    {
        if (columns <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0)
            return false;
        return contains(static_cast<std::uint64_t>(columns) * static_cast<std::uint64_t>(cellWidth),
            static_cast<std::uint64_t>(rows) * static_cast<std::uint64_t>(cellHeight));
    }
};

/// The largest frame a device can render into.
///
/// The frame is an image, bound as a framebuffer and drawn through a viewport
/// of its own size, so all three limits apply to it: a device may report a
/// framebuffer or a viewport smaller than the largest image it makes.
///
/// - Parameters:
///   - maxImageDimension: The widest or tallest 2D image the device makes.
///   - maxFramebufferWidth: The widest framebuffer it binds.
///   - maxFramebufferHeight: The tallest framebuffer it binds.
///   - maxViewportWidth: The widest viewport it sets.
///   - maxViewportHeight: The tallest viewport it sets.
/// - Returns: The extent every side of a render target must stay within.
[[nodiscard]] constexpr ImageExtent maxRenderTargetExtent(std::uint32_t maxImageDimension, std::uint32_t maxFramebufferWidth,
    std::uint32_t maxFramebufferHeight, std::uint32_t maxViewportWidth, std::uint32_t maxViewportHeight)
{
    return { std::min({ maxImageDimension, maxFramebufferWidth, maxViewportWidth }),
        std::min({ maxImageDimension, maxFramebufferHeight, maxViewportHeight }) };
}

} // namespace Ubiquitty::Linux
