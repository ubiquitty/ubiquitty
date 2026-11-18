// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Compares cursor shapes and focus states across software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeCursor()
{
    setupFonts();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-cursor", "vulkan init failed");

    struct Case {
        const char* name;
        const char* decscusr; // DECSCUSR escape, "" = leave default (block)
        Ubiquitty::Cursor::Shape shape;
        bool focused;
    };
    const Case cases[] = {
        { "block", "", Ubiquitty::Cursor::Shape::Block, true },
        { "bar", "\x1b[5 q", Ubiquitty::Cursor::Shape::Bar, true },
        { "underline", "\x1b[3 q", Ubiquitty::Cursor::Shape::Underline, true },
        { "hollow", "", Ubiquitty::Cursor::Shape::Block, false }, // unfocused block → hollow outline
    };

    bool didAllPass = true;
    for (const Case& testCase : cases) {
        // Fresh canned screen per case (the cursor sits at the prompt).
        activePane()->session->start(startupRows, startupColumns);
        Ubiquitty::Terminal* term = activePane()->session->terminal();
        if (!term) {
            g_printerr("smoke-cursor: no term\n");
            renderer.shutdown();
            return 1;
        }
        Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));
        if (testCase.decscusr[0] != '\0')
            Ubiquitty::processBytes(term, testCase.decscusr);

        // Deterministic overlay: opaque blink (the lit pixels are fully opaque,
        // so CPU integer-blend == GPU hardware-blend exactly) at the resolved shape.
        Ubiquitty::Linux::CursorOverlay cursor;
        cursor.visible = true;
        cursor.shape = testCase.shape;
        cursor.blinkAlpha = 1.0f;
        cursor.focused = testCase.focused;

        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRasterizeCPU = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor);
        const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor);
        const bool didCompareGPU = didRasterizeCPU && didRenderGPUFrame;
        const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);

        // The frame split the perf log reports. Checked here because this is a
        // real renderGrid: the counters are read from a wrapping microsecond
        // clock, and a delta taken after the conversion to seconds rather than
        // before turns a wrap into a negative interval that reads as a fast
        // frame. A frame that rendered has to have spent time in both halves.
        if (didRenderGPUFrame) {
            const double waitSeconds = renderer.lastFrameWaitSeconds();
            const double readbackSeconds = renderer.lastFrameReadbackSeconds();
            const bool areTimingsSane = waitSeconds >= 0.0 && readbackSeconds >= 0.0
                && waitSeconds < 60.0 && readbackSeconds < 60.0
                && (waitSeconds + readbackSeconds) > 0.0;
            if (!areTimingsSane) {
                g_printerr("smoke-cursor: FAIL: frame split is not a time (wait=%f readback=%f)\n",
                    waitSeconds, readbackSeconds);
                didAllPass = false;
            }
        }
        g_print("smoke-cursor: %-9s CPU==GPU %s (%dx%d)\n", testCase.name, oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)), cpuWidth, cpuHeight);
        didAllPass = didAllPass && same;

        // A parser-boundary frame must keep its own text and palette even if
        // the parser advances, while GTK supplies its presentation-time blink.
        const auto geometry = app().rasterContext.frameCaptureGeometry();
        Ubiquitty::Rendering::TerminalSnapshotOptions options;
        options.style = geometry.style;
        options.isFocused = testCase.focused;
        options.cellHeightPoints = geometry.cellHeightPoints;
        options.lineSpacingPoints = geometry.lineSpacingPoints;
        options.toolkitCaret = geometry.toolkitCaret;
        const char* steadyStyle = testCase.shape == Ubiquitty::Cursor::Shape::Bar ? "\x1b[6 q"
                                                                                  : (testCase.shape == Ubiquitty::Cursor::Shape::Underline ? "\x1b[4 q" : "\x1b[2 q");
        Ubiquitty::processBytes(term, steadyStyle);
        std::unique_ptr<Ubiquitty::Rendering::FrameCapture, LinuxPane::FrameRelease> captured(Ubiquitty::Rendering::FrameCapture::make());
        const bool didCapture = captured->capture(*term, options, geometry.metrics, geometry.glyphSlot);
        bool areCapturedPhasesEqual = didCapture;
        for (const float alpha : { 1.0f, 0.75f, 0.5f, 0.25f, 0.0f }) {
            cursor.blinkAlpha = alpha;
            captured->setCursorMixAlpha(alpha);
            std::vector<uint8_t> livePixels, capturedPixels;
            int liveWidth = 0, liveHeight = 0, capturedWidth = 0, capturedHeight = 0;
            const bool didDrawLive = renderer.renderGrid(app().rasterContext, term, livePixels, liveWidth, liveHeight, 0, nullptr, &cursor);
            const bool didDrawCapture = renderer.renderGrid(app().rasterContext, term, capturedPixels, capturedWidth, capturedHeight, 0, nullptr, &cursor, 0, {}, captured.get());
            areCapturedPhasesEqual = areCapturedPhasesEqual && didDrawLive && didDrawCapture
                && liveWidth == capturedWidth && liveHeight == capturedHeight && livePixels == capturedPixels;
        }
        g_print("smoke-cursor: %-9s captured GTK blink phases -- %s\n", testCase.name, areCapturedPhasesEqual ? "PASS" : "FAIL");
        didAllPass = didAllPass && areCapturedPhasesEqual;
        std::vector<uint8_t> beforeAdvance, afterAdvance;
        int beforeWidth = 0, beforeHeight = 0, afterWidth = 0, afterHeight = 0;
        const bool didDrawBeforeAdvance = renderer.renderGrid(app().rasterContext, term, beforeAdvance, beforeWidth, beforeHeight, 0, nullptr, &cursor, 0, {}, captured.get());
        Ubiquitty::processBytes(term, "\x1b]11;#550099\x07\x1b[2J\x1b[Hnext redraw");
        const bool didDrawAfterAdvance = renderer.renderGrid(app().rasterContext, term, afterAdvance, afterWidth, afterHeight, 0, nullptr, &cursor, 0, {}, captured.get());
        const bool isCaptureStable = didDrawBeforeAdvance && didDrawAfterAdvance && beforeWidth == afterWidth && beforeHeight == afterHeight
            && beforeAdvance == afterAdvance;
        g_print("smoke-cursor: %-9s capture survives next redraw -- %s\n", testCase.name, isCaptureStable ? "PASS" : "FAIL");
        didAllPass = didAllPass && isCaptureStable;

        // Leave the bar PNG on disk for an eyeball check.
        if (std::string_view(testCase.name) == "bar" && didRasterizeCPU) {
            const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(cpu, { cpuWidth, cpuHeight });
            FILE* f = std::fopen("/tmp/cursor_bar.png", "wb");
            if (f) {
                std::fwrite(png.data(), 1, png.size(), f);
                std::fclose(f);
                g_print("smoke-cursor: wrote /tmp/cursor_bar.png (%dx%d)\n", cpuWidth, cpuHeight);
            }
        }
    }
    didAllPass = smokeCursorPresentation(renderer) && didAllPass;
    didAllPass = smokeCapturedRetainedFrames(renderer) && didAllPass;
    didAllPass = smokeGlyphPrefixStability(renderer, app().rasterContext) && didAllPass;
    didAllPass = smokeTrackedGlyphPrefixes() && didAllPass;
    renderer.shutdown();
    g_print("smoke-cursor: %s\n", didAllPass ? "PASS" : "FAIL");
    return didAllPass ? 0 : 1;
}
