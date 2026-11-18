// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-oversized-grid — a grid past the device's largest frame is declined,
// not failed.
//
// The Vulkan frame is the model's grid at the renderer's cell, and a program
// sets the model's page length with DECSLPP: a page as tall as the model allows
// is seven bytes. At a large cell that frame is past the largest image any
// device makes, where creating one is invalid usage a driver need not report,
// and a frame the renderer fails costs the frontend its GPU for the rest of the
// run. So the renderer declines such a frame before making anything, the
// frontend draws it on the CPU raster, and the GPU draws the next grid that
// fits.
//
// On whatever device is present, it checks that a grid that fits draws and is
// not reported declined; that the page DECSLPP asks for past the device's limit
// is declined and reported so; that the CPU raster draws that same grid at its
// full height; that the next grid that fits draws on the same renderer; and
// that an export asked of the declined frame does not carry over to it.
/// Checks that an oversized frame is declined without disabling the Vulkan renderer.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeOversizedGrid()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-oversized-grid: FAIL: {}", what);
            ok = false;
        }
    };
    setupFonts();
    constexpr int fittingRows = 24;
    activePane()->session->start(fittingRows, 4);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-oversized-grid: FAIL: no term\n");
        return 1;
    }
    // A cell large enough that a page past every device's limit is still a
    // page the model holds.
    Ubiquitty::Rendering::UnifontRasterizer rasterizer(8);
    app().rasterContext.setGlyphRasterizer(rasterizer);
    app().rasterContext.resetSoftwareRenderer();
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasterizer);
    if (!renderer.init()) {
        g_print("smoke-oversized-grid: SKIP (Vulkan init failed: no device to decline a grid)\n");
        return smokeSkippedExitCode;
    }
    std::vector<std::uint8_t> frame;
    int width = 0;
    int height = 0;
    const bool didDrawFittingGrid = renderer.renderGrid(app().rasterContext, term, frame, width, height);
    check(didDrawFittingGrid, "a 24-row grid did not draw");
    check(!renderer.didDeclineOversizedGrid(), "a grid that fits was reported declined");
    const int cellHeight = didDrawFittingGrid ? height / fittingRows : 0;
    const std::uint32_t maxHeight = renderer.maxTargetExtent().height;
    const int oversizedRows = cellHeight > 0 ? static_cast<int>(maxHeight / static_cast<std::uint32_t>(cellHeight)) + 1 : 0;
    if (cellHeight <= 0 || oversizedRows > Ubiquitty::maxRows) {
        renderer.shutdown();
        g_printerr("smoke-oversized-grid: FAIL: no page the model holds is past this device's %u-pixel frame at this cell\n", maxHeight);
        return 1;
    }

    // Asked for as a program asks for it.
    Ubiquitty::processBytes(term, "\x1b[" + std::to_string(oversizedRows) + "t");
    check(term->rows == oversizedRows, "DECSLPP did not set the page length");
    if (renderer.canExportFrames())
        renderer.requestFrameExport();
    check(!renderer.renderGrid(app().rasterContext, term, frame, width, height), "a grid past the device's largest frame was drawn");
    check(renderer.didDeclineOversizedGrid(), "a grid past the device's largest frame was reported as a failure, which gives up the GPU for good");
    std::vector<std::uint8_t> cpuFrame;
    int cpuWidth = 0;
    int cpuHeight = 0;
    const bool didRasterize = app().rasterContext.rasterizeTerm(term, cpuFrame, cpuWidth, cpuHeight);
    check(didRasterize && cpuHeight == oversizedRows * cellHeight, "the CPU raster did not draw the declined grid at its full height");

    Ubiquitty::processBytes(term, "\x1b[" + std::to_string(fittingRows) + "t");
    const bool didDrawAfterDecline = renderer.renderGrid(app().rasterContext, term, frame, width, height);
    check(didDrawAfterDecline && height == fittingRows * cellHeight, "the renderer did not draw the next grid that fits");
    check(!renderer.didDeclineOversizedGrid(), "a frame that fits was reported declined after one that did not");
    if (const std::optional<Ubiquitty::Linux::VulkanRenderer::ExportedFrame> carried = renderer.takeExportedFrame()) {
        check(false, "the export asked of the declined frame carried over to the next one");
        ::close(carried->fileDescriptor);
        renderer.releaseExportedFrame(carried->releaseToken);
    }
    renderer.shutdown();
    Ubiquitty::PAL::logLine(stdout, "smoke-oversized-grid: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
