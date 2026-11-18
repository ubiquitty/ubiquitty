// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-image-vk — the inline-image CPU<->GPU oracle (Stage 11b) for a
// nearest draw: the same solid-red DEC sixel as --smoke-image, whose texels the
// GPU shader picks and over-blends exactly as the CPU does.
/// Compares nearest-neighbour image rendering across software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeImageVulkan()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk: no term\n");
        return 1;
    }

    // Same sixel as smokeImage: reg 1 = 100% red, repeated 16 px wide x 6 px tall.
    const char sixel[] = "\x1bP0;0;0q#1;2;100;0;0#1!16~\x1b\\";
    Ubiquitty::processBytes(term, std::string_view(sixel, sizeof(sixel) - 1));

    const int placements = Ubiquitty::Image::placementCount(term);
    if (placements < 1) {
        g_printerr("smoke-image-vk: sixel did not produce a placement (count=%d)\n", placements);
        return 1;
    }
    return compareImageOracle("smoke-image-vk", term);
}
