// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-gridcache — the retained-grid CPU<->GPU oracle, across frames. The
// single-frame smokes cannot see the reuse lane: the first frame over any
// terminal is full by construction, and only a second render of one grid
// — after a small edit, then after a scroll — takes the Load path and the
// scroll band copies. The CPU rasterizer re-reads the whole screen on every
// call, so byte-equality against it holds the retained target to its
// invariant: reuse changes the work, never the result. partialFrameCount() is
// the coverage bound — without it a verdict that rots to never-reuse turns
// this into a copy test that cannot fail.
/// Compares retained-grid edits and scrolling with complete software rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeGridCache()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-gridcache", "vulkan init failed");

    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-gridcache: no term\n");
        renderer.shutdown();
        return 1;
    }
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));

    struct Phase {
        const char* name;
        const char* bytes; // fed before the frame; "" feeds nothing
        std::uint64_t partialFramesAfter; // the coverage bound after this frame
    };
    const Phase phases[] = {
        { "full", "", 0 },
        // Two edits dirty two rows apart, one carrying an underline, so the
        // Load frame repaints rules as well as glyphs.
        { "edit", "\x1b[5;10Hedited \x1b[4mrow\x1b[0m\x1b[12;1Hsecond edited row", 1 },
        // No input at all: the frame Loads and repaints only the cursor rows.
        // What this frame shows is what the PAIR holds — a defect visible
        // here survived into the retained image; one visible only in the
        // frame before was transient to that encode.
        { "idle", "", 2 },
        // Newlines at the bottom row scroll the screen: the frame must copy
        // the band plan between the pair and repaint the exposed rows.
        { "scroll", "\x1b[24;1Hbottom\r\ntail one\r\ntail two", 3 },
    };

    bool didAllPhasesPass = true;
    std::string failedPhases;
    for (const Phase& phase : phases) {
        if (phase.bytes[0] != '\0')
            Ubiquitty::processBytes(term, phase.bytes);
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        // GPU first: the two arms share the injected rasterizer, and the CPU
        // render faulting a glyph first must not be able to change what the
        // GPU arm builds — running the subject before the oracle is what
        // makes a shared-cache contamination visible as a phase difference.
        const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
        const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
        const bool didCompareGPU = didRenderCPUFrame && didRenderGPUFrame;
        const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);
        const bool didTakeExpectedLane = !didCompareGPU || renderer.partialFrameCount() == phase.partialFramesAfter;
        g_print("smoke-gridcache: %-6s CPU==GPU %s, partial frames %llu (want %llu)\n", phase.name,
            oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)),
            static_cast<unsigned long long>(renderer.partialFrameCount()),
            static_cast<unsigned long long>(phase.partialFramesAfter));
        if (didCompareGPU && !same) {
            // Name the disagreement in cells, not just bytes: the first
            // differing pixel's row is usually the whole diagnosis for a
            // damage-tracking defect, and the PNG pair is the eyeball check.
            std::size_t firstDiffer = 0;
            while (firstDiffer < cpu.size() && firstDiffer < gpu.size() && cpu[firstDiffer] == gpu[firstDiffer])
                ++firstDiffer;
            const int pixelX = cpuWidth > 0 ? static_cast<int>((firstDiffer / 4) % static_cast<std::size_t>(cpuWidth)) : 0;
            const int pixelY = cpuWidth > 0 ? static_cast<int>((firstDiffer / 4) / static_cast<std::size_t>(cpuWidth)) : 0;
            int differingPixels = 0;
            for (std::size_t i = 0; i + 3 < cpu.size() && i + 3 < gpu.size(); i += 4)
                differingPixels += std::memcmp(cpu.data() + i, gpu.data() + i, 4) != 0 ? 1 : 0;
            g_print("smoke-gridcache: %s first differing pixel (%d,%d), %d pixel(s) differ\n", phase.name, pixelX, pixelY, differingPixels);
            for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("cpu", cpu), { "gpu", gpu } }) {
                const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { cpuWidth, cpuHeight });
                const std::string path = std::string("/tmp/gridcache_") + phase.name + "_" + label + ".png";
                if (FILE* f = std::fopen(path.c_str(), "wb")) {
                    std::fwrite(png.data(), 1, png.size(), f);
                    std::fclose(f);
                    g_print("smoke-gridcache: wrote %s\n", path.c_str());
                }
            }
        }
        if (!(same && didTakeExpectedLane)) {
            didAllPhasesPass = false;
            failedPhases += failedPhases.empty() ? phase.name : std::string(", ") + phase.name;
        }
    }
    renderer.shutdown();

    // The control that separates "the retained encode broke it" from "this
    // content never rendered right": the same final terminal through a FRESH
    // renderer is a first frame — full build, no pair, no Load — over the
    // same glyph population the partial frames just failed on.
    {
        Ubiquitty::Linux::VulkanRenderer freshRenderer;
        freshRenderer.setGlyphRasterizer(currentRasterizer());
        freshRenderer.setLigatureRasterizer(currentRasterizer());
        if (freshRenderer.init()) {
            std::vector<uint8_t> cpu;
            std::vector<uint8_t> gpu;
            int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
            const bool didRenderGPUFrame = freshRenderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
            const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
            const bool didCompareGPU = didRenderCPUFrame && didRenderGPUFrame;
            const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);
            g_print("smoke-gridcache: fresh-full control CPU==GPU %s\n",
                oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)));
            if (didCompareGPU && !same) {
                didAllPhasesPass = false;
                failedPhases += failedPhases.empty() ? "fresh-full" : std::string(", ") + "fresh-full";
            }
            freshRenderer.shutdown();
        }
    }

    if (didAllPhasesPass)
        g_print("smoke-gridcache: PASS\n");
    else
        g_print("smoke-gridcache: FAILED phase(s): %s\n", failedPhases.c_str());
    return didAllPhasesPass ? 0 : 1;
}
