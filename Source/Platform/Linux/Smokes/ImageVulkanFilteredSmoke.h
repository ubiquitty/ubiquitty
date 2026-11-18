// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-image-vk-filtered — the same oracle for filtered draws: a 32x32
// RGBA gradient with a transparent half, placed in a five-cell box (enlarged
// by a fraction) and a two-cell one (reduced, across two mip levels), so Core
// marks both Image::ImageFilter::Smooth. The GPU
// shader reads the CPU's mip chain with the CPU's own bilinear and level
// blend, so the frames must still match to the byte.
/// Compares filtered image scaling across software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeImageVulkanFiltered()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk-filtered: no term\n");
        return 1;
    }
    constexpr int side = 32;
    std::string pixels;
    pixels.reserve(side * side * 4);
    for (int y = 0; y < side; ++y) {
        for (int x = 0; x < side; ++x) {
            pixels.push_back(static_cast<char>(x * 8));
            pixels.push_back(static_cast<char>(y * 8));
            pixels.push_back(static_cast<char>((x + y) * 4));
            pixels.push_back(static_cast<char>(x < side / 2 ? 255 : (x - side / 2) * 16));
        }
    }
    std::string base64;
    base64.resize(Ubiquitty::Codec::base64EncodedLength(pixels.size()));
    const auto encoded = Ubiquitty::Codec::base64Encode({ pixels.data(), pixels.size() }, { base64.data(), base64.size() });
    if (!encoded)
        return 1;
    base64.resize(encoded->size());
    const std::string transfer = "\x1b_Ga=T,f=32,s=32,v=32,c=5,q=2;" + base64 + "\x1b\\"
        + "\x1b[8;1H\x1b_Ga=T,f=32,s=32,v=32,c=2,q=2;" + base64 + "\x1b\\";
    Ubiquitty::processBytes(term, transfer);
    Ubiquitty::drainAsyncDecodes(*term);
    if (Ubiquitty::Image::placementCount(term) < 2) {
        g_printerr("smoke-image-vk-filtered: the transfers did not produce two placements\n");
        return 1;
    }
    return compareImageOracle("smoke-image-vk-filtered", term);
}
