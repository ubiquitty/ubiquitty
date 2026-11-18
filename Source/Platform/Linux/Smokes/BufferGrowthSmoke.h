// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-cursor — the cursor-overlay CPU<->GPU oracle. For each cursor shape
// (block / bar / underline) plus an unfocused/hollow case, feed the canned
// screen with the matching DECSCUSR, build a DETERMINISTIC CursorOverlay (fixed
// opaque blinkAlpha so the result is stable + the overlay's lit pixels are fully
// opaque), render via both the CPU SoftwareRenderer and the GPU VulkanRenderer,
// and assert the two are byte-identical. Leaves /tmp/cursor_bar.png to eyeball.
// --smoke-buffer-growth — one renderer, two frames, the second on a grid the
// first's instance buffers cannot hold.
//
// The instance streams are mapped once when their buffers are created and stay
// mapped for the buffer's life, so the only moment those pointers change is a
// grow: the old buffers are freed and new ones made and mapped. No other smoke
// grows a buffer — every one of them renders a single geometry — so a grow that
// came back without a mapping would draw nothing here and be reported by
// nothing.
//
// Both frames are checked against the CPU rasterizer, and a frame that fails to
// render is a failure rather than a comparison that did not happen: past init,
// there is a device, so a refusal is the renderer's answer and not the
// machine's.
/// Checks that instance buffers grow for a larger second frame.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeBufferGrowth()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-buffer-growth", "vulkan init failed");

    struct Step {
        const char* name;
        int rows;
        int columns;
    };
    // Small first, so the second frame's cell, glyph and decoration counts all
    // exceed the capacities the first frame's buffers were sized to.
    const Step steps[] = {
        { "small", 8, 20 },
        { "grown", 40, 120 },
    };

    bool didEveryStepMatch = true;
    int widestSoFar = 0;
    for (const Step& step : steps) {
        activePane()->session->start(step.rows, step.columns);
        Ubiquitty::Terminal* term = activePane()->session->terminal();
        if (!term) {
            g_printerr("smoke-buffer-growth: no term\n");
            renderer.shutdown();
            return 1;
        }
        // start() does not resize a session that is already running, and the
        // render size is derived from the terminal — so without this the second
        // step renders the first step's grid and grows nothing.
        Ubiquitty::resize(*term, step.rows, step.columns);
        // Underlined, coloured text, so the decoration and glyph streams carry
        // instances too rather than only the cell stream.
        for (int row = 0; row < step.rows; ++row) {
            Ubiquitty::processBytes(term, "\x1b[4;33m");
            for (int column = 0; column < step.columns - 1; ++column)
                Ubiquitty::processBytes(term, "W");
            Ubiquitty::processBytes(term, "\x1b[0m\r\n");
        }

        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRasterizeCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
        const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
        const bool didCompareGPU = didRasterizeCPUFrame && didRenderGPUFrame;
        const bool same = didCompareGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu;
        if (!didRenderGPUFrame)
            g_printerr("smoke-buffer-growth: FAIL: '%s' rendered no frame, on a device that initialised\n", step.name);
        g_print("smoke-buffer-growth: %-6s CPU==GPU %s (%dx%d)\n", step.name,
            oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)),
            cpuWidth, cpuHeight);
        didEveryStepMatch = didEveryStepMatch && same;
        // The growth has to have happened, or this smoke passes by rendering the
        // same grid twice and never frees a buffer.
        if (gpuWidth > widestSoFar)
            widestSoFar = gpuWidth;
        else if (didRenderGPUFrame) {
            g_printerr("smoke-buffer-growth: FAIL: '%s' rendered %d wide, no wider than the step before it — nothing grew\n",
                step.name, gpuWidth);
            didEveryStepMatch = false;
        }
    }
    renderer.shutdown();
    g_print("smoke-buffer-growth: %s\n", didEveryStepMatch ? "PASS" : "FAIL");
    return didEveryStepMatch ? 0 : 1;
}
