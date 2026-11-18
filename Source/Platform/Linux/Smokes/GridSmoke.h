// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks the visible grid produced from the canned terminal screen.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeGrid()
{
    setupFonts();
    initTermCanned();
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!term || !app().rasterContext.rasterizeTerm(term, rgba, width, height) || rgba.empty()) {
        g_printerr("smoke(grid): rasterize failed\n");
        return 1;
    }
    bool uniform = true;
    for (size_t i = 4; i + 3 < rgba.size(); i += 4)
        if (rgba[i] != rgba[0] || rgba[i + 1] != rgba[1] || rgba[i + 2] != rgba[2]) {
            uniform = false;
            break;
        }
    g_print("smoke(grid): %dx%d — %s\n", width, height, uniform ? "FAIL (blank)" : "PASS (has text)");
    return uniform ? 1 : 0;
}
