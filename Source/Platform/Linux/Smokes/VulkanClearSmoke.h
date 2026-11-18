// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks the Vulkan clear path against the configured background.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeVulkanClear()
{
    Ubiquitty::Linux::VulkanRenderer renderer;
    if (!renderer.init())
        return skipNoGPUFrame("smoke(vulkan)", "vulkan init failed");
    std::vector<uint8_t> rgba;
    const bool ok = renderer.renderClear(640, 384, 0.05f, 0.45f, 0.5f, rgba);
    renderer.shutdown();
    if (!ok || rgba.size() < 4) {
        g_printerr("smoke(vulkan): render failed\n");
        return 1;
    }
    const size_t c = (static_cast<size_t>(192) * 640 + 320) * 4;
    const bool didPass = rgba[c + 3] == 255 && rgba[c + 1] > rgba[c] && rgba[c + 2] > rgba[c];
    g_print("smoke(vulkan): center RGBA = %u %u %u %u — %s\n", static_cast<unsigned>(rgba[c]), static_cast<unsigned>(rgba[c + 1]), static_cast<unsigned>(rgba[c + 2]), static_cast<unsigned>(rgba[c + 3]), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
